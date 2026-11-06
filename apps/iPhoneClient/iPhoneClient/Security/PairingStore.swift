import Foundation
import CryptoKit
import Security

enum PairingStoreError: LocalizedError {
    case keychain(OSStatus)
    case invalidPublicKey

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message =
                SecCopyErrorMessageString(
                    status,
                    nil
                ) as String?

            return message
                ?? "Keychain error \(status)"

        case .invalidPublicKey:
            return "Stored paired public key is invalid."
        }
    }
}

enum PairingStore {
    private static let service =
        "com.example.remotemac.pairing"

    private static let account =
        "paired-signing-public-key-v1"

    static func save(
        publicKeyData: Data
    ) throws {
        guard
            (try? Curve25519.Signing.PublicKey(
                rawRepresentation:
                    publicKeyData
            )) != nil
        else {
            throw PairingStoreError.invalidPublicKey
        }

        try delete()

        var query =
            baseQuery()

        query[kSecValueData] =
            publicKeyData

        query[kSecAttrAccessible] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status =
            SecItemAdd(
                query as CFDictionary,
                nil
            )

        guard status == errSecSuccess else {
            throw PairingStoreError
                .keychain(status)
        }
    }

    static func load()
        throws -> Data?
    {
        var query =
            baseQuery()

        query[kSecReturnData] = true
        query[kSecMatchLimit] =
            kSecMatchLimitOne

        var result: CFTypeRef?

        let status =
            SecItemCopyMatching(
                query as CFDictionary,
                &result
            )

        if status == errSecItemNotFound {
            return nil
        }

        guard
            status == errSecSuccess,
            let data = result as? Data
        else {
            throw PairingStoreError
                .keychain(status)
        }

        guard
            (try? Curve25519.Signing.PublicKey(
                rawRepresentation:
                    data
            )) != nil
        else {
            throw PairingStoreError.invalidPublicKey
        }

        return data
    }

    static func delete()
        throws
    {
        let status =
            SecItemDelete(
                baseQuery() as CFDictionary
            )

        guard
            status == errSecSuccess
            || status == errSecItemNotFound
        else {
            throw PairingStoreError
                .keychain(status)
        }
    }

    static func fingerprint()
        throws -> String?
    {
        guard let data =
            try load()
        else {
            return nil
        }

        return DeviceIdentity.fingerprint(
            for: data
        )
    }

    private static func baseQuery()
        -> [CFString: Any]
    {
        var query: [CFString: Any] = [
            kSecClass:
                kSecClassGenericPassword,
            kSecAttrService:
                service,
            kSecAttrAccount:
                account
        ]

        #if os(macOS)
        query[
            kSecUseDataProtectionKeychain
        ] = true
        #endif

        return query
    }
}
