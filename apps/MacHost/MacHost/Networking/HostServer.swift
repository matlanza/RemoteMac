import Foundation
import CryptoKit
import Combine
import Network
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics
import AppKit
import RemoteProtocol

final class HostServer: ObservableObject, @unchecked Sendable {
    static let shared = HostServer()
    @Published private(set) var status = "Starting"
    @Published private(set) var lastEvent = "None"
    @Published private(set) var isStreaming = false

    @Published private(set) var pairingMode = false
    @Published private(set) var pendingPairFingerprint: String?
    @Published private(set) var pairedPeerFingerprint: String?

    @Published private(set) var isAuthenticated = false

    private func debugConnectionEvent(
        _ message: String
    ) {
        let fileManager =
            FileManager.default

        guard let base =
            fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return
        }

        let directory =
            base.appendingPathComponent(
                "RemoteMac",
                isDirectory: true
            )

        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let file =
            directory.appendingPathComponent(
                "host-connection-debug.log"
            )

        let line =
            String(
                format:
                    "%.6f HOST[%d] %@\n",
                Date().timeIntervalSince1970,
                ProcessInfo.processInfo.processIdentifier,
                message
            )

        var data =
            (try? Data(contentsOf: file))
            ?? Data()

        data.append(
            Data(line.utf8)
        )

