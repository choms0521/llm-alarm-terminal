import Foundation
import Security

/// DeviceStore의 실 Keychain 구현. secret은 generic password item의 data에, Device 메타
/// (id/name/tokenId/expiresAt/revoked)는 같은 item의 generic attribute에 JSON으로 담는다.
/// 정책/UI는 DeviceStore protocol에만 의존하고, 비밀이 디스크에 닿는 곳은 이 한 conformer로
/// 모인다(D-2 옵션 A). 단위 테스트는 InMemoryDeviceStore로 entitlement/서명 오염 없이 정책을
/// 검증하고, 이 conformer는 GUI/CLI 검증 게이트로 분리한다.
///
/// item 1개 = 디바이스 1개다. account는 tokenId(식별자, 로그·매칭에 안전), service는
/// 환경 변수의 단일 service명. tokenId 1차 키로 SecItem을 왕복하며, revoke(id:)는 UUID로
/// 들어오므로 전체 item을 훑어 id 일치 item을 갱신한다.
///
/// secret raw bytes는 메모리에서 SecItem API로만 흐르고 어떤 로그에도 남기지 않는다
/// (master § 7 보안 원칙). os_log/print로 secret을 출력하는 경로는 두지 않는다.
public struct KeychainDeviceStore: DeviceStore {
    /// Keychain 접근 중 발생할 수 있는 오류. OSStatus를 그대로 담아 진단하되 secret 본문은
    /// 절대 포함하지 않는다.
    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case metadataDecodeFailed
        case metadataEncodeFailed
    }

    /// item의 generic attribute에 JSON으로 담기는 Device 메타. secret은 여기 없다
    /// (item data에만 존재).
    private struct StoredMetadata: Codable {
        let id: UUID
        let name: String
        let tokenId: String
        let fcmToken: String?
        let apnsToken: String?
        let expiresAt: Date
        let revoked: Bool
    }

    private let service: String

    /// service명을 주입한다. 기본값은 환경 변수(CLAUDE_ALARM_DEVICE_KEYCHAIN_SERVICE) 또는
    /// 명세 기본값. service명은 secret이 아닌 식별자라 코드/env에 두어도 안전하다.
    public init(service: String = KeychainDeviceStore.defaultService()) {
        self.service = service
    }

    /// CLAUDE_ALARM_DEVICE_KEYCHAIN_SERVICE(기본 com.choms0521.ClaudeAlarmTerminal.device).
    public static func defaultService() -> String {
        ProcessInfo.processInfo.environment["CLAUDE_ALARM_DEVICE_KEYCHAIN_SERVICE"]
            ?? "com.choms0521.ClaudeAlarmTerminal.device"
    }

    // MARK: - DeviceStore

    public func list() async throws -> [Device] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let items = result as? [[String: Any]] else {
            return []
        }
        return try items.compactMap { try Self.device(fromAttributes: $0) }
    }

    public func upsert(_ device: Device, secret: Data) async throws {
        // 동일 deviceId가 새 tokenId로 재페어링되면 옛 tokenId item(옛 secret 포함)을 먼저
        // 제거한다. 이로써 옛 secret은 즉시 폐기되고 옛 tokenId로는 검증이 실패한다(replace 의미).
        if let oldTokenId = try tokenId(forDeviceId: device.id), oldTokenId != device.tokenId {
            try deleteItem(tokenId: oldTokenId)
        }

        let metadata = try Self.encodeMetadata(from: device)
        let account = device.tokenId

        // 같은 tokenId item이 이미 있으면 secret/메타를 갱신(SecItemUpdate), 없으면 추가
        // (SecItemAdd). 재페어링 시 secret 교체를 SecItemUpdate가 보존한다.
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [
                kSecValueData as String: secret,
                kSecAttrGeneric as String: metadata
            ] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = secret
        addQuery[kSecAttrGeneric as String] = metadata
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    public func find(byTokenId tokenId: String) async throws -> Device? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenId,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let attributes = result as? [String: Any] else {
            return nil
        }
        return try Self.device(fromAttributes: attributes)
    }

    public func secret(forTokenId tokenId: String) async throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenId,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        return result as? Data
    }

    public func revoke(id: UUID) async throws {
        // revoke는 UUID로 들어온다. tokenId 역참조 후 메타의 revoked만 토글한 새 메타로
        // SecItemUpdate한다(secret/data는 건드리지 않음).
        guard let tokenId = try tokenId(forDeviceId: id),
              let device = try await find(byTokenId: tokenId) else {
            return
        }
        let revokedDevice = Device(
            id: device.id,
            name: device.name,
            tokenId: device.tokenId,
            fcmToken: device.fcmToken,
            apnsToken: device.apnsToken,
            expiresAt: device.expiresAt,
            revoked: true
        )
        let metadata = try Self.encodeMetadata(from: revokedDevice)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenId
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecAttrGeneric as String: metadata] as CFDictionary
        )
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func remove(id: UUID) async throws {
        // deviceId → tokenId 역참조 후 해당 item을 통째로 삭제한다(메타+secret 동시 폐기).
        // id가 없으면(이미 삭제됨) no-op로 멱등 처리한다. deleteItem은 errSecItemNotFound를
        // 흡수하므로 역참조와 삭제 사이의 경쟁으로 item이 사라져도 에러로 보지 않는다.
        guard let tokenId = try tokenId(forDeviceId: id) else {
            return
        }
        try deleteItem(tokenId: tokenId)
    }

    // MARK: - 내부 헬퍼

    /// deviceId(UUID)로 해당 디바이스의 tokenId를 역참조한다. account는 tokenId라 직접
    /// 조회가 불가하므로 전체 item을 훑어 메타의 id 일치 항목을 찾는다.
    private func tokenId(forDeviceId id: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let items = result as? [[String: Any]] else {
            return nil
        }
        for attributes in items {
            if let device = try Self.device(fromAttributes: attributes), device.id == id {
                return device.tokenId
            }
        }
        return nil
    }

    /// 단일 tokenId item을 삭제한다(재페어링 시 옛 secret 폐기).
    private func deleteItem(tokenId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenId
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// generic attribute의 JSON 메타를 Device로 복원한다. account/data 외 부가 attribute는
    /// 무시하고 메타 단일 출처로 Device를 만든다.
    private static func device(fromAttributes attributes: [String: Any]) throws -> Device? {
        guard let metadata = attributes[kSecAttrGeneric as String] as? Data else {
            return nil
        }
        let stored: StoredMetadata
        do {
            stored = try metadataDecoder().decode(StoredMetadata.self, from: metadata)
        } catch {
            throw KeychainError.metadataDecodeFailed
        }
        return Device(
            id: stored.id,
            name: stored.name,
            tokenId: stored.tokenId,
            fcmToken: stored.fcmToken,
            apnsToken: stored.apnsToken,
            expiresAt: stored.expiresAt,
            revoked: stored.revoked
        )
    }

    /// Device를 generic attribute용 JSON으로 인코딩한다(secret 제외).
    private static func encodeMetadata(from device: Device) throws -> Data {
        let stored = StoredMetadata(
            id: device.id,
            name: device.name,
            tokenId: device.tokenId,
            fcmToken: device.fcmToken,
            apnsToken: device.apnsToken,
            expiresAt: device.expiresAt,
            revoked: device.revoked
        )
        do {
            return try metadataEncoder().encode(stored)
        } catch {
            throw KeychainError.metadataEncodeFailed
        }
    }

    /// 메타 인코딩/디코딩이 공유하는 ISO8601 Date 전략(라운드트립 보장).
    private static func metadataEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func metadataDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
