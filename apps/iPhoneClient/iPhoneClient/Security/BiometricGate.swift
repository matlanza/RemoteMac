import Foundation
import LocalAuthentication

enum BiometricGateResult: Sendable {
    case success
    case failed(String)
}

enum BiometricGate {
    static func authenticate() async -> BiometricGateResult {
        let context = LAContext()

        context.localizedCancelTitle = "Cancel"

        var availabilityError: NSError?

        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &availabilityError
        ) else {
            if let error = availabilityError as? LAError {
                switch error.code {
                case .biometryLockout:
                    return .failed(
                        "Face ID is temporarily locked. Unlock your iPhone with its passcode once, then try again."
                    )

                case .biometryNotEnrolled:
                    return .failed(
                        "Face ID is not enrolled on this iPhone."
                    )

                case .biometryNotAvailable:
                    return .failed(
                        "Face ID is currently unavailable."
                    )

                default:
                    return .failed(
                        "Face ID unavailable: \(error.localizedDescription)"
                    )
                }
            }

            return .failed(
                availabilityError?.localizedDescription
                ?? "Face ID is unavailable."
            )
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason:
                    "Authenticate to connect to your Mac."
            )

            return success
                ? .success
                : .failed("Face ID was not accepted.")

        } catch let error as LAError {
            switch error.code {
            case .userCancel,
                 .appCancel,
                 .systemCancel:
                return .failed(
                    "Face ID cancelled."
                )

            case .authenticationFailed:
                return .failed(
                    "Face ID did not recognize you."
                )

            case .biometryLockout:
                return .failed(
                    "Face ID is temporarily locked. Unlock your iPhone with its passcode once, then try again."
                )

            default:
                return .failed(
                    error.localizedDescription
                )
            }

        } catch {
            return .failed(
                error.localizedDescription
            )
        }
    }
}