        try? data.write(
            to: file,
            options: .atomic
        )
    }

    private let queue = DispatchQueue(
        label: "com.example.remotemac.host"
    )

    private let captureQueue = DispatchQueue(
        label: "com.example.remotemac.capture"
    )

    private var listener: NWListener?
    private var connection: NWConnection?
    private var parser = RemotePacketParser()

    private var screenStream: SCStream?
    private var screenOutput: ScreenStreamOutput?
    private var h264Encoder: H264Encoder?
    private let inputController = InputController()

    private var pendingPairPublicKey: Data?

    private var txStatsFrames = 0
    private var txStatsBytes = 0

    private var txStatsStart =
        DispatchTime.now()
            .uptimeNanoseconds

    private var authenticationChallenge: Data?

    private let adaptiveVideoBitrates = [
        8_000_000,
        6_000_000,
        4_500_000,
        3_000_000,
        2_000_000
    ]

    private var adaptiveVideoBitrateIndex = 0
    private var adaptiveVideoSendsInFlight = 0
    private var adaptiveVideoSendEWMASeconds = 0.0
    private var adaptiveVideoBadWindows = 0
    private var adaptiveVideoGoodWindows = 0
    private var adaptiveVideoGeneration = 0

    private var videoDatagramEnabled = false
    private var videoDatagramFrameID: UInt32 = 0
    private var videoDatagramConnection: NWConnection?
    private var videoDatagramSending = false
    private var videoDatagramPendingFrame: Data?
    private var videoDatagramPendingKeyFrame = false
    private var videoDatagramPendingSourceFrameID: UInt32?
    private var videoDatagramDroppedFrames = 0


    private var adaptiveVideoLastEvaluation =
        DispatchTime.now()
            .uptimeNanoseconds

    private var adaptiveVideoLastChange =
        DispatchTime.now()
            .uptimeNanoseconds

    private func beginAuthentication(
        on connection: NWConnection
    ) {
        do {
            guard
                try PairingStore.load()
                    != nil
            else {
                authenticationChallenge =
                    nil

                DispatchQueue.main.async {
                    self.isAuthenticated =
                        false
                }

                publish(
                    status: "Pairing required",
                    event:
                        "No authenticated iPhone is paired"
                )

                return
            }

            let challenge =
                try SessionAuthentication
                    .makeChallenge()

            authenticationChallenge =
                challenge

            DispatchQueue.main.async {
                self.isAuthenticated =
                    false
            }

            send(
                .authChallenge(
                    challenge
                ),
                on: connection,
                successEvent:
                    "Authentication challenge sent"
            )

        } catch {
            publish(
                status:
                    "Authentication failed",
                event:
                    error.localizedDescription
            )
        }
    }

    private func respondToChallenge(
        _ challenge: Data,
        on connection: NWConnection
    ) {
        guard
            challenge.count
                == SessionAuthentication
                    .challengeLength
        else {
            send(
                .authRejected,
                on: connection,
                successEvent:
                    "Rejected malformed authentication challenge"
            )

            return
        }

        do {
            let identity =
                try DeviceIdentityStore
                    .loadOrCreate()

            let signature =
                try identity.signature(
                    for: challenge
                )

            send(
                .authResponse(
                    signature
                ),
                on: connection,
                successEvent:
                    "Signed iPhone authentication challenge"
            )

        } catch {
            publish(
                status:
                    "Authentication failed",
                event:
                    error.localizedDescription
            )
        }
    }

    private func verifyAuthenticationResponse(
        _ signature: Data,
        on connection: NWConnection
    ) {
        guard let challenge =
            authenticationChallenge
        else {
            publish(
                event:
                    "Unexpected authentication response"
            )

            return
        }

        do {
            guard let pairedKey =
                try PairingStore.load()
            else {
                send(
                    .authRejected,
                    on: connection,
                    successEvent:
                        "Authentication rejected — no paired iPhone"
                )

                return
            }

            let valid =
                DeviceIdentity.verify(
                    signature: signature,
                    for: challenge,
                    publicKeyData:
                        pairedKey
                )

            guard valid else {
                authenticationChallenge =
                    nil

                DispatchQueue.main.async {
                    self.isAuthenticated =
                        false
                }

                send(
                    .authRejected,
                    on: connection,
                    successEvent:
                        "Rejected invalid iPhone signature"
                )

                publish(
                    status:
                        "Authentication rejected",
                    event:
                        "iPhone signature did not match paired identity"
                )

                connection.cancel()

                return
            }

            authenticationChallenge =
                nil

            DispatchQueue.main.async {
                self.isAuthenticated =
                    true
            }

            send(
                .authAccepted,
                on: connection,
                successEvent:
                    "Authenticated paired iPhone ✓"
            )

            publish(
                status:
                    "Authenticated iPhone",
                event:
                    "Paired device signature verified ✓"
            )

        } catch {
            publish(
                status:
                    "Authentication failed",
                event:
                    error.localizedDescription
            )
        }
    }

    func refreshPairingState() {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            do {
                let fingerprint =
                    try PairingStore
                        .fingerprint()

                DispatchQueue.main.async {
                    self.pairedPeerFingerprint =
                        fingerprint
                }
            } catch {
                self.publish(
                    event:
                        "Pairing store error: \(error.localizedDescription)"
                )
            }
        }
    }

    func enablePairing() {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            self.pendingPairPublicKey = nil

            DispatchQueue.main.async {
                self.pendingPairFingerprint =
                    nil

                self.pairingMode = true
            }

            self.publish(
                event:
                    "Pairing enabled — waiting for iPhone"
            )
        }
    }

    func disablePairing() {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            self.pendingPairPublicKey = nil

            DispatchQueue.main.async {
                self.pendingPairFingerprint =
                    nil

                self.pairingMode = false
            }

            self.publish(
                event: "Pairing disabled"
            )
        }
    }

    func approvePendingPair() {
        queue.async { [weak self] in
            guard
                let self,
                let peerKey =
                    self.pendingPairPublicKey,
                let connection =
                    self.connection
            else {
                return
            }

            do {
                try PairingStore.save(
                    publicKeyData:
                        peerKey
                )

                let identity =
                    try DeviceIdentityStore
                        .loadOrCreate()

                self.send(
                    .pairApproved(
                        publicKey:
                            identity.publicKeyData
                    ),
                    on: connection,
                    successEvent:
                        "iPhone paired successfully"
                )

                let fingerprint =
                    DeviceIdentity.fingerprint(
                        for: peerKey
                    )

                self.pendingPairPublicKey = nil

                DispatchQueue.main.async {
                    self.pendingPairFingerprint =
                        nil

                    self.pairedPeerFingerprint =
                        fingerprint

                    self.pairingMode =
                        false
                }

            } catch {
                self.publish(
                    event:
                        "Pairing failed: \(error.localizedDescription)"
                )
            }
        }
    }

    func rejectPendingPair() {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            if let connection =
                self.connection
            {
                self.send(
                    .pairRejected,
                    on: connection,
                    successEvent:
                        "Pair request rejected"
                )
            }

            self.pendingPairPublicKey = nil

            DispatchQueue.main.async {
                self.pendingPairFingerprint =
                    nil
            }
        }
    }

    func forgetPairedPeer() {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            do {
                try PairingStore.delete()

                DispatchQueue.main.async {
                    self.pairedPeerFingerprint =
                        nil
                }

                self.publish(
                    event:
                        "Paired iPhone forgotten"
                )

            } catch {
                self.publish(
                    event:
                        "Could not forget pair: \(error.localizedDescription)"
                )
            }
        }
    }

    func restartConnection() {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            self.stopLiveStream(
                publishResult: false
            )

            self.connection?.cancel()
            self.listener?.cancel()

            self.connection = nil
            self.listener = nil
            self.parser = RemotePacketParser()
            self.authenticationChallenge = nil

            DispatchQueue.main.async {
                self.isAuthenticated = false
            }

            self.publish(
                status: "Restarting",
                event: "Restarting RemoteMac listener…"
            )

            self.startOnQueue()
        }
    }

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            self.stopLiveStream(
                publishResult: false
            )

            self.connection?.cancel()
            self.listener?.cancel()

            self.connection = nil
            self.listener = nil
            self.parser = RemotePacketParser()
            self.authenticationChallenge = nil

            DispatchQueue.main.async {
                self.isAuthenticated = false
            }

            self.publish(
                status: "Stopped",
                event: "Host stopped"
            )
        }
    }

    private func startOnQueue() {
        guard listener == nil else {
            return
        }

        guard let port = NWEndpoint.Port(
            rawValue: RemoteProtocolInfo.localHostPort
        ) else {
            publish(
                status: "Failed",
                event: "Invalid local port"
            )
            return
        }

        do {
            let listener = try NWListener(
                using: .tcp,
                on: port
            )

            self.listener = listener

            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard
                    let self,
                    let listener,
                    self.listener === listener
                else {
                    return
                }

                switch state {
                case .ready:
                    self.publish(
                        status: "Listening",
                        event: "Local TCP \(RemoteProtocolInfo.localHostPort)"
                    )

                case .waiting(let error):
                    self.publish(
                        status: "Waiting",
                        event: error.localizedDescription
                    )

                case .failed(let error):
                    self.listener = nil

                    self.publish(
                        status: "Failed",
                        event: error.localizedDescription
                    )

                case .cancelled:
                    self.listener = nil

                    self.publish(
                        status: "Stopped",
                        event: "Listener cancelled"
                    )

                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] newConnection in
                self?.accept(
                    newConnection
                )
            }

            listener.start(
                queue: queue
            )

        } catch {
            publish(
                status: "Failed",
                event: error.localizedDescription
            )
        }
    }

    private func accept(
        _ newConnection: NWConnection
    ) {
        let connectionID =
            String(
                ObjectIdentifier(
                    newConnection
                ).hashValue
            )

        debugConnectionEvent(
            "ACCEPT id=\(connectionID) hadCurrent=\(connection != nil)"
        )

        stopLiveStream(
            publishResult: false
        )

        if let oldConnection =
            connection
        {
            debugConnectionEvent(
                "CANCEL reason=new-connection"
            )

            oldConnection.cancel()
        }

        connection = newConnection
        parser = RemotePacketParser()

        videoDatagramEnabled = false
        videoDatagramFrameID = 0

        authenticationChallenge = nil

        newConnection.stateUpdateHandler = {
            [weak self] state in

            self?.debugConnectionEvent(
                "STATE id=\(connectionID) state=\(String(describing: state))"
            )
        }

        DispatchQueue.main.async {
            self.isAuthenticated =
                false
        }

        publish(
            status: "Client connected",
            event: "Authenticating RemoteMac session…"
        )

        newConnection.start(
            queue: queue
        )

        receive(
            on: newConnection
        )

        beginAuthentication(
            on: newConnection
        )
    }

    private func receive(
        on connection: NWConnection
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            guard self.connection === connection else {
                print(
                    "REMOTEMAC_HOST ignoring stale receive callback"
                )
                return
            }

            if let data, !data.isEmpty {
                do {
                    let packets = try self.parser.append(
                        data
                    )

                    for packet in packets {
                        self.debugConnectionEvent(
                            "RX type=\(String(describing: packet.type)) payload=\(packet.payload.count)"
                        )

                        self.handle(
                            packet,
                            on: connection
                        )
                    }
                } catch {
                    self.debugConnectionEvent(
                        "CANCEL reason=protocol-error error=\(error)"
                    )

                    self.stopLiveStream(
                        publishResult: false
                    )

                    connection.cancel()

                    self.connection = nil
                    self.parser = RemotePacketParser()

                    self.publish(
                        status: "Listening",
                        event: "Protocol error: \(error)"
                    )

                    return
                }
            }

            if let error {
                self.debugConnectionEvent(
                    "RECEIVE ERROR \(error.localizedDescription)"
                )

                self.stopLiveStream(
                    publishResult: false
                )

                self.connection = nil
                self.parser = RemotePacketParser()
                self.authenticationChallenge = nil

                DispatchQueue.main.async {
                    self.isAuthenticated = false
                }

                self.publish(
                    status: "Listening",
                    event: "Connection ended: \(error.localizedDescription)"
                )

                return
            }

            if isComplete {
                self.debugConnectionEvent(
                    "RECEIVE COMPLETE peer EOF"
                )

                self.stopLiveStream(
                    publishResult: false
                )

                self.connection = nil
                self.parser = RemotePacketParser()
                self.authenticationChallenge = nil

                DispatchQueue.main.async {
                    self.isAuthenticated = false
                }

                self.publish(
                    status: "Listening",
                    event: "Client disconnected"
                )

                return
            }

            self.receive(
                on: connection
            )
        }
    }

    private func handle(
        _ packet: RemotePacket,
        on connection: NWConnection
    ) {
        if !isAuthenticated {
            switch packet.type {
            case .ping,
                 .pong,
                 .disconnect,
                 .pairRequest,
                 .pairApproved,
                 .pairRejected,
                 .authChallenge,
                 .authResponse,
                 .authAccepted,
                 .authRejected:
                break

            default:
                publish(
                    event:
                        "Blocked unauthenticated \(packet.type) packet"
                )

                return
            }
        }

        switch packet.type {
        case .ping:
            send(
                .pong,
                on: connection,
                successEvent: "Received ping → sent pong"
            )

        case .pong:
            publish(
                event: "Received unexpected pong"
            )

        case .disconnect:
            debugConnectionEvent(
                "CANCEL reason=received-disconnect-packet"
            )

            stopLiveStream(
                publishResult: false
            )

            connection.cancel()

            self.connection = nil
            self.parser = RemotePacketParser()
            self.authenticationChallenge = nil

            DispatchQueue.main.async {
                self.isAuthenticated =
                    false
            }

            publish(
                status: "Listening",
                event: "Client disconnected"
            )

        case .requestFrame:
            captureSingleFrame(
                for: connection
            )

        case .startStream:
            startLiveStream()

        case .stopStream:
            stopLiveStream(
                publishResult: true
            )

        case .frame:
            publish(
                event: "Received unexpected frame"
            )

        case .captureError:
            publish(
                event: "Received unexpected capture error"
            )

        case .videoConfig:
            publish(
                event: "Received unexpected video config"
            )

        case .videoFrame:
            publish(
                event: "Received unexpected video frame"
            )

        case .requestVideoKeyFrame:
            guard let encoder =
                h264Encoder
            else {
                return
            }

            encoder.requestKeyFrame()

            print(
                "REMOTEMAC_UDP_VIDEO IDR_REQUEST_RECEIVED"
            )

        case .videoDatagramState:
            let enabled =
                packet.payload.first == 1

            videoDatagramEnabled =
                enabled
            adaptiveVideoSendsInFlight =
                0

            if enabled {
                adaptiveVideoBitrateIndex =
                    min(
                        4,
                        adaptiveVideoBitrates.count - 1
                    )

                if let encoder =
                    h264Encoder
                {
                    captureQueue.async {
                        let status =
                            encoder.updateBitrate(
                                2_000_000
                            )

                        print(
                            "REMOTEMAC_UDP_VIDEO bitrate=2000000 status=\(status)"
                        )
                    }
                }

                publish(
                    event:
                        "UDP video lane active • 2.0 Mbps"
                )

                print(
                    "REMOTEMAC_UDP_VIDEO ACTIVE"
                )

            } else {
                publish(
                    event:
                        "UDP video lane unavailable • TCP fallback"
                )

                print(
                    "REMOTEMAC_UDP_VIDEO FALLBACK_TCP"
                )
            }

        case .taskCompleted:
            publish(
                event:
                    "Received unexpected task completion"
            )

        case .apnsDeviceToken:
            storeAPNSDeviceToken(
                packet.payload
            )

        case .pointerDelta:
            guard let delta =
                RemotePointerDelta(
                    payload: packet.payload
                )
            else {
                return
            }

            inputController.movePointer(
                dx: delta.dx,
                dy: delta.dy
            )

        case .pointerAbsolute:
            guard let position =
                RemotePointerPosition(
                    payload: packet.payload
                )
            else {
                return
            }

            inputController.movePointerAbsolute(
                normalizedX:
                    position.normalizedX,
                normalizedY:
                    position.normalizedY
            )

        case .mouseButton:
            guard let event =
                RemoteMouseButtonEvent(
                    payload: packet.payload
                )
            else {
                return
            }

            inputController.mouseButton(
                event.button,
                action: event.action
            )

        case .scroll:
            guard let delta =
                RemoteScrollDelta(
                    payload: packet.payload
                )
            else {
                return
            }

            inputController.scroll(
                dx: delta.dx,
                dy: delta.dy
            )

        case .keyEvent:
            guard let event =
                RemoteKeyEvent(
                    payload: packet.payload
                )
            else {
                return
            }

            inputController.keyEvent(
                event
            )

        case .textInput:
            guard let text = String(
                data: packet.payload,
                encoding: .utf8
            ) else {
                return
            }

            inputController.typeText(
                text
            )

        case .pairRequest:
            guard pairingMode else {
                send(
                    .pairRejected,
                    on: connection,
                    successEvent:
                        "Rejected pair request — pairing mode off"
                )

                return
            }

            guard
                (try? Curve25519.Signing.PublicKey(
                    rawRepresentation:
                        packet.payload
                )) != nil
            else {
                send(
                    .pairRejected,
                    on: connection,
                    successEvent:
                        "Rejected invalid pair request"
                )

                return
            }

            pendingPairPublicKey =
                packet.payload

            let fingerprint =
                DeviceIdentity.fingerprint(
                    for: packet.payload
                )

            DispatchQueue.main.async {
                self.pendingPairFingerprint =
                    fingerprint
            }

            publish(
                event:
                    "Pair request received: \(fingerprint)"
            )

        case .pairApproved:
            publish(
                event:
                    "Received unexpected pair approval"
            )

        case .pairRejected:
            publish(
                event:
                    "Received unexpected pair rejection"
            )

        case .authChallenge:
            respondToChallenge(
                packet.payload,
                on: connection
            )

        case .authResponse:
            verifyAuthenticationResponse(
                packet.payload,
                on: connection
            )

        case .authAccepted:
            publish(
                event:
                    "Received unexpected authentication acceptance"
            )

        case .authRejected:
            DispatchQueue.main.async {
                self.isAuthenticated =
                    false
            }

            publish(
                status:
                    "Authentication rejected",
                event:
                    "Peer rejected authentication"
            )
        }
    }

    private func storeAPNSDeviceToken(
        _ payload: Data
    ) {
        guard
            let token =
                String(
                    data: payload,
                    encoding: .utf8
                )?
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
        else {
            publish(
                event:
                    "Rejected malformed APNs token"
            )

            return
        }

        let hexadecimal =
            CharacterSet(
                charactersIn:
                    "0123456789abcdefABCDEF"
            )

        guard
            !token.isEmpty,
            token.count <= 512,
            token.unicodeScalars
                .allSatisfy({
                    hexadecimal.contains($0)
                })
        else {
            publish(
                event:
                    "Rejected invalid APNs token"
            )

            return
        }

        do {
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
                base.appendingPathComponent(
                    "RemoteMac",
                    isDirectory: true
                )

            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories:
                    true
            )

            let file =
                directory
                    .appendingPathComponent(
                        "apns-device-token.txt"
                    )

            try Data(
                (token + "\n").utf8
            )
            .write(
                to: file,
                options: .atomic
            )

            try manager.setAttributes(
                [
                    .posixPermissions:
                        NSNumber(
                            value: 0o600
                        )
                ],
                ofItemAtPath:
                    file.path
            )

            publish(
                event:
                    "Updated iPhone push token ✓"
            )

        } catch {
            publish(
                event:
                    "Could not store push token: \(error.localizedDescription)"
            )
        }
    }

    private func startLiveStream() {
        guard screenStream == nil else {
            publish(
                event: "H.264 stream already running"
            )
            return
        }

        publish(
            status: "Preparing H.264",
            event: "Creating ScreenCaptureKit stream"
        )

        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ) { [weak self] content, error in
            guard let self else {
                return
            }

            if let error {
                self.publish(
                    status: "Capture failed",
                    event: error.localizedDescription
                )
                return
            }

            guard let display =
                content?.displays.first(
                    where: {
                        $0.displayID
                            == CGMainDisplayID()
                    }
                )
                ?? content?.displays.first
            else {
                self.publish(
                    status: "Capture failed",
                    event: "No captureable display was found"
                )
                return
            }

            var outputWidth = min(
                display.width,
                1280
            )

            if outputWidth % 2 != 0 {
                outputWidth -= 1
            }

            let ratio =
                Double(display.height)
                / Double(display.width)

            var outputHeight = max(
                2,
                Int(
                    Double(outputWidth)
                    * ratio
                )
            )

            if outputHeight % 2 != 0 {
                outputHeight -= 1
            }

            let configuration =
                SCStreamConfiguration()

            configuration.width = outputWidth
            configuration.height = outputHeight
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            configuration.showsCursor = true

            configuration.pixelFormat =
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

            configuration.minimumFrameInterval =
                CMTime(
                    value: 1,
                    timescale: 30
                )

            configuration.queueDepth = 3

            let filter = SCContentFilter(
                display: display,
                excludingWindows: []
            )

            let encoder: H264Encoder

            do {
                encoder = try H264Encoder(
                    width: outputWidth,
                    height: outputHeight,
                    fps: 30,
                    bitrate:
                        adaptiveVideoBitrates[
                            adaptiveVideoBitrateIndex
                        ],
                    onStreamConfig: { [weak self] config in
                        guard let self else {
                            return
                        }

                        self.queue.async {
                            guard let connection =
                                self.connection
                            else {
                                return
                            }

                            let remoteConfig =
                                RemoteH264Config(
                                    nalUnitHeaderLength:
                                        config.nalUnitHeaderLength,
                                    sps: config.sps,
                                    pps: config.pps
                                )

                            self.send(
                                .videoConfig(
                                    remoteConfig
                                ),
                                on: connection,
                                successEvent:
                                    "Sent H.264 SPS/PPS"
                            )
                        }
                    },
                    onEncodedFrame: { [weak self] frame in
                        guard let self else {
                            return
                        }

                        self.queue.async {
                            self.txStatsFrames += 1
                            self.txStatsBytes +=
                                frame.data.count

                            let now =
                                DispatchTime.now()
                                    .uptimeNanoseconds

                            let elapsed =
                                Double(
                                    now
                                    - self.txStatsStart
                                )
                                / 1_000_000_000.0

                            if elapsed >= 1.0 {
                                let fps =
                                    Double(
                                        self.txStatsFrames
                                    )
                                    / elapsed

                                let mbps =
                                    Double(
                                        self.txStatsBytes
                                    )
                                    * 8.0
                                    / elapsed
                                    / 1_000_000.0

                                print(
                                    String(
                                        format:
                                            "REMOTEMAC_TX %.1f FPS %.2f Mbps",
                                        fps,
                                        mbps
                                    )
                                )

                                self.txStatsFrames = 0
                                self.txStatsBytes = 0
                                self.txStatsStart = now
                            }
                            guard let connection =
                                self.connection
                            else {
                                return
                            }

                            self.sendVideoFrame(
                                frame.data,
                                isKeyFrame:
                                    frame.isKeyFrame,
                                sourceFrameID:
                                    UInt32(
                                        truncatingIfNeeded:
                                            frame.frameNumber
                                    ),
                                on:
                                    connection
                            )
                        }
                    },
                    onError: { [weak self] message in
                        self?.publish(
                            status: "H.264 error",
                            event: message,
                            streaming: false
                        )
                    }
                )
            } catch {
                self.publish(
                    status: "H.264 failed",
                    event: error.localizedDescription,
                    streaming: false
                )

                return
            }

            let output = ScreenStreamOutput { [weak self] sampleBuffer in
                self?.encode(
                    sampleBuffer
                )
            }

            let stream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: nil
            )

            do {
                try stream.addStreamOutput(
                    output,
                    type: .screen,
                    sampleHandlerQueue: self.captureQueue
                )
            } catch {
                encoder.stop()

                self.publish(
                    status: "Capture failed",
                    event: error.localizedDescription,
                    streaming: false
                )

                return
            }

            self.queue.async {
                self.h264Encoder = encoder
                self.screenOutput = output
                self.screenStream = stream

                stream.startCapture { [weak self] error in
                    guard let self else {
                        return
                    }

                    if let error {
                        self.queue.async {
                            self.h264Encoder?.stop()
                            self.h264Encoder = nil
                            self.screenOutput = nil
                            self.screenStream = nil
                        }

                        self.publish(
                            status: "Capture failed",
                            event: error.localizedDescription,
                            streaming: false
                        )

                        return
                    }

                    self.publish(
                        status: "H.264 hardware encode",
                        event:
                            "Encoder active • 1600-class • 60 FPS target • 8 Mbps",
                        streaming: true
                    )
                }
            }
        }
    }

    private func encode(
        _ sampleBuffer: CMSampleBuffer
    ) {
        guard let pixelBuffer =
            CMSampleBufferGetImageBuffer(
                sampleBuffer
            )
        else {
            return
        }

        let presentationTimeStamp =
            CMSampleBufferGetPresentationTimeStamp(
                sampleBuffer
            )

        h264Encoder?.encode(
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp
        )
    }

    private func stopLiveStream(
        publishResult: Bool
    ) {
        resetAdaptiveVideoController()

        let encoder = h264Encoder
        h264Encoder = nil

        encoder?.stop()

        guard let stream = screenStream else {
            screenOutput = nil

            if publishResult {
                publish(
                    status: "Client connected",
                    event: "H.264 stream already stopped",
                    streaming: false
                )
            }

            return
        }

        screenStream = nil
        screenOutput = nil

        stream.stopCapture { [weak self] error in
            guard let self else {
                return
            }

            if publishResult {
                if let error {
                    self.publish(
                        status: "Client connected",
                        event: "Stream stop error: \(error.localizedDescription)",
                        streaming: false
                    )
                } else {
                    self.publish(
                        status: "Client connected",
                        event: "H.264 encoder stopped",
                        streaming: false
                    )
                }
            }
        }
    }

    private func captureSingleFrame(
        for connection: NWConnection
    ) {
        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ) { [weak self] content, error in
            guard let self else {
                return
            }

            if let error {
                self.sendCaptureError(
                    error.localizedDescription,
                    on: connection
                )
                return
            }

            guard let display =
                content?.displays.first(
                    where: {
                        $0.displayID
                            == CGMainDisplayID()
                    }
                )
                ?? content?.displays.first
            else {
                self.sendCaptureError(
                    "No captureable display was found.",
                    on: connection
                )
                return
            }

            let filter = SCContentFilter(
                display: display,
                excludingWindows: []
            )

            let configuration =
                SCStreamConfiguration()

            let outputWidth = min(
                display.width,
                1280
            )

            let ratio =
                Double(display.height)
                / Double(display.width)

            configuration.width =
                outputWidth

            configuration.height = max(
                1,
                Int(
                    Double(outputWidth)
                    * ratio
                )
            )

            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            configuration.showsCursor = true

            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { [weak self] image, error in
                guard let self else {
                    return
                }

                if let error {
                    self.sendCaptureError(
                        error.localizedDescription,
                        on: connection
                    )
                    return
                }

                guard let image else {
                    self.sendCaptureError(
                        "ScreenCaptureKit returned no image.",
                        on: connection
                    )
                    return
                }

                let bitmap =
                    NSBitmapImageRep(
                        cgImage: image
                    )

                guard let jpeg =
                    bitmap.representation(
                        using: .jpeg,
                        properties: [
                            .compressionFactor: 0.65
                        ]
                    )
                else {
                    self.sendCaptureError(
                        "Could not encode captured display.",
                        on: connection
                    )
                    return
                }

                self.queue.async {
                    self.send(
                        .frame(jpeg),
                        on: connection,
                        successEvent:
                            "Sent single frame (\(jpeg.count / 1024) KB)"
                    )
                }
            }
        }
    }

    private func sendCaptureError(
        _ message: String,
        on connection: NWConnection
    ) {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            self.send(
                .captureError(
                    message
                ),
                on: connection,
                successEvent:
                    "Capture failed: \(message)"
            )
        }
    }

    private func resetAdaptiveVideoController() {
        adaptiveVideoBitrateIndex =
            videoDatagramEnabled
            ? min(
                4,
                adaptiveVideoBitrates.count - 1
            )
            : 0
        adaptiveVideoSendsInFlight = 0
        videoDatagramSending = false
        videoDatagramPendingFrame = nil
        videoDatagramPendingKeyFrame = false
        videoDatagramPendingSourceFrameID = nil
        adaptiveVideoSendEWMASeconds = 0
        adaptiveVideoBadWindows = 0
        adaptiveVideoGoodWindows = 0
        adaptiveVideoGeneration += 1

        let now =
            DispatchTime.now()
                .uptimeNanoseconds

        adaptiveVideoLastEvaluation = now
        adaptiveVideoLastChange = now
    }

    private func evaluateAdaptiveVideoController(
        now: UInt64
    ) {
        guard
            now >=
                adaptiveVideoLastEvaluation
        else {
            print(
                "REMOTEMAC_AUTO ignoring stale video timing sample"
            )

            return
        }

        let elapsed =
            Double(
                now
                - adaptiveVideoLastEvaluation
            )
            / 1_000_000_000.0

        guard elapsed >= 1.0 else {
            return
        }

        adaptiveVideoLastEvaluation = now

        let congested =
            adaptiveVideoSendsInFlight >= 8
            || adaptiveVideoSendEWMASeconds
                >= 0.120

        let healthy =
            adaptiveVideoSendsInFlight <= 2
            && (
                adaptiveVideoSendEWMASeconds == 0
                || adaptiveVideoSendEWMASeconds
                    <= 0.040
            )

        if congested {
            adaptiveVideoBadWindows += 1
            adaptiveVideoGoodWindows = 0
        } else if healthy {
            adaptiveVideoGoodWindows += 1
            adaptiveVideoBadWindows = 0
        } else {
            adaptiveVideoBadWindows = 0
            adaptiveVideoGoodWindows = 0
        }

        let secondsSinceChange:
            Double

        if now >= adaptiveVideoLastChange {
            secondsSinceChange =
                Double(
                    now
                    - adaptiveVideoLastChange
                )
                / 1_000_000_000.0
        } else {
            secondsSinceChange =
                0
        }

        if adaptiveVideoBadWindows >= 2,
           adaptiveVideoBitrateIndex
                < adaptiveVideoBitrates.count - 1,
           secondsSinceChange >= 2.0 {

            changeAdaptiveVideoBitrate(
                to:
                    adaptiveVideoBitrateIndex + 1,
                reason: "congestion",
                now: now
            )

            return
        }

        if adaptiveVideoGoodWindows >= 10,
           adaptiveVideoBitrateIndex > 0,
           secondsSinceChange >= 8.0 {

            changeAdaptiveVideoBitrate(
                to:
                    adaptiveVideoBitrateIndex - 1,
                reason: "recovery",
                now: now
            )
        }
    }

    private func changeAdaptiveVideoBitrate(
        to newIndex: Int,
        reason: String,
        now: UInt64
    ) {
        guard
            adaptiveVideoBitrates.indices
                .contains(newIndex),
            newIndex
                != adaptiveVideoBitrateIndex
        else {
            return
        }

        let oldBitrate =
            adaptiveVideoBitrates[
                adaptiveVideoBitrateIndex
            ]

        let newBitrate =
            adaptiveVideoBitrates[
                newIndex
            ]

        adaptiveVideoBitrateIndex =
            newIndex

        adaptiveVideoBadWindows = 0
        adaptiveVideoGoodWindows = 0
        adaptiveVideoLastChange = now

        let inFlight =
            adaptiveVideoSendsInFlight

        let latencyMS =
            Int(
                adaptiveVideoSendEWMASeconds
                * 1000.0
            )

        guard let encoder =
            h264Encoder
        else {
            return
        }

        captureQueue.async {
            let status =
                encoder.updateBitrate(
                    newBitrate
                )

            let oldMbps =
                String(
                    format: "%.1f",
                    Double(oldBitrate)
                    / 1_000_000.0
                )

            let newMbps =
                String(
                    format: "%.1f",
                    Double(newBitrate)
                    / 1_000_000.0
                )

            if status == noErr {
                print(
                    "REMOTEMAC_AUTO \(oldMbps) -> \(newMbps) Mbps • \(reason) • inflight \(inFlight) • \(latencyMS) ms"
                )
            } else {
                print(
                    "REMOTEMAC_AUTO bitrate update failed • OSStatus \(status)"
                )
            }
        }
    }

    private func ensureVideoDatagramConnection()
        -> NWConnection?
    {
        if let videoDatagramConnection {
            return videoDatagramConnection
        }

        guard let port =
            NWEndpoint.Port(
                rawValue: 42429
            )
        else {
            return nil
        }

        let connection =
            NWConnection(
                host:
                    NWEndpoint.Host(
                        "127.0.0.1"
                    ),
                port:
                    port,
                using:
                    .udp
            )

        connection.stateUpdateHandler = {
            [weak self, weak connection] state in

            guard
                let self,
                let connection
            else {
                return
            }

            switch state {
            case .failed(let error):
                print(
                    "REMOTEMAC_UDP_VIDEO local sender failed: \(error)"
                )

                if
                    self.videoDatagramConnection
                        === connection
                {
                    self.videoDatagramConnection =
                        nil
                }

            case .cancelled:
                if
                    self.videoDatagramConnection
                        === connection
                {
                    self.videoDatagramConnection =
                        nil
                }

            default:
                break
            }
        }

        videoDatagramConnection =
            connection

        connection.start(
            queue: queue
        )

        return connection
    }

    private func sendVideoFrameDatagram(
        _ data: Data,
        keyFrame: Bool,
        sourceFrameID: UInt32
    ) {
        if videoDatagramSending {
            if
                keyFrame
                || !videoDatagramPendingKeyFrame
            {
                videoDatagramPendingFrame =
                    data

                videoDatagramPendingKeyFrame =
                    keyFrame

                videoDatagramPendingSourceFrameID =
                    sourceFrameID
            }

            videoDatagramDroppedFrames +=
                1

            h264Encoder?
                .requestKeyFrame()

            if
                videoDatagramDroppedFrames
                    % 30 == 0
            {
                print(
                    "REMOTEMAC_UDP_VIDEO sender drops=\(videoDatagramDroppedFrames) latestSourceFrame=\(sourceFrameID)"
                )
            }

            return
        }

        videoDatagramSending =
            true

        sendVideoFrameDatagramNow(
            data,
            keyFrame:
                keyFrame,
            sourceFrameID:
                sourceFrameID
        )
    }

    private func sendVideoFrameDatagramNow(
        _ data: Data,
        keyFrame: Bool,
        sourceFrameID: UInt32
    ) {
        guard let connection =
            ensureVideoDatagramConnection()
        else {
            videoDatagramEnabled =
                false

            finishVideoDatagramFrame()

            return
        }

        do {
            let datagrams =
                try RemoteVideoDatagramCodec
                    .packetize(
                        frame:
                            data,
                        frameID:
                            sourceFrameID,
                        keyFrame:
                            keyFrame
                    )

            sendVideoDatagramFragment(
                datagrams,
                index:
                    0,
                frameID:
                    sourceFrameID,
                frameBytes:
                    data.count,
                connection:
                    connection
            )

        } catch {
            print(
                "REMOTEMAC_UDP_VIDEO packetize failed: \(error)"
            )

            finishVideoDatagramFrame()
        }
    }

    private func sendVideoDatagramFragment(
        _ datagrams: [Data],
        index: Int,
        frameID: UInt32,
        frameBytes: Int,
        connection: NWConnection
    ) {
        guard index < datagrams.count else {
            finishVideoDatagramFrame()
            return
        }

        let burstSize =
            4

        let burstEnd =
            min(
                index + burstSize,
                datagrams.count
            )

        let group =
            DispatchGroup()

        for fragmentIndex in index..<burstEnd {
            group.enter()

            connection.send(
                content:
                    datagrams[
                        fragmentIndex
                    ],
                completion:
                    .contentProcessed {
                        error in

                        if let error {
                            print(
                                "REMOTEMAC_UDP_VIDEO fragment send failed frame=\(frameID) index=\(fragmentIndex) error=\(error)"
                            )
                        }

                        group.leave()
                    }
            )
        }

        group.notify(
            queue:
                queue
        ) { [weak self] in
            guard let self else {
                return
            }

            if burstEnd >= datagrams.count {
                if frameID % 30 == 0 {
                    print(
                        "REMOTEMAC_UDP_VIDEO frame=\(frameID) bytes=\(frameBytes) fragments=\(datagrams.count)"
                    )
                }

                self.finishVideoDatagramFrame()
                return
            }

            self.queue.asyncAfter(
                deadline:
                    .now()
                    + .milliseconds(
                        5
                    )
            ) {
                self.sendVideoDatagramFragment(
                    datagrams,
                    index:
                        burstEnd,
                    frameID:
                        frameID,
                    frameBytes:
                        frameBytes,
                    connection:
                        connection
                )
            }
        }
    }

    private func finishVideoDatagramFrame() {
        videoDatagramSending =
            false

        guard
            let newest =
                videoDatagramPendingFrame,
            let newestSourceFrameID =
                videoDatagramPendingSourceFrameID
        else {
            videoDatagramPendingFrame =
                nil

            videoDatagramPendingSourceFrameID =
                nil

            return
        }

        let newestIsKeyFrame =
            videoDatagramPendingKeyFrame

        videoDatagramPendingFrame =
            nil

        videoDatagramPendingKeyFrame =
            false

        videoDatagramPendingSourceFrameID =
            nil

        sendVideoFrameDatagram(
            newest,
            keyFrame:
                newestIsKeyFrame,
            sourceFrameID:
                newestSourceFrameID
        )
    }

    private func sendVideoFrame(
        _ data: Data,
        isKeyFrame: Bool,
        sourceFrameID: UInt32,
        on connection: NWConnection
    ) {
        if videoDatagramEnabled {
            sendVideoFrameDatagram(
                data,
                keyFrame:
                    isKeyFrame,
                sourceFrameID:
                    sourceFrameID
            )

            return
        }

        let started =
            DispatchTime.now()
                .uptimeNanoseconds

        let generation =
            adaptiveVideoGeneration

        adaptiveVideoSendsInFlight += 1

        evaluateAdaptiveVideoController(
            now: started
        )

        connection.send(
            content:
                RemotePacket
                    .videoFrame(data)
                    .wireData,
            completion:
                .contentProcessed {
                    [weak self] error in

                    guard let self else {
                        return
                    }

                    let finished =
                        DispatchTime.now()
                            .uptimeNanoseconds

                    self.queue.async {
                        guard
                            generation
                                == self.adaptiveVideoGeneration
                        else {
                            return
                        }

                        self.adaptiveVideoSendsInFlight =
                            max(
                                0,
                                self.adaptiveVideoSendsInFlight
                                - 1
                            )

                        let duration =
                            Double(
                                finished
                                - started
                            )
                            / 1_000_000_000.0

                        if self.adaptiveVideoSendEWMASeconds
                            == 0 {

                            self.adaptiveVideoSendEWMASeconds =
                                duration
                        } else {
                            self.adaptiveVideoSendEWMASeconds =
                                (
                                    self.adaptiveVideoSendEWMASeconds
                                    * 0.85
                                )
                                + (
                                    duration
                                    * 0.15
                                )
                        }

                        self.evaluateAdaptiveVideoController(
                            now: finished
                        )

                        if let error {
                            self.publish(
                                event:
                                    "Video send failed: \(error.localizedDescription)"
                            )
                        }
                    }
                }
        )
    }

    private func send(
        _ packet: RemotePacket,
        on connection: NWConnection,
        successEvent: String
    ) {
        debugConnectionEvent(
            "SEND type=\(String(describing: packet.type)) payload=\(packet.payload.count)"
        )

        connection.send(
            content: packet.wireData,
            completion: .contentProcessed { [weak self] error in
                guard let self else {
                    return
                }

                if let error {
                    self.publish(
                        event:
                            "Send failed: \(error.localizedDescription)"
                    )
                } else {
                    self.publish(
                        event: successEvent
                    )
                }
            }
        )
    }

    private func publish(
        status: String? = nil,
        event: String? = nil,
        streaming: Bool? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            if let status {
                self.status = status
            }

            if let event {
                self.lastEvent = event
            }

            if let streaming {
                self.isStreaming = streaming
            }
        }
    }
}
