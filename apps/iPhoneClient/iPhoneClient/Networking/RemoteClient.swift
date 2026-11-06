import Foundation
import CryptoKit
import Network
import Combine
import RemoteProtocol
import TailscaleKit

final class RemoteClient: ObservableObject, @unchecked Sendable {
    @Published var host =
        UserDefaults.standard.string(
            forKey: "RemoteMacHost"
        ) ?? "your-mac.your-tailnet.ts.net"

    @Published private(set) var status = "Disconnected"
    @Published private(set) var lastEvent = "Enter your Mac's Tailscale IP"

    @Published private(set) var isConnected = false
    @Published private(set) var isStreaming = false

    @Published private(set) var frameData: Data?

    @Published private(set) var h264ConfigReceived = false
    @Published private(set) var h264FramesReceived = 0
    @Published private(set) var h264BytesReceived = 0

    @Published private(set) var h264ReceiveFPS:
        Double = 0

    @Published private(set) var h264ReceiveMbps:
        Double = 0

    private var h264TotalFrames = 0
    private var h264TotalBytes = 0

    private var h264StatsFrames = 0
    private var h264StatsBytes = 0

    private var h264StatsStart =
        DispatchTime.now()
            .uptimeNanoseconds

    @Published private(set) var pairedMacFingerprint: String?
    @Published private(set) var pairingMessage = ""

    @Published private(set) var isAuthenticated = false

    private var rxStatsFrames = 0
    private var rxStatsBytes = 0

    private var rxStatsStart =
        DispatchTime.now()
            .uptimeNanoseconds

    private var authenticationChallenge: Data?
    private var macSignatureVerified = false
    private var macAcceptedClient = false

    private let queue = DispatchQueue(
        label: "com.example.remotemac.client"
    )

    private var connection: NWConnection?
    private var parser = RemotePacketParser()

    private var udpVideoTask: Task<Void, Never>?
    private var udpVideoActive = false
    private var selectedVideoHost: String?

    private var pointerPendingDX =
        0.0

    private var pointerPendingDY =
        0.0

    private var pointerFlushScheduled =
        false

    private let pointerFlushIntervalNanoseconds =
        11_111_111



    private var activeDeviceID:
        String?

    private var activeEndpoint:
        RemoteEndpoint?

    private var onH264Config:
        (@Sendable (RemoteH264Config) -> Void)?

    private var onH264Frame:
        (@Sendable (Data) -> Void)?

    func setActiveDevice(
        deviceID: String?,
        endpoint: RemoteEndpoint?
    ) {
        let cleaned =
            deviceID?
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        queue.async { [weak self] in
            guard let self else {
                return
            }

            let newDeviceID:
                String?

            if
                let cleaned,
                !cleaned.isEmpty
            {
                newDeviceID =
                    cleaned
            } else {
                newDeviceID =
                    nil
            }

            let changed =
                self.activeDeviceID
                != newDeviceID

            self.activeDeviceID =
                newDeviceID

            self.activeEndpoint =
                endpoint

            if changed {
                DispatchQueue.main.async {
                    self.pairedMacFingerprint =
                        nil

                    self.pairingMessage =
                        ""
                }
            }

            print(
                "REMOTEMAC_CLIENT active device route configured"
            )
        }
    }

    func setVideoHandlers(
        onConfig:
            @escaping @Sendable (RemoteH264Config) -> Void,
        onFrame:
            @escaping @Sendable (Data) -> Void
    ) {
        queue.async { [weak self] in
            self?.onH264Config = onConfig
            self?.onH264Frame = onFrame
        }
    }

    private func beginAuthentication(
        on connection: NWConnection
    ) {
        do {
            guard
                let activeDeviceID,
                try DevicePairingStore
                    .load(
                        for:
                            activeDeviceID
                    ) != nil
            else {
                authenticationChallenge =
                    nil

                macSignatureVerified =
                    false

                macAcceptedClient =
                    false

                DispatchQueue.main.async {
                    self.isAuthenticated =
                        false
                }

                publish(
                    status: "Connected",
                    event:
                        "Pairing required",
                    connected: true
                )

                return
            }

            let challenge =
                try SessionAuthentication
                    .makeChallenge()

            authenticationChallenge =
                challenge

            macSignatureVerified =
                false

            macAcceptedClient =
                false

            DispatchQueue.main.async {
                self.isAuthenticated =
                    false
            }

            publish(
                status:
                    "Authenticating…",
                event:
                    "Verifying paired Mac",
                connected: true
            )

            send(
                .authChallenge(
                    challenge
                ),
                on: connection
            )

        } catch {
            publish(
                status:
                    "Authentication failed",
                event:
                    error.localizedDescription,
                connected: true
            )
        }
    }

