import Foundation

/// 영속화 root 컨테이너. `workspaces.json` 의 최상위 객체에 직렬화된다.
///
/// `version` 은 add-only 마이그레이션 anchor 이며 P2 v1 에서는 1.
public struct WorkspaceFile: Codable, Equatable, @unchecked Sendable {
    public let version: Int
    public let workspaces: [Workspace]
    public let lastActiveWorkspaceId: UUID?

    public init(
        version: Int = WorkspaceStore.currentSchemaVersion,
        workspaces: [Workspace],
        lastActiveWorkspaceId: UUID? = nil
    ) {
        self.version = version
        self.workspaces = workspaces
        self.lastActiveWorkspaceId = lastActiveWorkspaceId
    }

    /// 첫 위치에 workspace 를 삽입한다. agent-view invariant guard 의 0개→1개 보정에 사용.
    public func with(prepending ws: Workspace) -> WorkspaceFile {
        WorkspaceFile(
            version: version,
            workspaces: [ws] + workspaces,
            lastActiveWorkspaceId: lastActiveWorkspaceId
        )
    }

    /// MED2: agent-view 가 2개 이상이면 가장 앞 1개만 유지하고 나머지를 제거.
    public func dedupAgentViews() -> WorkspaceFile {
        var keptAgentView = false
        let filtered = workspaces.filter { ws in
            guard ws.kind == .agentView else { return true }
            if keptAgentView { return false }
            keptAgentView = true
            return true
        }
        return WorkspaceFile(
            version: version,
            workspaces: filtered,
            lastActiveWorkspaceId: lastActiveWorkspaceId
        )
    }
}

/// `WorkspaceStore` 가 발생시키는 에러. 에러 메시지는 한국어로 호출부의
/// 에러 다이얼로그/로그에 surface 된다(H2: silently swallow 금지).
public enum WorkspaceStoreError: Error, CustomStringConvertible, Equatable {
    case writeFailed(path: String, underlyingDescription: String)

    public var description: String {
        switch self {
        case let .writeFailed(path, underlyingDescription):
            return "워크스페이스 저장에 실패했습니다 (경로: \(path)): \(underlyingDescription)"
        }
    }

    public static func == (lhs: WorkspaceStoreError, rhs: WorkspaceStoreError) -> Bool {
        switch (lhs, rhs) {
        case let (.writeFailed(p1, u1), .writeFailed(p2, u2)):
            return p1 == p2 && u1 == u2
        }
    }
}

/// `workspaces.json` 영속화 엔트리.
///
/// 3-파일 atomic write 정책(M4): `workspaces.json`(정상) /
/// `workspaces.json.tmp`(write-in-progress) / `workspaces.json.bak`(직전 정상본).
/// `load()` 진입부에서 stale `.tmp` 정리와 `.bak` 복구를 수행한다.
public final class WorkspaceStore {
    public static let currentSchemaVersion: Int = 1

    public let fileURL: URL

    /// Application Support 디렉터리 기반 기본 init.
    public convenience init() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let dir = appSupport.appendingPathComponent("ClaudeAlarmTerminal", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try self.init(fileURL: dir.appendingPathComponent("workspaces.json"))
    }

    /// 테스트 주입용 designated init. 주어진 URL 의 부모 디렉터리는
    /// 호출부가 미리 생성해 두어야 한다.
    public init(fileURL: URL) throws {
        self.fileURL = fileURL
    }

    /// 영속화된 `WorkspaceFile` 로드. 부재 시 빈 인스턴스 반환.
    ///
    /// - 진입부에서 stale `.tmp` 정리(이전 저장이 중단된 흔적).
    /// - `.json` 부재이고 `.bak` 존재 시 복구 시도.
    /// - MED2: decode 후 agent-view invariant guard 적용.
    public func load() throws -> WorkspaceFile {
        let tempURL = fileURL.appendingPathExtension("tmp")
        if FileManager.default.fileExists(atPath: tempURL.path) {
            KoreanLogger.warn("이전 저장이 미완료 상태로 종료되었습니다. 임시 파일을 정리합니다.")
            try? FileManager.default.removeItem(at: tempURL)
        }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let bakURL = fileURL.appendingPathExtension("bak")
            if FileManager.default.fileExists(atPath: bakURL.path) {
                KoreanLogger.warn("주 파일이 없어 백업(.bak)에서 복구를 시도합니다.")
                try FileManager.default.copyItem(at: bakURL, to: fileURL)
            } else {
                // 첫 부팅: agent-view 만 갖는 빈 파일을 in-memory 로 반환.
                // (저장하지 않음. 호출부가 의도적으로 save() 를 호출해야 디스크에 기록됨.)
                return WorkspaceFile(
                    version: Self.currentSchemaVersion,
                    workspaces: [Workspace.makeAgentView()],
                    lastActiveWorkspaceId: nil
                )
            }
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var file = try decoder.decode(WorkspaceFile.self, from: data)

        let agentViewCount = file.workspaces.filter { $0.kind == .agentView }.count
        if agentViewCount == 0 {
            file = file.with(prepending: Workspace.makeAgentView())
        } else if agentViewCount > 1 {
            KoreanLogger.warn("agent-view 워크스페이스가 \(agentViewCount)개 발견되었습니다. 첫 번째만 유지합니다.")
            file = file.dedupAgentViews()
        }
        return file
    }

    /// H2 + M4: 3-파일 atomic write.
    ///
    /// 1) `.tmp` 에 write
    /// 2) 직전 `.json` 이 있으면 `.bak` 로 이동 (기존 `.bak` 는 미리 제거)
    /// 3) `.tmp → .json` rename
    ///
    /// 어느 단계든 실패 시 `WorkspaceStoreError.writeFailed` 로 wrap 하여 throw.
    /// silently swallow 금지: 호출부가 한국어 에러 다이얼로그/로그에 surface 한다.
    public func save(_ file: WorkspaceFile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let tempURL = fileURL.appendingPathExtension("tmp")
        let bakURL = fileURL.appendingPathExtension("bak")

        do {
            let data = try encoder.encode(file)
            try data.write(to: tempURL, options: [.atomic])

            if FileManager.default.fileExists(atPath: fileURL.path) {
                if FileManager.default.fileExists(atPath: bakURL.path) {
                    try FileManager.default.removeItem(at: bakURL)
                }
                try FileManager.default.moveItem(at: fileURL, to: bakURL)
            }

            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        } catch {
            // 부분 실패 흔적 정리(best-effort): .tmp 가 남아 있다면 다음 load() 가 정리하므로
            // 여기서 강제 제거하지 않는다. 단, 에러는 호출부에 반드시 전파.
            throw WorkspaceStoreError.writeFailed(
                path: fileURL.path,
                underlyingDescription: error.localizedDescription
            )
        }
    }
}
