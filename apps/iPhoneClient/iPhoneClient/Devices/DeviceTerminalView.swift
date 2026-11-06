import SwiftUI
import RemoteProtocol

struct DeviceTerminalRow: View {
    let device:
        RemoteDevice

    let connected:
        Bool

    private var statusText:
        String
    {
        if connected {
            return "Connected"
        }

        return device
            .presence
            .displayName
    }

    private var statusSymbol:
        String
    {
        if connected {
            return "circle.fill"
        }

        switch device.presence {
        case .checking:
            return "arrow.triangle.2.circlepath"

        case .available:
            return "circle.fill"

        case .sleeping:
            return "moon.fill"

        case .offline:
            return "circle"

        case .lowBattery:
            return "battery.25"

        case .noNetwork:
            return "wifi.slash"

        case .unknown:
            return "questionmark.circle"
        }
    }

    var body: some View {
        HStack(
            spacing: 14
        ) {
            Image(
                systemName:
                    device.platform
                        .systemImage
            )
            .font(
                .system(
                    size: 28,
                    weight: .medium
                )
            )
            .frame(
                width: 38
            )

            VStack(
                alignment: .leading,
                spacing: 5
            ) {
                Text(
                    device.name
                )
                .font(.headline)

                Text(
                    device.platform
                        .displayName
                )
                .font(.caption)
                .foregroundStyle(
                    .secondary
                )

                Label(
                    statusText,
                    systemImage:
                        statusSymbol
                )
                .font(.caption)
                .foregroundStyle(
                    connected
                        ? .primary
                        : .secondary
                )

                if
                    !connected,
                    device.presence ==
                        .offline,
                    let lastSeen =
                        device.lastSeen
                {
                    Text(
                        "Last seen \(lastSeen, style: .relative)"
                    )
                    .font(.caption2)
                    .foregroundStyle(
                        .tertiary
                    )
                }
            }

            Spacer()
        }
        .padding(
            .vertical,
            6
        )
    }
}

struct DeviceDetailsView: View {
    @Environment(\.dismiss)
    private var dismiss

    @ObservedObject var registry:
        DeviceRegistry

    @ObservedObject var client:
        RemoteClient

    @ObservedObject var renderer:
        H264VideoRenderer

    let deviceID:
        String

    @Binding var immersiveSession:
        Bool

    @State private var biometricMessage =
        ""

    @State private var draftName =
        ""

    @State private var manualOverrideEnabled =
        false

    @State private var manualHost =
        ""

    @State private var showingRemoveConfirmation =
        false

    @State private var removalError:
        String?

    private var device:
        RemoteDevice?
    {
        registry.devices.first {
            $0.id == deviceID
        }
    }

    private var automaticAddress:
        String
    {
        device?
            .automaticEndpoint?
            .dialAddress
            ?? "Not available"
    }

    private var resolvedMode:
        String
    {
        device?
            .manualEndpointOverride
            == nil
            ? "Automatic"
            : "Manual override"
    }

