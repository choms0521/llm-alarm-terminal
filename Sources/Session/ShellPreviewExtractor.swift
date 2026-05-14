import Foundation

/// shell pane 의 viewport text 에서 카드 preview 로 표시할 출력 line 을 추출한다.
///
/// 우선순위:
/// (1) OSC 133 영역 분석 — `\u{1b}]133;B` 마커 뒤부터 `\u{1b}]133;D` 까지가 command
///     출력 영역. 발견 시 그 영역의 마지막 non-prompt line 을 반환한다.
/// (2) Fallback — 전체 text 에서 ANSI 시퀀스 strip 후 마지막 non-prompt line 반환.
///
/// RPROMPT 처리: CSI cursor 이동 (`...C/A/B/D/H/F/G`) 직후의 현재 line 잔여는 right
/// margin 영역으로 간주하여 drop. raw `\r` 단독은 현재 line 의 출력된 부분 drop.
public enum ShellPreviewExtractor {

    private static let promptMarkers = ["% ", "$ ", "❯ ", "# "]

    public static func extract(_ viewportText: String) -> String? {
        if let region = oscCommandOutputRegion(viewportText) {
            return lastNonPromptLine(strip(region))
        }
        return lastNonPromptLine(strip(viewportText))
    }

    // MARK: - Region detection

    /// `\u{1b}]133;B` ~ ST/BEL ~ ... ~ `\u{1b}]133;D` (또는 끝) 사이를 반환.
    private static func oscCommandOutputRegion(_ s: String) -> String? {
        let bMarker = "\u{1b}]133;B"
        guard let bRange = s.range(of: bMarker) else { return nil }
        var bEnd = bRange.upperBound
        while bEnd < s.endIndex {
            let c = s[bEnd]
            if c == "\u{07}" {
                bEnd = s.index(after: bEnd)
                break
            }
            if c == "\u{1b}" {
                let n = s.index(after: bEnd)
                if n < s.endIndex, s[n] == "\\" {
                    bEnd = s.index(after: n)
                    break
                }
            }
            bEnd = s.index(after: bEnd)
        }
        let dMarker = "\u{1b}]133;D"
        var regionEnd = s.endIndex
        if let dRange = s.range(of: dMarker, range: bEnd..<s.endIndex) {
            regionEnd = dRange.lowerBound
        }
        return String(s[bEnd..<regionEnd])
    }

    // MARK: - ANSI strip + RPROMPT 처리

    private static func strip(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "\u{1b}" {
                let nextIdx = s.index(after: i)
                if nextIdx >= s.endIndex { break }
                let next = s[nextIdx]
                if next == "[" {
                    var j = s.index(after: nextIdx)
                    var rprompt = false
                    while j < s.endIndex {
                        let c = s[j]
                        if let v = c.asciiValue, v >= 0x40, v <= 0x7E {
                            if c == "C" || c == "A" || c == "B" || c == "D" ||
                               c == "H" || c == "F" || c == "G" {
                                rprompt = true
                            }
                            j = s.index(after: j)
                            break
                        }
                        j = s.index(after: j)
                    }
                    if rprompt {
                        while j < s.endIndex, s[j] != "\n" {
                            j = s.index(after: j)
                        }
                    }
                    i = j
                    continue
                } else if next == "]" {
                    var j = s.index(after: nextIdx)
                    while j < s.endIndex {
                        let c = s[j]
                        if c == "\u{07}" {
                            j = s.index(after: j)
                            break
                        }
                        if c == "\u{1b}" {
                            let n = s.index(after: j)
                            if n < s.endIndex, s[n] == "\\" {
                                j = s.index(after: n)
                                break
                            }
                        }
                        j = s.index(after: j)
                    }
                    i = j
                    continue
                } else {
                    i = s.index(after: nextIdx)
                    continue
                }
            }
            // "\r\n" 은 grapheme cluster 단일 character 로 들어옴. 우선 처리.
            if ch == "\r\n" {
                out.append("\n")
                i = s.index(after: i)
                continue
            }
            if ch == "\r" {
                let nextIdx = s.index(after: i)
                if nextIdx < s.endIndex, s[nextIdx] == "\n" {
                    out.append("\n")
                    i = s.index(after: nextIdx)
                    continue
                }
                if let lastNL = out.lastIndex(of: "\n") {
                    out = String(out[..<out.index(after: lastNL)])
                } else {
                    out.removeAll(keepingCapacity: true)
                }
                i = s.index(after: i)
                continue
            }
            out.append(ch)
            i = s.index(after: i)
        }
        return out
    }

    // MARK: - Line selection

    private static func lastNonPromptLine(_ stripped: String) -> String? {
        let lines = stripped.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        var idx = lines.count - 1
        while idx >= 0, lines[idx].isEmpty { idx -= 1 }
        if idx < 0 { return nil }
        let lastLine = lines[idx]
        if endsWithPromptOnly(lastLine) {
            idx -= 1
            while idx >= 0, lines[idx].isEmpty { idx -= 1 }
            if idx < 0 { return nil }
            return lines[idx]
        }
        return lastLine
    }

    private static func endsWithPromptOnly(_ line: String) -> Bool {
        for marker in promptMarkers where line.hasSuffix(marker) {
            return true
        }
        return false
    }
}
