import Foundation
import Security

struct KeychainStore {
    let service: String
    let account: String

    static let obsPassword = KeychainStore(
        service: "works.ven.obs-utils.obs-websocket",
        account: "default"
    )

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.status(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }
        return value
    }

    func write(_ value: String) throws {
        if value.isEmpty {
            try delete()
            return
        }

        let data = Data(value.utf8)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw KeychainStoreError.status(status)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.status(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.status(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum KeychainStoreError: LocalizedError {
    case status(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .status(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error: \(message) (\(status))"
            }
            return "Keychain error: \(status)"
        case .invalidData:
            return "Keychain returned invalid password data"
        }
    }
}
