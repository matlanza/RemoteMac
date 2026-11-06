import Foundation
import RemoteProtocol
import TailscaleKit

final class DevicePresenceProbe:
    @unchecked Sendable
{
    static let shared =
        DevicePresenceProbe()

    private let responseDeadlineNanoseconds:
        UInt64 =
            2_000_000_000

    private init() {}

    func isReachable(
        endpoint: RemoteEndpoint,
        onTransportReady:
            (@Sendable () async -> Void)? =
                nil
    ) async -> Bool {
        var connection:
            OutgoingConnection?

        var deadlineTask:
            Task<Void, Never>?

        do {
            let activeConnection =
                try await TailscaleKitProbe
                    .shared
                    .makeConnection(
                        to:
                            endpoint.dialAddress,
                        maxAttempts:
                            5
                    )

            connection =
                activeConnection

            if let onTransportReady {
                await onTransportReady()
            }

            deadlineTask =
                Task {
                    [responseDeadlineNanoseconds]
                    in

                    do {
                        try await Task.sleep(
                            nanoseconds:
                                responseDeadlineNanoseconds
                        )
                    } catch {
                        return
                    }

                    guard !Task.isCancelled else {
                        return
                    }

                    print(
                        "REMOTEMAC_PRESENCE probe deadline; closing connection"
                    )

                    await activeConnection
                        .close()
                }

            var parser =
                RemotePacketParser()

            try await activeConnection
                .send(
                    RemotePacket
                        .ping
                        .wireData
                )

            for _ in 0..<3 {
                let data =
                    try await activeConnection
                        .receive(
                            maximumLength:
                                4096
                        )

                if data.isEmpty {
                    break
                }

                let packets =
                    try parser.append(
                        data
                    )

                if
                    packets.contains(
                        where: {
                            $0.type ==
                                .pong
                        }
                    )
                {
                    deadlineTask?
                        .cancel()

                    try? await activeConnection
                        .send(
                            RemotePacket
                                .disconnect
                                .wireData
                        )

                    await activeConnection
                        .close()

                    print(
                        "REMOTEMAC_PRESENCE MacHost pong ✓"
                    )

                    return true
                }
            }

            deadlineTask?
                .cancel()

            try? await activeConnection
                .send(
                    RemotePacket
                        .disconnect
                        .wireData
                )

            await activeConnection
                .close()

            print(
                "REMOTEMAC_PRESENCE no MacHost pong"
            )

            return false

        } catch {
            deadlineTask?
                .cancel()

            if let connection {
                await connection.close()
            }

            print(
                "REMOTEMAC_PRESENCE MacHost unavailable: \(error.localizedDescription)"
            )

            return false
        }
    }
}
