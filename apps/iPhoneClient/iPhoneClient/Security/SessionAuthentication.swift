import Foundation
import Security

enum SessionAuthenticationError:
    LocalizedError
{
    case randomGeneration(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomGeneration(
            let status
        ):
            return "Could not generate authentication challenge. OSStatus \(status)."
        }
    }
}

enum SessionAuthentication {
    static let challengeLength = 32

    static func makeChallenge()
        throws -> Data
    {
        var data = Data(
            count: challengeLength
        )

        let status =
            data.withUnsafeMutableBytes {
                buffer -> OSStatus in

                guard let baseAddress =
                    buffer.baseAddress
                else {
                    return errSecParam
                }

                return SecRandomCopyBytes(
                    kSecRandomDefault,
                    challengeLength,
                    baseAddress
                )
            }

        guard status == errSecSuccess else {
            throw SessionAuthenticationError
                .randomGeneration(status)
        }

        return data
    }
}
