import AppKit
import Foundation

/// P3.5 Day 2: workspaces.json v1 → v2 schema migration 한국어 다이얼로그.
///
/// `WorkspaceSchemaMigration.migrateIfNeeded` 의 결과(`Result`)에 따라 호출부에서
/// 본 enum 의 함수를 사용해 사용자에게 변환 결과를 알린다. NSAlert 패턴은
/// `KoreanErrorDialog` 와 정합.
@MainActor
public enum SchemaMigrationDialogs {

    /// migration 성공 다이얼로그. backup 파일 경로를 informativeText 에 노출.
    public static func presentSuccess(backupURL: URL, in window: NSWindow? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "워크스페이스 스키마를 v2로 변환했습니다"
        alert.informativeText =
            "이전 버전 파일은 다음 위치에 보관됩니다:\n\(backupURL.lastPathComponent)\n\n"
            + "원본을 복원하려면 해당 파일을 workspaces.json 으로 덮어쓰면 됩니다."
        alert.addButton(withTitle: "확인")
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// migration backup 생성 실패 다이얼로그. 원본 v1 파일은 보존됨을 알린다.
    public static func presentBackupFailure(reason: String, in window: NSWindow? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "워크스페이스 스키마 변환을 보류했습니다"
        alert.informativeText =
            "v2로 변환하려 했으나 백업 생성에 실패했습니다. 원본 파일은 그대로 보존됩니다.\n\n"
            + "사유: \(reason)\n\n"
            + "디스크 용량 또는 디렉터리 권한을 확인한 뒤 다음 부팅 시 다시 시도합니다."
        alert.addButton(withTitle: "확인")
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
