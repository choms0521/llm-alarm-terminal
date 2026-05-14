import Foundation
import SwiftUI

/// SwiftUI `AttributedString` 으로의 ANSI SGR 부분집합 파서.
///
/// 지원 영역 (ADR-E 가 정한 subset):
/// - SGR 0 (reset), 1 (bold), 22 (no bold)
/// - 30~37 / 90~97 (foreground basic + bright)
/// - 40~47 / 100~107 (background basic + bright)
/// - 38;5;N (256 fg), 48;5;N (256 bg), 38;2;R;G;B (truecolor fg), 48;2;R;G;B (truecolor bg)
/// - 39 / 49 (default fg / bg)
///
/// 미지원 코드(5 blink, 7 reverse 등) 는 silently drop. raw ESC byte 가 결과에
/// 유출되지 않도록 모든 CSI/OSC 시퀀스를 strip 한다. CR 처리:
/// "\r\n" → "\n", 단독 "\r" 은 현재 줄의 이전 부분 drop.
public enum AnsiSGRParser {

    public static func parse(_ input: String) -> AttributedString {
        var output = AttributedString("")
        var currentAttr = AttributeContainer()
        var pendingPlain = ""
        var i = input.startIndex

        func flushPlain() {
            if pendingPlain.isEmpty { return }
            var seg = AttributedString(pendingPlain)
            seg.mergeAttributes(currentAttr)
            output.append(seg)
            pendingPlain.removeAll(keepingCapacity: true)
        }

        while i < input.endIndex {
            let ch = input[i]
            if ch == "\u{1b}" {
                let nextIdx = input.index(after: i)
                guard nextIdx < input.endIndex else { break }
                let next = input[nextIdx]
                if next == "[" {
                    flushPlain()
                    let (paramsStr, finalChar, advanceTo) = readCSI(input, after: input.index(after: nextIdx))
                    if let final = finalChar, final == "m" {
                        applySGR(paramsStr, to: &currentAttr)
                    }
                    i = advanceTo
                    continue
                } else if next == "]" {
                    flushPlain()
                    i = skipOSC(input, after: input.index(after: nextIdx))
                    continue
                } else {
                    i = input.index(after: nextIdx)
                    continue
                }
            }

            // Swift Character iteration 은 grapheme cluster 단위. "\r\n" 은 단일
            // cluster 로 묶이므로 우선 그 경우를 명시 처리한다.
            if ch == "\r\n" {
                pendingPlain.append("\n")
                i = input.index(after: i)
                continue
            }
            if ch == "\r" {
                let nextIdx = input.index(after: i)
                if nextIdx < input.endIndex, input[nextIdx] == "\n" {
                    pendingPlain.append("\n")
                    i = input.index(after: nextIdx)
                    continue
                }
                flushPlain()
                truncateLastLine(&output)
                i = input.index(after: i)
                continue
            }

            pendingPlain.append(ch)
            i = input.index(after: i)
        }
        flushPlain()
        return output
    }

    /// CSI 시퀀스의 parameter 영역과 final byte 를 읽고 종료 인덱스를 반환한다.
    private static func readCSI(
        _ s: String,
        after startIdx: String.Index
    ) -> (params: String, final: Character?, endIdx: String.Index) {
        var params = ""
        var j = startIdx
        while j < s.endIndex {
            let c = s[j]
            if let scalar = c.asciiValue, scalar >= 0x40, scalar <= 0x7E {
                return (params, c, s.index(after: j))
            }
            params.append(c)
            j = s.index(after: j)
        }
        return (params, nil, j)
    }

    /// OSC 시퀀스 종료 ST(\u{1b}\\) 또는 BEL(\u{07}) 까지 skip 하고 종료 인덱스 반환.
    private static func skipOSC(_ s: String, after startIdx: String.Index) -> String.Index {
        var j = startIdx
        while j < s.endIndex {
            let c = s[j]
            if c == "\u{07}" {
                return s.index(after: j)
            }
            if c == "\u{1b}" {
                let nextIdx = s.index(after: j)
                if nextIdx < s.endIndex, s[nextIdx] == "\\" {
                    return s.index(after: nextIdx)
                }
            }
            j = s.index(after: j)
        }
        return j
    }

