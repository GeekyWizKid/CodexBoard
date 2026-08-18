import Foundation
import Security

struct OpenAIRealtimeCredentialStore: Sendable {
    private let service = "com.local.CodexBoard.realtime"
    private let account = "openai-api-key"

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            throw OpenAIRealtimeCredentialError.keychain(status)
        }
        return value
    }

    func save(_ apiKey: String) throws {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw OpenAIRealtimeCredentialError.emptyKey }
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw OpenAIRealtimeCredentialError.keychain(updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw OpenAIRealtimeCredentialError.keychain(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenAIRealtimeCredentialError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

enum OpenAIRealtimeCredentialError: LocalizedError, Equatable {
    case emptyKey
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            "API key 不能为空。"
        case let .keychain(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                "无法访问 macOS 钥匙串：\(message)"
            } else {
                "无法访问 macOS 钥匙串（状态 \(status)）。"
            }
        }
    }
}