    var body: some View {
        Form {
            Section {
                connectionPanel
            }

            Section(
                "Device"
            ) {
                HStack {
                    TextField(
                        "Device name",
                        text:
                            $draftName
                    )

                    Button(
                        "Rename"
                    ) {
                        registry.rename(
                            deviceID:
                                deviceID,
                            name:
                                draftName
                        )
                    }
                    .disabled(
                        draftName
                            .trimmingCharacters(
                                in:
                                    .whitespacesAndNewlines
                            )
                            .isEmpty
                    )
                }

                LabeledContent(
                    "Platform",
                    value:
                        device?
                            .platform
                            .displayName
                        ?? "Unknown"
                )

                if
                    let fingerprint =
                        device?
                            .identityFingerprint
                {
                    VStack(
                        alignment: .leading,
                        spacing: 6
                    ) {
                        Text(
                            "Identity"
                        )
                        .foregroundStyle(
                            .secondary
                        )

                        Text(
                            fingerprint
                        )
                        .font(.caption)
                        .monospaced()
                        .textSelection(
                            .enabled
                        )
                    }
                }
            }

            Section(
                "Capabilities"
            ) {
                if
                    let capabilities =
                        device?
                            .capabilities
                            .sorted(
                                by: {
                                    $0.rawValue
                                        < $1.rawValue
                                }
                            )
                {
                    ForEach(
                        capabilities,
                        id: \.rawValue
                    ) { capability in
                        Label(
                            capability
                                .displayName,
                            systemImage:
                                capability
                                    .systemImage
                        )
                    }
                }
            }

            Section(
                "Advanced"
            ) {
                LabeledContent(
                    "Connection",
                    value:
                        resolvedMode
                )

                VStack(
                    alignment: .leading,
                    spacing: 5
                ) {
                    Text(
                        "Automatic route"
                    )
                    .foregroundStyle(
                        .secondary
                    )

                    Text(
                        automaticAddress
                    )
                    .font(.caption)
                    .monospaced()
                    .textSelection(
                        .enabled
                    )
                }

                Toggle(
                    "Manual override",
                    isOn:
                        $manualOverrideEnabled
                )
                .onChange(
                    of:
                        manualOverrideEnabled
                ) { _, enabled in
                    if !enabled {
                        registry
                            .setManualEndpoint(
                                deviceID:
                                    deviceID,
                                host:
                                    nil
                            )

                        activateDevice()
                    }
                }

                if manualOverrideEnabled {
                    TextField(
                        "Host or Tailscale IP",
                        text:
                            $manualHost
                    )
                    .textInputAutocapitalization(
                        .never
                    )
                    .autocorrectionDisabled()

                    Button(
                        "Save Manual Route"
                    ) {
                        registry
                            .setManualEndpoint(
                                deviceID:
                                    deviceID,
                                host:
                                    manualHost
                            )

                        activateDevice()
                    }
                    .disabled(
                        manualHost
                            .trimmingCharacters(
                                in:
                                    .whitespacesAndNewlines
                            )
                            .isEmpty
                    )
                }

                LabeledContent(
                    "Protocol",
                    value:
                        "v\(RemoteProtocolInfo.version)"
                )
            }

            Section {
                Button(
                    "Remove Device",
                    role:
                        .destructive
                ) {
                    showingRemoveConfirmation =
                        true
                }
            } footer: {
                Text(
                    "Removes this device and its trusted pairing key from this iPhone."
                )
            }
        }
        .confirmationDialog(
            "Remove \(device?.name ?? "Device")?",
            isPresented:
                $showingRemoveConfirmation,
            titleVisibility:
                .visible
        ) {
            Button(
                "Remove Device",
                role:
                    .destructive
            ) {
                removeCurrentDevice()
            }

            Button(
                "Cancel",
                role:
                    .cancel
            ) {}
        } message: {
            Text(
                "You will need to pair this device again before connecting to it."
            )
        }
        .alert(
            "Could Not Remove Device",
            isPresented:
                Binding(
                    get: {
                        removalError != nil
                    },
                    set: { presented in
                        if !presented {
                            removalError =
                                nil
                        }
                    }
                )
        ) {
            Button(
                "OK",
                role:
                    .cancel
            ) {}
        } message: {
            Text(
                removalError
                    ?? "Unknown error."
            )
        }
        .navigationTitle(
            device?
                .name
                ?? "Device"
        )
        .navigationBarTitleDisplayMode(
            .inline
        )
        .onAppear {
            loadDeviceState()
            activateDevice()
        }
    }

    private func removeCurrentDevice() {
        if client.isConnected {
            client.disconnect()
        }

        do {
            let fallback =
                try registry
                    .removeDevice(
                        deviceID:
                            deviceID
                    )

            client.setActiveDevice(
                deviceID:
                    fallback?
                        .id,
                endpoint:
                    fallback?
                        .resolvedEndpoint
            )

            dismiss()

        } catch {
            removalError =
                error.localizedDescription
        }
    }

    @ViewBuilder
    private var connectionPanel:
        some View
    {
        VStack(
            alignment: .leading,
            spacing: 14
        ) {
            HStack {
                VStack(
                    alignment: .leading,
                    spacing: 4
                ) {
                    Text(
                        connectionStatus
                    )
                    .font(.headline)

                    Text(
                        connectionDetail
                    )
                    .font(.caption)
                    .foregroundStyle(
                        .secondary
                    )
                }

                Spacer()

                Image(
                    systemName:
                        connectionSymbol
                )
                .font(
                    .title2
                )
            }

            if client.isConnected {
                if client.isAuthenticated {
                    Button {
                        immersiveSession =
                            true
                    } label: {
                        Label(
                            "Start Session",
                            systemImage:
                                "rectangle.inset.filled.and.person.filled"
                        )
                        .frame(
                            maxWidth:
                                .infinity
                        )
                    }
                    .buttonStyle(
                        .borderedProminent
                    )
                    .controlSize(
                        .large
                    )

                } else {
                    ProgressView(
                        "Authenticating…"
                    )
                }

                Button(
                    role:
                        .destructive
                ) {
                    renderer.reset()
                    client.disconnect()
                } label: {
                    Text(
                        "Disconnect"
                    )
                    .frame(
                        maxWidth:
                            .infinity
                    )
                }
                .buttonStyle(
                    .bordered
                )

            } else {
                Button {
                    connect()
                } label: {
                    Label(
                        "Connect",
                        systemImage:
                            "arrow.right.circle.fill"
                    )
                    .frame(
                        maxWidth:
                            .infinity
                    )
                }
                .buttonStyle(
                    .borderedProminent
                )
                .controlSize(
                    .large
                )
                .disabled(
                    device?
                        .resolvedEndpoint
                        == nil
                )
            }

            if !biometricMessage.isEmpty {
                Text(
                    biometricMessage
                )
                .font(.caption)
                .foregroundStyle(
                    .secondary
                )
            }
        }
        .padding(
            .vertical,
            4
        )
    }

