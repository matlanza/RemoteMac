import Foundation
import Combine
import UIKit
import TailscaleKit
import RemoteProtocol

private struct RemoteMacTailscaleLogger:
    LogSink
{
    var logFileHandle: Int32? = nil

    func log(
        _ message: String
    ) {
        print(
            "REMOTEMAC_TSIPHONE \(message)"
        )
    }
}

private actor RemoteMacTailscaleConsumer:
    MessageConsumer
{
    private let notifyHandler:
        @Sendable (Ipn.Notify) -> Void

    private let errorHandler:
        @Sendable (Error) -> Void

    init(
        notifyHandler:
            @escaping @Sendable
            (Ipn.Notify) -> Void,
        errorHandler:
            @escaping @Sendable
            (Error) -> Void
    ) {
        self.notifyHandler =
            notifyHandler

        self.errorHandler =
            errorHandler
    }

    func notify(
        _ notify: Ipn.Notify
    ) {
        notifyHandler(notify)
    }

    func error(
        _ error: Error
    ) {
        errorHandler(error)
    }
}

@MainActor
final class TailscaleKitProbe:
    ObservableObject
{
    static let shared =
        TailscaleKitProbe()

    @Published private(set)
    var status =
        "Embedded Tailscale idle"

    @Published private(set)
    var ipv4: String?

    @Published private(set)
    var authURL: URL?

    private var node:
        TailscaleNode?

    private var localAPI:
        LocalAPIClient?

    private var processor:
        MessageProcessor?

    private var consumer:
        RemoteMacTailscaleConsumer?

    private var loginRequested =
        false

    private var dialStarted =
        false

    private var udpBoundaryProbeStarted =
        false

    private init() {}

    func start() {
        guard node == nil else {
            return
        }

        status =
            "Starting embedded Tailscale"

        Task {
            await startEmbeddedNode()
        }
    }

    private func startEmbeddedNode()
        async
    {
        do {
            let stateDirectory =
                try makeStateDirectory()

            let configuration =
                Configuration(
                    hostName:
                        "remotemac-iphone-embedded",
                    path:
                        stateDirectory.path,
                    authKey: nil,
                    controlURL:
                        kDefaultControlURL,
                    ephemeral: false
                )

            let logger =
                RemoteMacTailscaleLogger()

            let node =
                try TailscaleNode(
                    config:
                        configuration,
                    logger:
                        logger
                )

            self.node =
                node

            let localAPI =
                LocalAPIClient(
                    localNode: node,
                    logger: logger
                )

            self.localAPI =
                localAPI

            let consumer =
                RemoteMacTailscaleConsumer(
                    notifyHandler:
                    { notify in
                        Task {
                            @MainActor in

                            TailscaleKitProbe
                                .shared
                                .handle(
                                    notify
                                )
                        }
                    },
                    errorHandler:
                    { error in
                        Task {
                            @MainActor in

                            TailscaleKitProbe
                                .shared
                                .handle(
                                    error
                                )
                        }
                    }
                )

            self.consumer =
                consumer

            processor =
                try await localAPI
                    .watchIPNBus(
                        mask: [
                            .initialState,
                            .netmap,
                            .noPrivateKeys,
                            .rateLimitNetmaps
                        ],
                        consumer:
                            consumer
                    )

            print(
                "REMOTEMAC_TSIPHONE bringing node up"
            )

            try await node.up()

            await refreshAddresses()

        } catch {
            status =
                "Embedded Tailscale failed"

            print(
                "REMOTEMAC_TSIPHONE START ERROR: \(error)"
            )
        }
    }

    private func handle(
        _ notify: Ipn.Notify
    ) {
        if let state =
            notify.State
        {
            print(
                "REMOTEMAC_TSIPHONE STATE: \(state)"
            )

            switch state {
            case .NeedsLogin:
                status =
                    "Authorization required"

                print(
                    "REMOTEMAC_TSIPHONE waiting for tsnet interactive login"
                )

            case .Starting:
                status =
                    "Embedded Tailscale starting"

            case .Running:
                status =
                    "Embedded Tailscale running"

                Task {
                    await refreshAddresses()
                }

            default:
                break
            }
        }

        if let rawURL =
            notify.BrowseToURL,
           let url =
            URL(string: rawURL)
        {
            guard authURL != url else {
                return
            }

            authURL = url

            status =
                "Authorization required"

            print(
                "REMOTEMAC_TSIPHONE AUTH URL: \(url.absoluteString)"
            )

            UIApplication.shared.open(
                url,
                options: [:],
                completionHandler: nil
            )
        }

        if notify.LoginFinished != nil {
            print(
                "REMOTEMAC_TSIPHONE LOGIN FINISHED"
            )

            Task {
                await refreshAddresses()
            }
        }

        if let message =
            notify.ErrMessage
        {
            print(
                "REMOTEMAC_TSIPHONE IPN ERROR: \(message)"
            )
        }
    }

    private func handle(
        _ error: Error
    ) {
        print(
            "REMOTEMAC_TSIPHONE BUS ERROR: \(error)"
        )
    }

    private func requestInteractiveLogin() {
        guard
            !loginRequested,
            let localAPI
        else {
            return
        }

        loginRequested = true

        Task {
            do {
                print(
                    "REMOTEMAC_TSIPHONE requesting interactive login"
                )

                try await localAPI
                    .startLoginInteractive()

            } catch {
                await MainActor.run {
                    self.loginRequested =
                        false

                    print(
                        "REMOTEMAC_TSIPHONE LOGIN REQUEST ERROR: \(error)"
                    )
                }
            }
        }
    }

    private func refreshAddresses()
        async
    {
        guard let node else {
            return
        }

        do {
            let addresses =
                try await node.addrs()

            ipv4 =
                addresses.ip4

            if let ipv4 =
                addresses.ip4
            {
                status =
                    "Embedded Tailscale ready"

                print(
                    "REMOTEMAC_TSIPHONE RUNNING IP: \(ipv4)"
                )

            }


            await runUDPDatagramBoundaryProbe()

        } catch {
            print(
                "REMOTEMAC_TSIPHONE ADDRESS ERROR: \(error)"
            )
        }
    }

    private func testMacDial()
        async
    {
        guard !dialStarted else {
            return
        }

        guard let node else {
            return
        }

        guard let handle =
            await node.tailscale
        else {
            print(
                "REMOTEMAC_TSIPHONE no Tailscale handle"
            )
            return
        }

        dialStarted = true

        do {
            let connection =
                try await OutgoingConnection(
                    tailscale:
                        handle,
                    to:
                        "your-mac.your-tailnet.ts.net:42424",
                    proto:
                        .tcp,
                    logger:
                        RemoteMacTailscaleLogger()
                )

            try await connection
                .connect()

            print(
                "REMOTEMAC_TSIPHONE DIAL SUCCEEDED: your-mac.your-tailnet.ts.net:42424"
            )

            status =
                "Embedded path reaches Mac"

            await connection.close()

        } catch {
            dialStarted = false

            print(
                "REMOTEMAC_TSIPHONE DIAL ERROR: \(error)"
            )

            status =
                "Embedded Mac dial failed"
        }

    }


    private func runUDPDatagramBoundaryProbe()
        async
    {
        guard !udpBoundaryProbeStarted else {
            return
        }

        udpBoundaryProbeStarted =
            true

        guard
            let node,
            let handle =
                await node.tailscale
        else {
            print(
                "REMOTEMAC_UDP_BOUNDARY no Tailscale handle"
            )

            status =
                "UDP boundary unavailable"

            return
        }

        let address =
            "your-mac.your-tailnet.ts.net:42428"

        let connection =
            DatagramConnection(
                tailscale:
                    handle,
                to:
                    address,
                logger:
                    RemoteMacTailscaleLogger()
            )

        do {
            try await connection.connect()

            print(
                "REMOTEMAC_UDP_BOUNDARY connected \(address)"
            )

            let sizes =
                [
                    111,
                    777,
                    1200
                ]

            let prefix =
                Data(
                    "RMUDP1:".utf8
                )

            var allPassed =
                true

            for size in sizes {
                var payload =
                    prefix

                let remaining =
                    size
                    - prefix.count

                if remaining > 0 {
                    payload.append(
                        contentsOf:
                            (0..<remaining)
                                .map {
                                    UInt8(
                                        truncatingIfNeeded:
                                            $0
                                    )
                                }
                    )
                }

                guard payload.count == size else {
                    allPassed =
                        false

                    print(
                        "REMOTEMAC_UDP_BOUNDARY payload construction failed size=\(size)"
                    )

                    continue
                }

                try await connection.send(
                    payload
                )

                let echo =
                    try await connection.receive(
                        maximumLength:
                            2048,
                        timeout:
                            3000
                    )

                let matches =
                    echo == payload

                print(
                    "REMOTEMAC_UDP_BOUNDARY sent=\(payload.count) recv=\(echo.count) match=\(matches)"
                )

                if
                    echo.count != size
                    || !matches
                {
                    allPassed =
                        false
                }
            }

            await connection.close()

            if allPassed {
                print(
                    "REMOTEMAC_UDP_BOUNDARY ALL PASSED"
                )

                status =
                    "UDP 111/777/1200 ✓"
            } else {
                print(
                    "REMOTEMAC_UDP_BOUNDARY FAILED"
                )

                status =
                    "UDP boundary mismatch"
            }

        } catch {
            await connection.close()

            print(
                "REMOTEMAC_UDP_BOUNDARY ERROR: \(error)"
            )

            status =
                "UDP boundary failed"
        }

    }

    func tailnetPeers()
        async throws
        -> [TailnetPeerCandidate]
    {
        for _ in 0..<50 {
            if let node {
                let api =
                    LocalAPIClient(
                        localNode:
                            node,
                        logger:
                            RemoteMacTailscaleLogger()
                    )

                let status =
                    try await api
                        .backendStatus()

                let peers =
                    status.Peer
                    ?? [:]

                return peers
                    .compactMap {
                        peerID,
                        peer
                            -> TailnetPeerCandidate?
                        in

                        guard
                            let ip =
                                peer
                                    .TailscaleIPs?
                                    .first(
                                        where: {
                                            $0.contains(
                                                "."
                                            )
                                        }
                                    )
                                ?? peer
                                    .TailscaleIPs?
                                    .first
                        else {
                            return nil
                        }

                        let dnsName =
                            peer.DNSName
                                .trimmingCharacters(
                                    in:
                                        CharacterSet(
                                            charactersIn:
                                                "."
                                        )
                                )

                        let name:
                            String

                        if
                            !peer
                                .HostName
                                .isEmpty
                        {
                            name =
                                peer
                                    .HostName

                        } else if
                            !dnsName
                                .isEmpty
                        {
                            name =
                                dnsName
                                    .split(
                                        separator:
                                            "."
                                    )
                                    .first
                                    .map(
                                        String.init
                                    )
                                ?? dnsName

                        } else {
                            name =
                                "RemoteMac Device"
                        }

                        return TailnetPeerCandidate(
                            id:
                                peerID,
                            name:
                                name,
                            dnsName:
                                dnsName,
                            endpoint:
                                RemoteEndpoint(
                                    host:
                                        ip,
                                    port:
                                        RemoteProtocolInfo
                                            .port
                                ),
                            online:
                                peer.Online
                        )
                    }
            }

            try await Task.sleep(
                nanoseconds:
                    200_000_000
            )
        }

        throw EmbeddedTailscaleBridgeError
            .tailnetNotReady
    }

    func makeConnection(
        to address: String,
        proto: NetProtocol = .tcp,
        maxAttempts: Int = 150
    )
        async throws
        -> OutgoingConnection
    {
        let attempts =
            max(
                1,
                maxAttempts
            )

        for _ in 0..<attempts {
            if let node {
                do {
                    let addresses =
                        try await node.addrs()

                    if addresses.ip4 != nil,
                       let handle =
                        await node.tailscale
                    {
                        let connection =
                            try await OutgoingConnection(
                                tailscale:
                                    handle,
                                to:
                                    address,
                                proto:
                                    proto,
                                logger:
                                    RemoteMacTailscaleLogger()
                            )

                        try await connection
                            .connect()

                        return connection
                    }

                } catch {
                    print(
                        "REMOTEMAC_BRIDGE waiting for embedded tailnet: \(error)"
                    )
                }
            }

            try await Task.sleep(
                nanoseconds:
                    200_000_000
            )
        }

        throw EmbeddedTailscaleBridgeError
            .tailnetNotReady
    }

    func makeDatagramConnection(
        to address: String,
        maxAttempts: Int = 150
    )
        async throws
        -> DatagramConnection
    {
        let attempts =
            max(
                1,
                maxAttempts
            )

        for _ in 0..<attempts {
            if let node {
                do {
                    let addresses =
                        try await node.addrs()

                    if addresses.ip4 != nil,
                       let handle =
                        await node.tailscale
                    {
                        let connection =
                            DatagramConnection(
                                tailscale:
                                    handle,
                                to:
                                    address,
                                logger:
                                    RemoteMacTailscaleLogger()
                            )

                        try await connection
                            .connect()

                        return connection
                    }

                } catch {
                    print(
                        "REMOTEMAC_UDP_VIDEO waiting for embedded tailnet: \(error)"
                    )
                }
            }

            try await Task.sleep(
                nanoseconds:
                    200_000_000
            )
        }

        throw EmbeddedTailscaleBridgeError
            .tailnetNotReady
    }

    private func makeStateDirectory()
        throws -> URL
    {
        let manager =
            FileManager.default

        let base =
            try manager.url(
                for:
                    .applicationSupportDirectory,
                in:
                    .userDomainMask,
                appropriateFor: nil,
                create: true
            )

        let directory =
            base
                .appendingPathComponent(
                    "RemoteMac",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "EmbeddedTailscaleV2",
                    isDirectory: true
                )

        try manager
            .createDirectory(
                at: directory,
                withIntermediateDirectories:
                    true
            )

        return directory
    }
}
