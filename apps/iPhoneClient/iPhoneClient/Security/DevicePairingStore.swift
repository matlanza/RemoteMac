import Foundation
import CryptoKit
import Security

enum DevicePairingStoreError:
    LocalizedError
{
    case keychain(OSStatus)
    case invalidPublicKey
    case invalidDeviceID

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
            return
                "Stored paired public key is invalid."

        case .invalidDeviceID:
            return
                "Remote device identity is invalid."
        }
    }
}

enum DevicePairingStore {
    private static let service =
        "com.example.remotemac.pairing.devices"

    private static let accountPrefix =
        "trusted-signing-public-key-v1:"

    static func save(
        publicKeyData: Data,
        for deviceID: String
    ) throws {
        try validate(
            deviceID: deviceID
        )

        guard
            (try? Curve25519.Signing.PublicKey(
                rawRepresentation:
                    publicKeyData
            )) != nil
        else {
            throw DevicePairingStoreError
                .invalidPublicKey
        }

        try delete(
            for: deviceID
        )

        var query =
            baseQuery(
                deviceID: deviceID
            )

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
            throw DevicePairingStoreError
                .keychain(status)
        }
    }

    static func load(
        for deviceID: String
    ) throws -> Data? {
        try validate(
            deviceID: deviceID
        )

        var query =
            baseQuery(
                deviceID: deviceID
            )

        query[kSecReturnData] =
            true

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
            let data =
                result as? Data
        else {
            throw DevicePairingStoreError
                .keychain(status)
        }

        guard
            (try? Curve25519.Signing.PublicKey(
                rawRepresentation:
                    data
            )) != nil
        else {
            throw DevicePairingStoreError
                .invalidPublicKey
        }

        return data
    }

    static func delete(
        for deviceID: String
    ) throws {
        try validate(
            deviceID: deviceID
        )

        let status =
            SecItemDelete(
                baseQuery(
                    deviceID: deviceID
                ) as CFDictionary
            )

        guard
            status == errSecSuccess
            || status == errSecItemNotFound
        else {
            throw DevicePairingStoreError
                .keychain(status)
        }
    }

    static func fingerprint(
        for deviceID: String
    ) throws -> String? {
        guard
            let data =
                try load(
                    for: deviceID
                )
        else {
            return nil
        }

        return DeviceIdentity
            .fingerprint(
                for: data
            )
    }

    private static func validate(
        deviceID: String
    ) throws {
        let cleaned =
            deviceID.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        guard
            !cleaned.isEmpty,
            cleaned.count <= 256
        else {
            throw DevicePairingStoreError
                .invalidDeviceID
        }
    }

    private static func baseQuery(
        deviceID: String
    ) -> [CFString: Any] {
        [
            kSecClass:
                kSecClassGenericPassword,
            kSecAttrService:
                service,
            kSecAttrAccount:
                accountPrefix
                + deviceID
        ]
    }
}
