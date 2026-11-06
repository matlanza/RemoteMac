import Foundation
import CryptoKit
import Security

struct DeviceIdentity {
    let privateKey: Curve25519.Signing.PrivateKey

    var publicKeyData: Data {
        privateKey.publicKey.rawRepresentation
    }

    var fingerprint: String {
        Self.fingerprint(
            for: publicKeyData
        )
    }

    static func fingerprint(
        for publicKeyData: Data
    ) -> String {
        let digest = SHA256.hash(
            data: publicKeyData
        )

        let hex = digest
            .prefix(10)
            .map {
                String(
                    format: "%02X",
                    $0
                )
            }

        return stride(
            from: 0,
            to: hex.count,
            by: 2
        )
        .map {
            hex[$0..<min($0 + 2, hex.count)]
                .joined()
        }
        .joined(
            separator: "-"
        )
    }

    func signature(
        for data: Data
    ) throws -> Data {
        try privateKey.signature(
            for: data
        )
    }

    static func verify(
        signature: Data,
        for data: Data,
        publicKeyData: Data
    ) -> Bool {
        guard let publicKey =
            try? Curve25519.Signing.PublicKey(
                rawRepresentation:
                    publicKeyData
            )
        else {
            return false
        }

        return publicKey.isValidSignature(
            signature,
            for: data
        )
    }
}

enum DeviceIdentityStoreError:
    LocalizedError
{
    case keychain(OSStatus)
    case invalidStoredKey

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

        case .invalidStoredKey:
            return "The stored RemoteMac identity key is invalid."
        }
    }
}

enum DeviceIdentityStore {
    private static let service =
        "com.example.remotemac.identity"

    private static let account =
        "ed25519-signing-key-v1"

    static func loadOrCreate()
        throws -> DeviceIdentity
    {
        if let existing =
            try loadRawKey()
        {
            guard let key =
                try? Curve25519.Signing.PrivateKey(
                    rawRepresentation:
                        existing
                )
            else {
                throw DeviceIdentityStoreError
                    .invalidStoredKey
            }

            return DeviceIdentity(
                privateKey: key
            )
        }

        let generated =
            Curve25519.Signing.PrivateKey()

        let inserted =
            try saveRawKey(
                generated.rawRepresentation
            )

        if inserted {
            return DeviceIdentity(
                privateKey: generated
            )
        }

        guard
            let existing =
                try loadRawKey(),
            let key =
                try? Curve25519.Signing.PrivateKey(
                    rawRepresentation:
                        existing
                )
        else {
            throw DeviceIdentityStoreError
                .invalidStoredKey
        }

        return DeviceIdentity(
            privateKey: key
        )
    }

    static func fingerprint()
        throws -> String
    {
        try loadOrCreate()
            .fingerprint
    }

    private static func loadRawKey()
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
            throw DeviceIdentityStoreError
                .keychain(status)
        }

        return data
    }

    private static func saveRawKey(
        _ data: Data
    ) throws -> Bool {
        var query =
            baseQuery()

        query[kSecValueData] = data

        query[kSecAttrAccessible] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status =
            SecItemAdd(
                query as CFDictionary,
                nil
            )

        if status == errSecDuplicateItem {
            return false
        }

        guard status == errSecSuccess else {
            throw DeviceIdentityStoreError
                .keychain(status)
        }

        return true
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
