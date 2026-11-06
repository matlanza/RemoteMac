import Foundation
import Dispatch
import Network
import TailscaleKit

enum EmbeddedTailscaleBridgeConfig {
    nonisolated static let localHost = "127.0.0.1"
    nonisolated static let localPort: UInt16 = 42426

    nonisolated static let macTailnetHost =
        "your-mac.your-tailnet.ts.net"
}

enum EmbeddedTailscaleBridgeError:
    Error,
    LocalizedError,
    Sendable
{
    case tailnetNotReady
    case localConnectionClosed

    var errorDescription: String? {
        switch self {
        case .tailnetNotReady:
            return "Embedded Tailscale is not ready"

        case .localConnectionClosed:
            return "Local RemoteMac connection closed"
        }
    }
}

actor EmbeddedTailscaleBridge {
    static let shared =
        EmbeddedTailscaleBridge()

    private let networkQueue =
        DispatchQueue(
            label:
                "com.example.remotemac.embedded-bridge"
        )

    private var listener:
        NWListener?

    private var listenerIsReady =
        false

    private var foregroundGeneration:
        UInt64 = 0

    private var preparedForegroundGeneration:
        UInt64 = 0

    private var sessionID:
        UUID?

    private var localConnection:
        NWConnection?

    private var tailConnection:
        OutgoingConnection?

    private var targetEndpoint:
        RemoteEndpoint?

    private var localToTailTask:
        Task<Void, Never>?

    private var tailToLocalTask:
        Task<Void, Never>?

    func start() {
        guard listener == nil else {
            return
        }

        listenerIsReady =
            false

        do {
            guard let port =
                NWEndpoint.Port(
                    rawValue:
                        EmbeddedTailscaleBridgeConfig
                            .localPort
                )
            else {
                print(
                    "REMOTEMAC_BRIDGE invalid local port"
                )

                return
            }

            let parameters =
                NWParameters.tcp

            parameters.allowLocalEndpointReuse =
                true

            parameters.requiredLocalEndpoint =
                .hostPort(
                    host:
                        NWEndpoint.Host(
                            EmbeddedTailscaleBridgeConfig
                                .localHost
                        ),
                    port: port
                )

            let listener =
                try NWListener(
                    using: parameters
                )

            self.listener =
                listener

            listener.stateUpdateHandler = {
                [weak self] state in

                guard let self else {
                    return
                }

                Task {
                    await self.handleListenerState(
                        state,
                        source: listener
                    )
                }
            }

            listener.newConnectionHandler = {
                [weak self] connection in

                guard let self else {
                    connection.cancel()
                    return
                }

                Task {
                    await self.accept(
                        connection
                    )
                }
            }

            listener.start(
                queue: networkQueue
            )

        } catch {
            listenerIsReady =
                false

            listener =
                nil

            print(
                "REMOTEMAC_BRIDGE listener error: \(error)"
            )
        }
    }

    private func handleListenerState(
        _ state: NWListener.State,
        source: NWListener
    ) {
        guard listener === source else {
            print(
                "REMOTEMAC_BRIDGE ignoring stale listener state"
            )

            return
        }

        switch state {
        case .ready:
            listenerIsReady =
                true

            print(
                "REMOTEMAC_BRIDGE listening on 127.0.0.1:42426"
            )

        case .waiting(let error):
            listenerIsReady =
                false

            print(
                "REMOTEMAC_BRIDGE listener waiting: \(error)"
            )

        case .failed(let error):
            listenerIsReady =
                false

            print(
                "REMOTEMAC_BRIDGE listener failed: \(error)"
            )

            listener = nil

        case .cancelled:
            listenerIsReady =
                false

            print(
                "REMOTEMAC_BRIDGE listener cancelled"
            )

            listener = nil

        default:
            break
        }
    }

    private func accept(
        _ connection: NWConnection
    ) async {
        await closeCurrentSession()

        let id =
            UUID()

        sessionID =
            id

        localConnection =
            connection

        print(
            "REMOTEMAC_BRIDGE local RemoteClient connected"
        )

        connection.stateUpdateHandler = {
            [weak self] state in

            guard let self else {
                return
            }

            Task {
                await self.handleLocalState(
                    state,
                    sessionID: id
                )
            }
        }

        connection.start(
            queue: networkQueue
        )
    }

    private func handleLocalState(
        _ state: NWConnection.State,
        sessionID id: UUID
    ) async {
        guard sessionID == id else {
            return
        }

        switch state {
        case .ready:
            print(
                "REMOTEMAC_BRIDGE localhost side ready"
            )

            await connectTailnet(
                sessionID: id
            )

        case .failed(let error):
            print(
                "REMOTEMAC_BRIDGE localhost failed: \(error)"
            )

            await closeSession(
                id
            )

        case .cancelled:
            print(
                "REMOTEMAC_BRIDGE localhost closed"
            )

            await closeSession(
                id
            )

        default:
            break
        }
    }

    private func connectTailnet(
        sessionID id: UUID
    ) async {
        guard sessionID == id else {
            return
        }

        guard
            let targetEndpoint
        else {
            print(
                "REMOTEMAC_BRIDGE no selected remote endpoint"
            )

            await closeSession(
                id
            )

            return
        }

        let address =
            targetEndpoint
                .dialAddress

        do {
            print(
                "REMOTEMAC_BRIDGE dialing \(address)"
            )

            let tail =
                try await TailscaleKitProbe
                    .shared
                    .makeConnection(
                        to:
                            address
                    )

            guard sessionID == id else {
                await tail.close()
                return
            }

            tailConnection =
                tail

            print(
                "REMOTEMAC_BRIDGE tailnet connected ✓"
            )

            Task {
                await self.runUDPPathProbe(
                    host:
                        targetEndpoint.host
                )
            }

            startPumps(
                sessionID: id,
                tail: tail
            )

        } catch {
            print(
                "REMOTEMAC_BRIDGE tailnet dial failed: \(error)"
            )

            await closeSession(
                id
            )
        }
    }

    private func runUDPPathProbe(
        host: String
    ) async {
        let sampleCount =
            8

        let address =
            "\(host):42428"

        do {
            let udp =
                try await TailscaleKitProbe
                    .shared
                    .makeConnection(
                        to: address,
                        proto: .udp,
                        maxAttempts: 1
                    )

            var rtts: [Double] =
                []

            for sequence in 0..<sampleCount {
                let payload =
                    Data(
                        "RMUDP1:\(sequence):\(UUID().uuidString)"
                            .utf8
                    )

                let started =
                    DispatchTime
                        .now()
                        .uptimeNanoseconds

                try await udp.send(
                    payload
                )

                do {
                    let response =
                        try await udp.receive(
                            maximumLength: 512,
                            timeout: 500
                        )

                    if response == payload {
                        let finished =
                            DispatchTime
                                .now()
                                .uptimeNanoseconds

                        let rtt =
                            Double(
                                finished
                                - started
                            )
                            / 1_000_000.0

                        rtts.append(
                            rtt
                        )

                        print(
                            String(
                                format:
                                    "REMOTEMAC_UDP_PROBE sample=%d rtt=%.1fms",
                                sequence,
                                rtt
                            )
                        )
                    }
                } catch {
                    print(
                        "REMOTEMAC_UDP_PROBE sample=\(sequence) timeout"
                    )
                }

                if sequence + 1 < sampleCount {
                    try? await Task.sleep(
                        nanoseconds:
                            80_000_000
                    )
                }
            }

            await udp.close()

            let received =
                rtts.count

            let lost =
                sampleCount
                - received

            if received > 0 {
                let average =
                    rtts.reduce(
                        0,
                        +
                    )
                    / Double(
                        received
                    )

                let minimum =
                    rtts.min()
                    ?? 0

                let maximum =
                    rtts.max()
                    ?? 0

                print(
                    String(
                        format:
                            "REMOTEMAC_UDP_PROBE RESULT received=%d/%d lost=%d avg=%.1fms min=%.1fms max=%.1fms",
                        received,
                        sampleCount,
                        lost,
                        average,
                        minimum,
                        maximum
                    )
                )
            } else {
                print(
                    "REMOTEMAC_UDP_PROBE RESULT received=0/\(sampleCount)"
                )
            }
        } catch {
            print(
                "REMOTEMAC_UDP_PROBE FAILED \(error)"
            )
        }
    }

    private func startPumps(
        sessionID id: UUID,
        tail: OutgoingConnection
    ) {
        localToTailTask?.cancel()
        tailToLocalTask?.cancel()

        localToTailTask =
            Task {
                await self.pumpLocalToTail(
                    sessionID: id,
                    tail: tail
                )
            }

        tailToLocalTask =
            Task {
                await self.pumpTailToLocal(
                    sessionID: id,
                    tail: tail
                )
            }
    }

    private func pumpLocalToTail(
        sessionID id: UUID,
        tail: OutgoingConnection
    ) async {
        do {
            while
                !Task.isCancelled,
                sessionID == id
            {
                guard let local =
                    localConnection
                else {
                    throw EmbeddedTailscaleBridgeError
                        .localConnectionClosed
                }

                let data =
                    try await receiveLocal(
                        local
                    )

                if data.isEmpty {
                    continue
                }

                try await tail.send(
                    data
                )
            }

        } catch {
            if !Task.isCancelled {
                print(
                    "REMOTEMAC_BRIDGE local→tail ended: \(error)"
                )

                await closeSession(
                    id
                )
            }
        }
    }

    private func pumpTailToLocal(
        sessionID id: UUID,
        tail: OutgoingConnection
    ) async {
        do {
            while
                !Task.isCancelled,
                sessionID == id
            {
                let data =
                    try await tail.receive(
                        maximumLength:
                            65_536,
                        timeout: -1
                    )

                if data.isEmpty {
                    continue
                }

                guard let local =
                    localConnection
                else {
                    throw EmbeddedTailscaleBridgeError
                        .localConnectionClosed
                }

                try await sendLocal(
                    data,
                    on: local
                )
            }

        } catch {
            if !Task.isCancelled {
                print(
                    "REMOTEMAC_BRIDGE tail→local ended: \(error)"
                )

                await closeSession(
                    id
                )
            }
        }
    }

    private func receiveLocal(
        _ connection: NWConnection
    ) async throws -> Data {
        try await withCheckedThrowingContinuation {
            (
                continuation:
                    CheckedContinuation<
                        Data,
                        any Error
                    >
            ) in

            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 65_536
            ) {
                data,
                _,
                isComplete,
                error
                in

                if let error {
                    continuation.resume(
                        throwing: error
                    )

                    return
                }

                if let data,
                   !data.isEmpty
                {
                    continuation.resume(
                        returning: data
                    )

                    return
                }

                if isComplete {
                    continuation.resume(
                        throwing:
                            EmbeddedTailscaleBridgeError
                                .localConnectionClosed
                    )

                    return
                }

                continuation.resume(
                    returning: Data()
                )
            }
        }
    }

    private func sendLocal(
        _ data: Data,
        on connection: NWConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (
                continuation:
                    CheckedContinuation<
                        Void,
                        any Error
                    >
            ) in

            connection.send(
                content: data,
                completion:
                    .contentProcessed {
                        error in

                        if let error {
                            continuation.resume(
                                throwing: error
                            )
                        } else {
                            continuation.resume(
                                returning: ()
                            )
                        }
                    }
            )
        }
    }

    func markDidBecomeActive() {
        foregroundGeneration &+= 1

        listenerIsReady =
            false

        print(
            "REMOTEMAC_BRIDGE foreground generation=\(foregroundGeneration)"
        )
    }

    func prepareForConnection(
        endpoint: RemoteEndpoint
    ) async -> Bool {
        let cleanedHost =
            endpoint.host
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        guard
            !cleanedHost.isEmpty,
            endpoint.port != 0
        else {
            print(
                "REMOTEMAC_BRIDGE invalid target endpoint"
            )

            return false
        }

        let resolvedEndpoint =
            RemoteEndpoint(
                host:
                    cleanedHost,
                port:
                    endpoint.port
            )

        if
            sessionID != nil,
            targetEndpoint !=
                resolvedEndpoint
        {
            print(
                "REMOTEMAC_BRIDGE cannot switch target during active session"
            )

            return false
        }

        targetEndpoint =
            resolvedEndpoint

        let targetGeneration =
            foregroundGeneration

        if
            preparedForegroundGeneration
                != targetGeneration
        {
            guard sessionID == nil else {
                return await ensureReady()
            }

            print(
                "REMOTEMAC_BRIDGE refreshing listener before connection"
            )

            let ready =
                await recreateListener()

            if ready {
                preparedForegroundGeneration =
                    targetGeneration
            }

            return ready
        }

        return await ensureReady()
    }

    func ensureReady()
        async -> Bool
    {
        for _ in 0..<80 {
            if listenerIsActuallyReady() {
                listenerIsReady =
                    true

                return true
            }

            if listener == nil {
                start()
            }

            try? await Task.sleep(
                nanoseconds:
                    50_000_000
            )
        }

        listenerIsReady =
            listenerIsActuallyReady()

        print(
            "REMOTEMAC_BRIDGE listener readiness timed out ready=\(listenerIsReady)"
        )

        return listenerIsReady
    }

    private func listenerIsActuallyReady()
        -> Bool
    {
        guard let listener else {
            return false
        }

        if case .ready =
            listener.state
        {
            return true
        }

        return false
    }

    private func recreateListener()
        async -> Bool
    {
        let oldListener =
            listener

        listener =
            nil

        listenerIsReady =
            false

        oldListener?
            .stateUpdateHandler = nil

        oldListener?
            .newConnectionHandler = nil

        oldListener?
            .cancel()

        try? await Task.sleep(
            nanoseconds:
                200_000_000
        )

        start()

        return await ensureReady()
    }

    func rearmAfterDisconnect()
        async
    {
        print(
            "REMOTEMAC_BRIDGE closing session; listener retained"
        )

        await closeCurrentSession()

        let ready =
            await ensureReady()

        print(
            "REMOTEMAC_BRIDGE listener retained ready=\(ready)"
        )
    }

    private func closeSession(
        _ id: UUID
    ) async {
        guard sessionID == id else {
            return
        }

        await closeCurrentSession()
    }

    private func closeCurrentSession()
        async
    {
        let local =
            localConnection

        let tail =
            tailConnection

        localConnection =
            nil

        tailConnection =
            nil

        sessionID =
            nil

        localToTailTask?.cancel()
        tailToLocalTask?.cancel()

        localToTailTask =
            nil

        tailToLocalTask =
            nil

        local?.stateUpdateHandler =
            nil

        local?.cancel()

        if let tail {
            await tail.close()
        }
    }
}
