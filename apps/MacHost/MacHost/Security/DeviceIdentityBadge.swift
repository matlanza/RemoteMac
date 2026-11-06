import SwiftUI

struct DeviceIdentityBadge: View {
    @State private var fingerprint =
        "Loading identity…"

    @State private var failed =
        false

    var body: some View {
        Text(
            failed
                ? fingerprint
                : "Device ID \(fingerprint)"
        )
        .font(.caption2)
        .monospaced()
        .foregroundStyle(
            failed
                ? .red
                : .secondary
        )
        .task {
            guard
                fingerprint
                    == "Loading identity…"
            else {
                return
            }

            do {
                let value =
                    try await Task.detached(
                        priority: .utility
                    ) {
                        try DeviceIdentityStore
                            .fingerprint()
                    }
                    .value

                fingerprint = value

            } catch {
                failed = true
                fingerprint =
                    "Identity error: \(error.localizedDescription)"
            }
        }
    }
}