    private var connectionStatus:
        String
    {
        if client.isConnected {
            if client.isAuthenticated {
                return "Connected"
            }

            return "Authenticating"
        }

        return device?
            .presence
            .displayName
            ?? "Unknown"
    }

    private var connectionDetail:
        String
    {
        if client.isConnected {
            return client.lastEvent
        }

        switch device?.presence {
        case .checking:
            return "Checking device availability…"

        case .available:
            return "Ready to connect"

        case .sleeping:
            return "Device is sleeping"

        case .offline:
            return "Device is offline"

        case .lowBattery:
            return "Device reports low battery"

        case .noNetwork:
            return "Device has no network"

        case .unknown, .none:
            return "Availability has not been checked yet"
        }
    }

    private var connectionSymbol:
        String
    {
        if client.isConnected {
            return client
                .isAuthenticated
                ? "checkmark.circle.fill"
                : "ellipsis.circle"
        }

        return "circle"
    }

    private func loadDeviceState() {
        guard let device else {
            return
        }

        draftName =
            device.name

        manualOverrideEnabled =
            device
                .manualEndpointOverride
                != nil

        manualHost =
            device
                .manualEndpointOverride?
                .host
            ?? ""
    }

    private func activateDevice() {
        guard let device else {
            return
        }

        registry.select(
            deviceID:
                device.id
        )

        client.setActiveDevice(
            deviceID:
                device.id,
            endpoint:
                device.resolvedEndpoint
        )

        if
            let endpoint =
                device
                    .resolvedEndpoint
        {
            client.host =
                endpoint.host
        }

        client.refreshPairingState()
    }

    private func connect() {
        activateDevice()

        Task {
            biometricMessage =
                "Checking Face ID…"

            let result =
                await BiometricGate
                    .authenticate()

            switch result {
            case .success:
                biometricMessage =
                    ""

                client.connect()

            case .failed(
                let message
            ):
                biometricMessage =
                    message
            }
        }
    }
}

private extension RemotePlatform {
    var displayName:
        String
    {
        switch self {
        case .macOS:
            return "macOS"

        case .windows:
            return "Windows"

        case .linux:
            return "Linux"

        case .iOS:
            return "iPhone"

        case .iPadOS:
            return "iPad"

        case .unknown:
            return "Unknown"
        }
    }

    var systemImage:
        String
    {
        switch self {
        case .macOS:
            return "laptopcomputer"

        case .windows:
            return "desktopcomputer"

        case .linux:
            return "terminal"

        case .iOS:
            return "iphone"

        case .iPadOS:
            return "ipad"

        case .unknown:
            return "questionmark.square"
        }
    }
}

private extension RemotePresence {
    var displayName:
        String
    {
        switch self {
        case .unknown:
            return "Unknown"

        case .checking:
            return "Checking…"

        case .available:
            return "Available"

        case .sleeping:
            return "Sleeping"

        case .offline:
            return "Offline"

        case .lowBattery:
            return "Low Battery"

        case .noNetwork:
            return "No Network"
        }
    }
}

private extension RemoteCapability {
    var displayName:
        String
    {
        switch self {
        case .screen:
            return "Screen"

        case .pointer:
            return "Pointer"

        case .keyboard:
            return "Keyboard"

        case .notifications:
            return "Notifications"
        }
    }

    var systemImage:
        String
    {
        switch self {
        case .screen:
            return "rectangle.on.rectangle"

        case .pointer:
            return "cursorarrow"

        case .keyboard:
            return "keyboard"

        case .notifications:
            return "bell"
        }
    }
}