    private func respondToAuthenticationChallenge(
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
                on: connection
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
                on: connection
            )

        } catch {
            publish(
                status:
                    "Authentication failed",
                event:
                    error.localizedDescription,
                connected: true
            )
        }
    }

    private func verifyMacSignature(
        _ signature: Data
    ) {
        guard let challenge =
            authenticationChallenge
        else {
            return
        }

        do {
            guard
                let activeDeviceID,
                let pairedMacKey =
                    try DevicePairingStore
                        .load(
                            for:
                                activeDeviceID
                        )
            else {
                publish(
                    status:
                        "Authentication failed",
                    event:
                        "No paired Mac identity",
                    connected: true
                )

                return
            }

            let valid =
                DeviceIdentity.verify(
                    signature: signature,
                    for: challenge,
                    publicKeyData:
                        pairedMacKey
                )

            guard valid else {
                authenticationChallenge =
                    nil

                macSignatureVerified =
                    false

                DispatchQueue.main.async {
                    self.isAuthenticated =
                        false
                }

                publish(
                    status:
                        "Authentication rejected",
                    event:
                        "Mac signature did not match paired identity",
                    connected: true
                )

                return
            }

            authenticationChallenge =
                nil

            macSignatureVerified =
                true

            finishAuthenticationIfReady()

        } catch {
            publish(
                status:
                    "Authentication failed",
                event:
                    error.localizedDescription,
                connected: true
            )
        }
    }

    func syncAPNSTokenIfPossible() {
        queue.async { [weak self] in
            guard
                let self,
                self.macSignatureVerified,
                self.macAcceptedClient,
                let connection =
                    self.connection,
                let token =
                    UserDefaults.standard
                        .string(
                            forKey:
                                "RemoteMacAPNSDeviceToken"
                        )?
                        .trimmingCharacters(
                            in:
                                .whitespacesAndNewlines
                        ),
                !token.isEmpty
            else {
                return
            }

            self.send(
                .apnsDeviceToken(
                    token
                ),
                on:
                    connection
            )

            print(
                "REMOTEMAC_APNS token synced to Mac"
            )
        }
    }

    private func finishAuthenticationIfReady() {
        guard
            macSignatureVerified,
            macAcceptedClient
        else {
            return
        }

        DispatchQueue.main.async {
            self.isAuthenticated =
                true
        }

        publish(
            status: "Authenticated ✓",
            event:
                "Paired Mac verified",
            connected: true
        )

        if let connection =
            connection
        {
            if let token =
                UserDefaults.standard
                    .string(
                        forKey:
                            "RemoteMacAPNSDeviceToken"
                    )?
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    ),
               !token.isEmpty
            {
                send(
                    .apnsDeviceToken(
                        token
                    ),
                    on: connection
                )
            }

            send(
                .ping,
                on: connection
            )

            startUDPVideoReceiver(
                on: connection
            )
        }
    }

    private func stopUDPVideoReceiver() {
        udpVideoTask?.cancel()
        udpVideoTask =
            nil

        udpVideoActive =
            false
    }

    private func startUDPVideoReceiver(
        on controlConnection: NWConnection
    ) {
        stopUDPVideoReceiver()

        guard let videoHost = selectedVideoHost,
              !videoHost.isEmpty else {
            print("REMOTEMAC_UDP_VIDEO missing host; using TCP")
            return
        }

        udpVideoTask =
            Task {
                [weak self] in

                guard let self else {
                    return
                }

                let address =
                    "\(videoHost):42428"

                while !Task.isCancelled {
                    var udp:
                        DatagramConnection?

                    do {
                        let connection =
                            try await TailscaleKitProbe
                                .shared
                                .makeDatagramConnection(
                                    to:
                                        address,
                                    maxAttempts:
                                        25
                                )

                        udp =
                            connection

                        try await connection.send(
                            Data(
                                "RMVIDEO1".utf8
                            )
                        )

                        let ack =
                            try await connection.receive(
                                maximumLength:
                                    64,
                                timeout:
                                    3000
                            )

                        guard
                            ack
                                == Data(
                                    "RMVIDEOACK1".utf8
                                )
                        else {
                            throw EmbeddedTailscaleBridgeError
                                .tailnetNotReady
                        }

                        self.queue.async {
                            [weak self, weak controlConnection] in

                            guard
                                let self,
                                let controlConnection,
                                self.connection
                                    === controlConnection
                            else {
                                return
                            }

                            self.udpVideoActive =
                                true

                            self.send(
                                RemotePacket(
                                    type:
                                        .videoDatagramState,
                                    payload:
                                        Data(
                                            [1]
                                        )
                                ),
                                on:
                                    controlConnection
                            )

                            print(
                                "REMOTEMAC_UDP_VIDEO IPHONE_ACTIVE"
                            )
                        }

                        var assembler =
                            RemoteVideoFrameAssembler()

                        var waitingForKeyFrame =
                            true

                        var keyFrameRequested =
                            false

                        var lastCompletedFrameID:
                            UInt32?

                        while !Task.isCancelled {
                            do {
                                let datagram =
                                    try await connection.receive(
                                        maximumLength:
                                            RemoteVideoDatagramCodec
                                                .maxDatagramSize,
                                        timeout:
                                            1000
                                    )

                                if let completed =
                                    try assembler.ingest(
                                        datagram
                                    )
                                {
                                    let expectedFrameID =
                                        lastCompletedFrameID
                                            .map {
                                                $0 &+ 1
                                            }

                                    let frameGap =
                                        expectedFrameID != nil
                                        && completed.frameID
                                            != expectedFrameID

                                    lastCompletedFrameID =
                                        completed.frameID

                                    if frameGap {
                                        waitingForKeyFrame =
                                            true

                                        keyFrameRequested =
                                            false

                                        print(
                                            "REMOTEMAC_UDP_VIDEO FRAME_GAP expected=\(expectedFrameID ?? 0) received=\(completed.frameID)"
                                        )
                                    }

                                    if waitingForKeyFrame {
                                        if completed.isKeyFrame {
                                            waitingForKeyFrame =
                                                false

                                            keyFrameRequested =
                                                false

                                            print(
                                                "REMOTEMAC_UDP_VIDEO IDR_RECOVERED frame=\(completed.frameID)"
                                            )

                                        } else {
                                            if !keyFrameRequested {
                                                keyFrameRequested =
                                                    true

                                                self.queue.async {
                                                    [weak self, weak controlConnection] in

                                                    guard
                                                        let self,
                                                        let controlConnection,
                                                        self.connection
                                                            === controlConnection
                                                    else {
                                                        return
                                                    }

                                                    self.send(
                                                        RemotePacket(
                                                            type:
                                                                .requestVideoKeyFrame
                                                        ),
                                                        on:
                                                            controlConnection
                                                    )

                                                    print(
                                                        "REMOTEMAC_UDP_VIDEO IDR_REQUEST_SENT"
                                                    )
                                                }
                                            }

                                            continue
                                        }
                                    }

                                    let frameData =
                                        completed.data

                                    let frameID =
                                        completed.frameID

                                    self.queue.async {
                                        [weak self] in

                                        guard let self else {
                                            return
                                        }

                                        guard self.udpVideoActive else {
                                            return
                                        }

                                        self.h264TotalFrames +=
                                            1

                                        self.h264TotalBytes +=
                                            frameData.count

                                        self.onH264Frame?(
                                            frameData
                                        )

                                        let frames =
                                            self.h264TotalFrames

                                        let bytes =
                                            self.h264TotalBytes

                                        DispatchQueue.main.async {
                                            self.h264FramesReceived =
                                                frames

                                            self.h264BytesReceived =
                                                bytes

                                            self.status =
                                                "H.264 UDP live"

                                            if frameID % 60 == 0 {
                                                self.lastEvent =
                                                    "UDP frame \(frameID) • \(frameData.count) B"
                                            }
                                        }
                                    }
                                }

                            } catch
                                DatagramConnectionError.timeout
                            {
                                continue
                            }
                        }

                        await connection.close()

                        return

                    } catch {
                        if let udp {
                            await udp.close()
                        }

                        self.queue.async {
                            [weak self, weak controlConnection] in

                            guard
                                let self,
                                let controlConnection,
                                self.connection
                                    === controlConnection
                            else {
                                return
                            }

                            let wasActive =
                                self.udpVideoActive

                            self.udpVideoActive =
                                false

                            if wasActive {
                                self.send(
                                    RemotePacket(
                                        type:
                                            .videoDatagramState,
                                        payload:
                                            Data(
                                                [0]
                                            )
                                    ),
                                    on:
                                        controlConnection
                                )
                            }

                            print(
                                "REMOTEMAC_UDP_VIDEO receiver retry: \(error)"
                            )
                        }

                        if Task.isCancelled {
                            return
                        }

                        try? await Task.sleep(
                            nanoseconds:
                                400_000_000
                        )
                    }
                }
            }
    }

    func refreshPairingState() {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            do {
                guard
                    let activeDeviceID
                else {
                    DispatchQueue.main.async {
                        self.pairedMacFingerprint =
                            nil
                    }

                    return
                }

                let fingerprint =
                    try DevicePairingStore
                        .fingerprint(
                            for:
                                activeDeviceID
                        )

                DispatchQueue.main.async {
                    self.pairedMacFingerprint =
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

    func requestPairing() {
        queue.async { [weak self] in
            guard
                let self,
                let connection =
                    self.connection
            else {
                return
            }

            do {
                let identity =
                    try DeviceIdentityStore
                        .loadOrCreate()

                self.send(
                    .pairRequest(
                        publicKey:
                            identity.publicKeyData
                    ),
                    on: connection
                )

                DispatchQueue.main.async {
                    self.pairingMessage =
                        "Pair request sent. Approve it on your Mac."
                }

            } catch {
                self.publish(
                    event:
                        "Could not request pairing: \(error.localizedDescription)"
                )
            }
        }
    }

    func forgetPairedMac() {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            do {
                guard
                    let activeDeviceID
                else {
                    self.publish(
                        event:
                            "No selected device to forget"
                    )

                    return
                }

                try DevicePairingStore
                    .delete(
                        for:
                            activeDeviceID
                    )

                DispatchQueue.main.async {
                    self.pairedMacFingerprint =
                        nil

                    self.pairingMessage =
                        "Paired device forgotten"
                }

            } catch {
                self.publish(
                    event:
                        "Could not forget Mac: \(error.localizedDescription)"
                )
            }
        }
    }

    func connect() {
        print(
            "REMOTEMAC_CLIENT connect() ENTERED"
        )

        let configuredEndpoint =
            queue.sync {
                activeEndpoint
            }

        let legacyHost =
            host.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        let endpoint:
            RemoteEndpoint

        if let configuredEndpoint {
            endpoint =
                configuredEndpoint
        } else {
            guard !legacyHost.isEmpty else {
                publish(
                    status:
                        "No device endpoint",
                    event:
                        "The selected device has no connection route",
                    connected:
                        false
                )

                return
            }

            endpoint =
                RemoteEndpoint(
                    host:
                        legacyHost,
                    port:
                        RemoteProtocolInfo.port
                )
        }

        let hostValue =
            endpoint.host

        UserDefaults.standard.set(
            hostValue,
            forKey:
                "RemoteMacHost"
        )

        guard
            let port =
                NWEndpoint.Port(
                    rawValue:
                        EmbeddedTailscaleBridgeConfig
                            .localPort
                )
        else {
            publish(
                status: "Error",
                event:
                    "Invalid protocol port",
                connected: false
            )

            return
        }

        publish(
            status:
                "Preparing connection…",
            event:
                "Checking embedded transport",
            connected:
                false,
            streaming:
                false
        )

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let bridgeReady =
                await EmbeddedTailscaleBridge
                    .shared
                    .prepareForConnection(
                        endpoint:
                            endpoint
                    )

            guard bridgeReady else {
                self.publish(
                    status:
                        "Waiting",
                    event:
                        "Embedded transport is not ready yet",
                    connected:
                        false,
                    streaming:
                        false
                )

                return
            }

            self.connectToReadyBridge(
                hostValue:
                    hostValue,
                port:
                    port
            )
        }
    }

    private func connectToReadyBridge(
        hostValue: String,
        port: NWEndpoint.Port
    ) {
        queue.async { [weak self] in
            self?.stopUDPVideoReceiver()
        }

        queue.async { [weak self] in
            guard let self else {
                return
            }

            self.connection?
                .cancel()

            self.parser =
                RemotePacketParser()

            let connection =
                NWConnection(
                    host:
                        NWEndpoint.Host(
                            EmbeddedTailscaleBridgeConfig
                                .localHost
                        ),
                    port:
                        port,
                    using:
                        .tcp
                )

            self.selectedVideoHost = hostValue

            self.connection =
                connection

            self.publish(
                status:
                    "Connecting…",
                event:
                    "Embedded → \(hostValue):\(RemoteProtocolInfo.port)",
                connected:
                    false,
                streaming:
                    false
            )

            connection.stateUpdateHandler = {
                [weak self] state in

                guard let self else {
                    return
                }

                switch state {
                case .ready:
                    self.publish(
                        status:
                            "Connected",
                        event:
                            "Sending ping…",
                        connected:
                            true,
                        streaming:
                            false
                    )

                    self.receive(
                        on:
                            connection
                    )

                    self.beginAuthentication(
                        on:
                            connection
                    )

                case .waiting(let error):
                    self.publish(
                        status:
                            "Waiting",
                        event:
                            error.localizedDescription,
                        connected:
                            false,
                        streaming:
                            false
                    )

                case .failed(let error):
                    self.publish(
                        status:
                            "Failed",
                        event:
                            error.localizedDescription,
                        connected:
                            false,
                        streaming:
                            false
                    )

                case .cancelled:
                    self.publish(
                        status:
                            "Disconnected",
                        event:
                            "Connection closed",
                        connected:
                            false,
                        streaming:
                            false
                    )

                default:
                    break
                }
            }

            connection.start(
                queue:
                    self.queue
            )
        }
    }

    func startStream() {
        queue.async { [weak self] in
            guard
                let self,
                let connection = self.connection
            else {
                return
            }

            self.h264FramesReceived = 0
            self.h264BytesReceived = 0
            self.h264ConfigReceived = false

            self.publish(
                status: "Starting H.264…",
                event: "Requesting hardware video",
                connected: true,
                streaming: true
            )

            self.send(
                .startStream,
                on: connection
            )
        }
    }

    func stopStream() {
        queue.async { [weak self] in
            guard
                let self,
                let connection = self.connection
            else {
                return
            }

            self.send(
                .stopStream,
                on: connection
            )

            self.publish(
                status: "Connected",
                event: "Video stream stopped",
                connected: true,
                streaming: false
            )
        }
    }

    func requestFrame() {
        queue.async { [weak self] in
            guard
                let self,
                let connection = self.connection
            else {
                return
            }

            self.send(
                .requestFrame,
                on: connection
            )
        }
    }

    func movePointer(
        dx: CGFloat,
        dy: CGFloat
    ) {
        let dxValue =
            Double(dx)

        let dyValue =
            Double(dy)

        queue.async {
            [weak self] in

            guard let self else {
                return
            }

            self.pointerPendingDX +=
                dxValue

            self.pointerPendingDY +=
                dyValue

            self.schedulePointerFlushIfNeeded()
        }
    }

    private func schedulePointerFlushIfNeeded() {
        guard !pointerFlushScheduled else {
            return
        }

        pointerFlushScheduled =
            true

        queue.asyncAfter(
            deadline:
                .now()
                + .nanoseconds(
                    pointerFlushIntervalNanoseconds
                )
        ) { [weak self] in
            self?.flushPointerDelta()
        }
    }

    private func flushPointerDelta() {
        pointerFlushScheduled =
            false

        guard let connection else {
            pointerPendingDX =
                0

            pointerPendingDY =
                0

            return
        }

        let dx64 =
            Int64(
                pointerPendingDX.rounded()
            )

        let dy64 =
            Int64(
                pointerPendingDY.rounded()
            )

        guard
            dx64 != 0
            || dy64 != 0
        else {
            return
        }

        let sendDX =
            Int32(
                clamping:
                    dx64
            )

        let sendDY =
            Int32(
                clamping:
                    dy64
            )

        pointerPendingDX -=
            Double(sendDX)

        pointerPendingDY -=
            Double(sendDY)

        send(
            .pointerDelta(
                RemotePointerDelta(
                    dx:
                        sendDX,
                    dy:
                        sendDY
                )
            ),
            on:
                connection
        )

        if
            abs(pointerPendingDX)
                >= 0.5
            || abs(pointerPendingDY)
                >= 0.5
        {
            schedulePointerFlushIfNeeded()
        }
    }

    func movePointerAbsolute(
        x: CGFloat,
        y: CGFloat
    ) {
        queue.async { [weak self] in
            guard
                let self,
                let connection =
                    self.connection
            else {
                return
            }

            let position =
                RemotePointerPosition(
                    normalizedX:
                        Double(x),
                    normalizedY:
                        Double(y)
                )

            self.send(
                .pointerAbsolute(
                    position
                ),
                on: connection
            )
        }
    }

    func leftClick() {
        sendMouse(
            button: .left,
            action: .click
        )
    }

    func rightClick() {
        sendMouse(
            button: .right,
            action: .click
        )
    }

    func doubleClick() {
        sendMouse(
            button: .left,
            action: .doubleClick
        )
    }

    func leftMouseDown() {
        sendMouse(
            button: .left,
            action: .down
        )
    }

    func leftMouseUp() {
        sendMouse(
            button: .left,
            action: .up
        )
    }

    func scroll(
        dx: CGFloat,
        dy: CGFloat
    ) {
        queue.async { [weak self] in
            guard
                let self,
                let connection = self.connection
            else {
                return
            }

            let delta = RemoteScrollDelta(
                dx: Int32(dx.rounded()),
                dy: Int32(dy.rounded())
            )

            self.send(
                .scroll(
                    delta
                ),
                on: connection
            )
        }
    }

    private func sendMouse(
        button: RemoteMouseButton,
        action: RemoteButtonAction
    ) {
        queue.async { [weak self] in
            guard
                let self,
                let connection = self.connection
            else {
                return
            }

            let event =
                RemoteMouseButtonEvent(
                    button: button,
                    action: action
                )

            self.send(
                .mouseButton(
                    event
                ),
                on: connection
            )
        }
    }

    func sendText(
        _ text: String,
        modifiers: RemoteModifierFlags = []
    ) {
        guard !text.isEmpty else {
            return
        }

        if modifiers.isEmpty {
            queue.async { [weak self] in
                guard
                    let self,
                    let connection =
                        self.connection
                else {
                    return
                }

                self.send(
                    .textInput(text),
                    on: connection
                )
            }

            return
        }

        for character in text {
            guard let keyCode =
                MacKeyCode.character(
                    character
                )
            else {
                continue
            }

            sendKey(
                keyCode,
                modifiers: modifiers
            )
        }
    }

    func sendKey(
        _ keyCode: UInt16,
        modifiers: RemoteModifierFlags = []
    ) {
        queue.async { [weak self] in
            guard
                let self,
                let connection =
                    self.connection
            else {
                return
            }

            let event =
                RemoteKeyEvent(
                    keyCode: keyCode,
                    action: .press,
                    modifiers: modifiers
                )

            self.send(
                .keyEvent(event),
                on: connection
            )
        }
    }

    func sendPing() {
        queue.async { [weak self] in
            guard
                let self,
                let connection = self.connection
            else {
                return
            }

            self.send(
                .ping,
                on: connection
            )
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.stopUDPVideoReceiver()
        }

        queue.async { [weak self] in
            guard let self else {
                return
            }

            guard let connection = self.connection else {
                self.publish(
                    status: "Disconnected",
                    event: "No active connection",
                    connected: false,
                    streaming: false
                )

                return
            }

            connection.send(
                content:
                    RemotePacket.disconnect.wireData,
                completion:
                    .contentProcessed { [weak self] _ in
                        guard let self else {
                            return
                        }

                        connection.stateUpdateHandler = nil
                        connection.cancel()

                        self.connection = nil
                        self.parser =
                            RemotePacketParser()

                        Task { [weak self] in
                            await EmbeddedTailscaleBridge
                                .shared
                                .rearmAfterDisconnect()

                            guard let self else {
                                return
                            }

                            self.publish(
                                status:
                                    "Disconnected",
                                event:
                                    "Connection closed",
                                connected:
                                    false,
                                streaming:
                                    false
                            )
                        }
                    }
            )
        }
    }

    private func send(
        _ packet: RemotePacket,
        on connection: NWConnection
    ) {
        connection.send(
            content: packet.wireData,
            completion:
                .contentProcessed { [weak self] error in
                    guard let self else {
                        return
                    }

                    if let error {
                        self.publish(
                            event:
                                "Send failed: \(error.localizedDescription)"
                        )
                    }
                }
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

            if let data, !data.isEmpty {
                do {
                    let packets =
                        try self.parser.append(
                            data
                        )

                    for packet in packets {
                        self.process(
                            packet
                        )
                    }
                } catch {
                    connection.cancel()

                    self.connection = nil
                    self.parser =
                        RemotePacketParser()

                    self.publish(
                        status: "Protocol error",
                        event: "\(error)",
                        connected: false,
                        streaming: false
                    )

                    return
                }
            }

            if let error {
                self.connection = nil
                self.parser =
                    RemotePacketParser()

                self.publish(
                    status: "Connection error",
                    event: error.localizedDescription,
                    connected: false,
                    streaming: false
                )

                return
            }

            if isComplete {
                self.connection = nil
                self.parser =
                    RemotePacketParser()

                self.publish(
                    status: "Disconnected",
                    event: "Mac closed connection",
                    connected: false,
                    streaming: false
                )

                return
            }

            self.receive(
                on: connection
            )
        }
    }

    private func process(
        _ packet: RemotePacket
    ) {
        switch packet.type {
        case .pong:
            publish(
                status: "Connected",
                event: "Received pong ✓",
                connected: true
            )

        case .videoConfig:
            guard let config =
                RemoteH264Config(
                    payload: packet.payload
                )
            else {
                publish(
                    status: "H.264 error",
                    event:
                        "Invalid H.264 configuration",
                    connected: true,
                    streaming: false
                )

                return
            }

            onH264Config?(
                config
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                self.h264ConfigReceived = true
                self.status = "H.264 live"

                self.lastEvent =
                    "SPS \(config.sps.count) B • PPS \(config.pps.count) B"
            }

        case .videoFrame:
            if udpVideoActive {
                return
            }

            let data = packet.payload

            h264TotalFrames += 1
            h264TotalBytes += data.count

            rxStatsFrames += 1
            rxStatsBytes += data.count

            let rxNow =
                DispatchTime.now()
                    .uptimeNanoseconds

            let rxElapsed =
                Double(
                    rxNow - rxStatsStart
                )
                / 1_000_000_000.0

            if rxElapsed >= 1.0 {
                let rxFPS =
                    Double(
                        rxStatsFrames
                    )
                    / rxElapsed

                let rxMbps =
                    Double(
                        rxStatsBytes
                    )
                    * 8.0
                    / rxElapsed
                    / 1_000_000.0

                print(
                    String(
                        format:
                            "REMOTEMAC_RX %.1f FPS %.2f Mbps",
                        rxFPS,
                        rxMbps
                    )
                )

                let totalFrames =
                    h264TotalFrames

                let totalBytes =
                    h264TotalBytes

                DispatchQueue.main.async {
                    [weak self] in

                    guard let self else {
                        return
                    }

                    self.h264FramesReceived =
                        totalFrames

                    self.h264BytesReceived =
                        totalBytes

                    self.h264ReceiveFPS =
                        rxFPS

                    self.h264ReceiveMbps =
                        rxMbps

                    self.status =
                        "H.264 live"

                    self.lastEvent =
                        String(
                            format:
                                "RX %.1f FPS • %.2f Mbps",
                            rxFPS,
                            rxMbps
                        )
                }

                rxStatsFrames = 0
                rxStatsBytes = 0
                rxStatsStart = rxNow
            }

            onH264Frame?(
                data
            )

        case .taskCompleted:
            guard
                let completion =
                    RemoteTaskCompletion(
                        payload: packet.payload
                    )
            else {
                publish(
                    event:
                        "Invalid task completion event"
                )

                return
            }

            Task { @MainActor [weak self] in
                RemoteMacAppDelegate
                    .postTaskCompletion(
                        completion
                    )

                self?.lastEvent =
                    "\(completion.deviceName) finished \(completion.task)"
            }

        case .frame:
            DispatchQueue.main.async { [weak self] in
                self?.frameData =
                    packet.payload
            }

        case .captureError:
            let message = String(
                data: packet.payload,
                encoding: .utf8
            ) ?? "Unknown capture error"

            publish(
                status: "Capture failed",
                event: message,
                connected: true,
                streaming: false
            )

        case .disconnect:
            publish(
                status: "Disconnected",
                event: "Mac requested disconnect",
                connected: false,
                streaming: false
            )

        case .ping:
            publish(
                event:
                    "Received unexpected ping"
            )

        case .requestFrame:
            publish(
                event:
                    "Received unexpected frame request"
            )

        case .startStream:
            publish(
                event:
                    "Received unexpected start message"
            )

        case .stopStream:
            publish(
                event:
                    "Received unexpected stop message"
            )

        case .requestVideoKeyFrame:
            publish(
                event:
                    "Received unexpected keyframe request"
            )

        case .videoDatagramState:
            publish(
                event:
                    "Received unexpected UDP video state packet"
            )

        case .pointerDelta:
            break

        case .mouseButton:
            break

        case .scroll:
            break

        case .keyEvent:
            break

        case .textInput:
            break

        case .pointerAbsolute:
            break

        case .pairRequest:
            break

        case .pairApproved:
            guard
                (try? Curve25519.Signing.PublicKey(
                    rawRepresentation:
                        packet.payload
                )) != nil
            else {
                DispatchQueue.main.async {
                    self.pairingMessage =
                        "Mac sent an invalid public key."
                }

                return
            }

            do {
                guard
                    let activeDeviceID
                else {
                    DispatchQueue.main.async {
                        self.pairingMessage =
                            "No selected device for pairing."
                    }

                    return
                }

                let fingerprint =
                    DeviceIdentity.fingerprint(
                        for:
                            packet.payload
                    )

                if
                    activeDeviceID
                        .hasPrefix(
                            "identity:"
                        ),
                    activeDeviceID !=
                        "identity:\(fingerprint)"
                {
                    DispatchQueue.main.async {
                        self.pairingMessage =
                            "Pairing identity does not match the selected device."
                    }

                    return
                }

                try DevicePairingStore
                    .save(
                        publicKeyData:
                            packet.payload,
                        for:
                            activeDeviceID
                    )

                DispatchQueue.main.async {
                    self.pairedMacFingerprint =
                        fingerprint

                    self.pairingMessage =
                        "Pairing complete ✓"
                }

            } catch {
                DispatchQueue.main.async {
                    self.pairingMessage =
                        "Could not save paired Mac: \(error.localizedDescription)"
                }
            }

        case .pairRejected:
            DispatchQueue.main.async {
                self.pairingMessage =
                    "Pair request rejected."
            }

        case .apnsDeviceToken:
            publish(
                event:
                    "Received unexpected APNs device token"
            )

        case .authChallenge:
            guard let connection =
                self.connection
            else {
                return
            }

            respondToAuthenticationChallenge(
                packet.payload,
                on: connection
            )

        case .authResponse:
            verifyMacSignature(
                packet.payload
            )

        case .authAccepted:
            macAcceptedClient =
                true

            finishAuthenticationIfReady()

        case .authRejected:
            macAcceptedClient =
                false

            macSignatureVerified =
                false

            DispatchQueue.main.async {
                self.isAuthenticated =
                    false
            }

            publish(
                status:
                    "Authentication rejected",
                event:
                    "Mac rejected this device",
                connected: true
            )
        }
    }

    private func publish(
        status: String? = nil,
        event: String? = nil,
        connected: Bool? = nil,
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

            if let connected {
                self.isConnected = connected
            }

            if let streaming {
                self.isStreaming = streaming
            }
        }
    }
}