    private static func truncateLastLine(_ output: inout AttributedString) {
        let plain = String(output.characters)
        if let last = plain.lastIndex(of: "\n") {
            let prefix = String(plain[..<plain.index(after: last)])
            output = AttributedString(prefix)
        } else {
            output = AttributedString("")
        }
    }

    /// SGR parameter 문자열 (`"31"`, `"38;2;128;64;255"`, `"1;31"`, `""`) 을 해석.
    private static func applySGR(_ params: String, to attr: inout AttributeContainer) {
        let pieces = params.isEmpty ? ["0"] : params.split(separator: ";").map { String($0) }
        var k = 0
        while k < pieces.count {
            let code = Int(pieces[k]) ?? -1
            switch code {
            case 0:
                attr = AttributeContainer()
            case 1:
                attr.font = (attr.font ?? .body).bold()
            case 22:
                if let f = attr.font { attr.font = f }
            case 30...37:
                attr.foregroundColor = basicColor(code - 30)
            case 38:
                if k + 1 < pieces.count {
                    let kind = pieces[k+1]
                    if kind == "5", k + 2 < pieces.count {
                        if let idx = Int(pieces[k+2]) {
                            attr.foregroundColor = palette256(idx)
                        }
                        k += 2
                    } else if kind == "2", k + 4 < pieces.count {
                        let r = Int(pieces[k+2]) ?? 0
                        let g = Int(pieces[k+3]) ?? 0
                        let b = Int(pieces[k+4]) ?? 0
                        attr.foregroundColor = Color(.sRGB,
                                                     red: Double(r)/255.0,
                                                     green: Double(g)/255.0,
                                                     blue: Double(b)/255.0,
                                                     opacity: 1)
                        k += 4
                    }
                }
            case 39:
                attr.foregroundColor = nil
            case 40...47:
                attr.backgroundColor = basicColor(code - 40)
            case 48:
                if k + 1 < pieces.count {
                    let kind = pieces[k+1]
                    if kind == "5", k + 2 < pieces.count {
                        if let idx = Int(pieces[k+2]) {
                            attr.backgroundColor = palette256(idx)
                        }
                        k += 2
                    } else if kind == "2", k + 4 < pieces.count {
                        let r = Int(pieces[k+2]) ?? 0
                        let g = Int(pieces[k+3]) ?? 0
                        let b = Int(pieces[k+4]) ?? 0
                        attr.backgroundColor = Color(.sRGB,
                                                     red: Double(r)/255.0,
                                                     green: Double(g)/255.0,
                                                     blue: Double(b)/255.0,
                                                     opacity: 1)
                        k += 4
                    }
                }
            case 49:
                attr.backgroundColor = nil
            case 90...97:
                attr.foregroundColor = basicColor(code - 90).opacity(0.85)
            case 100...107:
                attr.backgroundColor = basicColor(code - 100).opacity(0.85)
            default:
                // 5 blink / 7 reverse / 기타 silently drop
                break
            }
            k += 1
        }
    }

    private static func basicColor(_ idx: Int) -> Color {
        switch idx {
        case 0: return .black
        case 1: return .red
        case 2: return .green
        case 3: return .yellow
        case 4: return .blue
        case 5: return Color(.sRGB, red: 0.7, green: 0.2, blue: 0.7, opacity: 1) // magenta
        case 6: return .cyan
        case 7: return .white
        default: return .primary
        }
    }

    /// 256-color palette: 0~15 standard, 16~231 6x6x6 cube, 232~255 grayscale.
    private static func palette256(_ idx: Int) -> Color {
        if idx >= 0, idx <= 7 { return basicColor(idx) }
        if idx >= 8, idx <= 15 { return basicColor(idx - 8).opacity(0.85) }
        if idx >= 16, idx <= 231 {
            let n = idx - 16
            let r = (n / 36) % 6
            let g = (n / 6) % 6
            let b = n % 6
            let lvl = { (v: Int) -> Double in
                v == 0 ? 0 : Double(55 + 40 * v) / 255.0
            }
            return Color(.sRGB, red: lvl(r), green: lvl(g), blue: lvl(b), opacity: 1)
        }
        if idx >= 232, idx <= 255 {
            let v = Double(8 + 10 * (idx - 232)) / 255.0
            return Color(.sRGB, red: v, green: v, blue: v, opacity: 1)
        }
        return .primary
    }
}
