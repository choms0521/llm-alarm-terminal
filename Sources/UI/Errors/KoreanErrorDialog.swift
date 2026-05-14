import AppKit
import Foundation

/// master § 4.2 의 UPPER_SNAKE 에러 코드. P2 단계에서 surface 되는 5종.
/// 본 enum 의 rawValue 가 i18n catalog 의 키와 매핑된다(`error.lower.snake`).
public enum ErrorCode: String, CaseIterable, Equatable {
    case maxSessionsReached     = "MAX_SESSIONS_REACHED"
    case workspaceDecodeFailed  = "WORKSPACE_DECODE_FAILED"
    case atomicWriteFailed      = "ATOMIC_WRITE_FAILED"
    case claudeBinaryNotFound   = "CLAUDE_BINARY_NOT_FOUND"
    case cwdInaccessible        = "CWD_INACCESSIBLE"

    /// i18n key (`error.lower.snake`).
    public var i18nKey: String {
        switch self {
        case .maxSessionsReached:    return "error.max_sessions_reached"
        case .workspaceDecodeFailed: return "error.workspace_decode_failed"
        case .atomicWriteFailed:     return "error.atomic_write_failed"
        case .claudeBinaryNotFound:  return "error.claude_binary_not_found"
        case .cwdInaccessible:       return "error.cwd_inaccessible"
        }
    }
}

/// 한국어 에러 메시지 catalog. master § 4.2 의 5종 P2-scope 에러를 보유한다.
/// `Resources/ko.lproj/Errors.strings` 도 동일 키로 보유하지만, 본 코드는 Swift literal
/// 을 source-of-truth 로 사용하여 test 격리 시에도 fallback 없이 일관 메시지를 보장.
public enum KoreanErrorCatalog {

    /// `lower.snake` i18n key → 한국어 메시지.
    public static let messages: [String: String] = [
        ErrorCode.maxSessionsReached.i18nKey:
            "최대 세션 개수에 도달했습니다 (N=20). 기존 세션을 종료하세요.",
        ErrorCode.workspaceDecodeFailed.i18nKey:
            "워크스페이스 파일을 읽을 수 없습니다. 백업 파일(workspaces.json.bak)에서 복구를 시도합니다.",
        ErrorCode.atomicWriteFailed.i18nKey:
            "워크스페이스 저장에 실패했습니다. 디스크 용량 또는 권한을 확인하세요.",
        ErrorCode.claudeBinaryNotFound.i18nKey:
            "claude 바이너리를 찾을 수 없습니다. PATH, /opt/homebrew/bin, /usr/local/bin을 확인하세요.",
        ErrorCode.cwdInaccessible.i18nKey:
            "워크스페이스 디렉터리에 접근할 수 없습니다: {path}"
    ]

    /// 짧은 다이얼로그 제목.
    public static let titles: [ErrorCode: String] = [
        .maxSessionsReached:    "세션을 더 만들 수 없습니다",
        .workspaceDecodeFailed: "워크스페이스 로드 실패",
        .atomicWriteFailed:     "워크스페이스 저장 실패",
        .claudeBinaryNotFound:  "Claude 바이너리 부재",
        .cwdInaccessible:       "디렉터리 접근 불가"
    ]

    /// 메시지 조회. `params` 의 키에 해당하는 `{key}` placeholder 를 replace.
    public static func message(for code: ErrorCode, params: [String: String] = [:]) -> String {
        var msg = messages[code.i18nKey] ?? "오류가 발생했습니다."
        for (k, v) in params {
            msg = msg.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return msg
    }

    public static func title(for code: ErrorCode) -> String {
        titles[code] ?? "오류가 발생했습니다"
    }

    /// 도메인 에러 → ErrorCode 매핑. 미매핑은 nil 을 반환하여 호출부가 generic fallback 표시.
    public static func code(from error: Error) -> ErrorCode? {
        switch error {
        case is ManagerError:
            if case .maxSessionsReached = (error as! ManagerError) { return .maxSessionsReached }
            return nil
        case is WorkspaceStoreError:
            if case .writeFailed = (error as! WorkspaceStoreError) { return .atomicWriteFailed }
            return nil
        case is BinaryResolveError:
            if case .claudeNotFound = (error as! BinaryResolveError) { return .claudeBinaryNotFound }
            return nil
        default:
            return nil
        }
    }
}

/// NSAlert 기반 한국어 다이얼로그 wrapper.
@MainActor
public enum KoreanErrorDialog {

    /// 도메인 에러를 한국어 NSAlert 로 surface. 인식되지 않은 에러는 localizedDescription 을 fallback 으로 노출.
    public static func present(for error: Error, in window: NSWindow? = nil, params: [String: String] = [:]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let code = KoreanErrorCatalog.code(from: error) {
            alert.messageText = KoreanErrorCatalog.title(for: code)
            alert.informativeText = KoreanErrorCatalog.message(for: code, params: params)
        } else {
            alert.messageText = "오류가 발생했습니다."
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: "확인")
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
