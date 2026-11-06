import SwiftUI
import RemoteProtocol

struct TailnetPeerCandidate:
    Identifiable,
    Sendable
{
    let id:
        String

    let name:
        String

    let dnsName:
        String

    let endpoint:
        RemoteEndpoint

    let online:
        Bool
}

actor RemoteMacDiscoveryService {
    static let shared =
        RemoteMacDiscoveryService()

    private var currentScan:
        Task<
            [TailnetPeerCandidate],
            Error
        >?

    func discover(
        excludingHosts:
            Set<String>
    ) async throws
        -> [TailnetPeerCandidate]
    {
        if let currentScan {
            print(
                "REMOTEMAC_DISCOVERY reusing in-flight scan"
            )

            return try await
                currentScan.value
        }

        let task =
            Task<
                [TailnetPeerCandidate],
                Error
            > {
                try await Self
                    .performDiscovery(
                        excludingHosts:
                            excludingHosts
                    )
            }

        currentScan =
            task

        do {
            let result =
                try await task.value

            currentScan =
                nil

            return result

        } catch {
            currentScan =
                nil

            throw error
        }
    }

    private static func performDiscovery(
        excludingHosts:
            Set<String>
    ) async throws
        -> [TailnetPeerCandidate]
    {
        let peers =
            try await TailscaleKitProbe
                .shared
                .tailnetPeers()

        return await withTaskGroup(
            of:
                TailnetPeerCandidate?.self
        ) { group in
            for peer in peers {
                guard
                    peer.online,
                    !excludingHosts
                        .contains(
                            peer.endpoint.host
                        )
                else {
                    continue
                }

                group.addTask {
                    let remoteMacAlive =
                        await DevicePresenceProbe
                            .shared
                            .isReachable(
                                endpoint:
                                    peer.endpoint
                            )

                    return remoteMacAlive
                        ? peer
                        : nil
                }
            }

            var discovered:
                [TailnetPeerCandidate] = []

            for await candidate in group {
                if let candidate {
                    discovered.append(
                        candidate
                    )
                }
            }

            return discovered.sorted {
                $0.name
                    .localizedCaseInsensitiveCompare(
                        $1.name
                    )
                    == .orderedAscending
            }
        }
    }
}

struct AddDeviceView: View {
    @ObservedObject var registry:
        DeviceRegistry

    @ObservedObject var client:
        RemoteClient

    @Environment(\.dismiss)
    private var dismiss

    @State private var candidates:
        [TailnetPeerCandidate] = []

    @State private var isSearching =
        false

    @State private var errorMessage =
        ""

    @State private var scanGeneration =
        UUID()

    var body: some View {
        List {
            if isSearching {
                Section {
                    HStack(
                        spacing: 12
                    ) {
                        ProgressView()

                        Text(
                            "Searching for RemoteMac devices…"
                        )
                    }
                }
            }

            if !candidates.isEmpty {
                Section(
                    "Discovered Devices"
                ) {
                    ForEach(
                        candidates
                    ) { candidate in
                        NavigationLink {
                            PairDiscoveredDeviceView(
                                registry:
                                    registry,
                                client:
                                    client,
                                candidate:
                                    candidate,
                                onAdded: {
                                    dismiss()
                                }
                            )
                        } label: {
                            HStack(
                                spacing: 12
                            ) {
                                Image(
                                    systemName:
                                        "laptopcomputer"
                                )
                                .font(
                                    .title2
                                )

                                VStack(
                                    alignment:
                                        .leading,
                                    spacing:
                                        4
                                ) {
                                    Text(
                                        candidate.name
                                    )
                                    .font(
                                        .headline
                                    )

                                    Label(
                                        "RemoteMac detected",
                                        systemImage:
                                            "checkmark.circle.fill"
                                    )
                                    .font(
                                        .caption
                                    )
                                    .foregroundStyle(
                                        .secondary
                                    )
                                }
                            }
                        }
                    }
                }
            }

            if
                !isSearching,
                candidates.isEmpty,
                errorMessage.isEmpty
            {
                ContentUnavailableView(
                    "No New Devices",
                    systemImage:
                        "laptopcomputer.slash",
                    description:
                        Text(
                            "Open RemoteMac on another computer and enable pairing."
                        )
                )
            }

            if !errorMessage.isEmpty {
                Section {
                    Text(
                        errorMessage
                    )
                    .foregroundStyle(
                        .secondary
                    )
                }
            }

            Section {
                Button {
                    Task {
                        await scan()
                    }
                } label: {
                    Label(
                        "Scan Again",
                        systemImage:
                            "arrow.clockwise"
                    )
                }
                .disabled(
                    isSearching
                )
            } footer: {
                Text(
                    "Only devices on your tailnet that answer the RemoteMac protocol are shown."
                )
            }
        }
        .navigationTitle(
            "Add Device"
        )
        .navigationBarTitleDisplayMode(
            .inline
        )
        .task {
            await scan()
        }
    }

    @MainActor
    private func scan()
        async
    {
        guard !isSearching else {
            return
        }

        let generation =
            UUID()

        let scanStartedAt =
            Date()

        scanGeneration =
            generation

        isSearching =
            true

        errorMessage =
            ""

        candidates =
            []

        let existingHosts =
            Set(
                registry
                    .devices
                    .compactMap {
                        $0.resolvedEndpoint?
                            .host
                    }
            )

        Task {
            do {
                let discovered =
                    try await RemoteMacDiscoveryService
                        .shared
                        .discover(
                            excludingHosts:
                                existingHosts
                        )

                let elapsed =
                    Date()
                        .timeIntervalSince(
                            scanStartedAt
                        )

                if elapsed < 0.7 {
                    let remaining =
                        0.7 - elapsed

                    try? await Task.sleep(
                        nanoseconds:
                            UInt64(
                                remaining
                                * 1_000_000_000
                            )
                    )
                }

                await MainActor.run {
                    guard
                        scanGeneration ==
                            generation
                    else {
                        print(
                            "REMOTEMAC_DISCOVERY ignoring stale result"
                        )

                        return
                    }

                    candidates =
                        discovered

                    isSearching =
                        false
                }

            } catch {
                await MainActor.run {
                    guard
                        scanGeneration ==
                            generation
                    else {
                        return
                    }

                    candidates =
                        []

                    errorMessage =
                        "Could not scan devices: \(error.localizedDescription)"

                    isSearching =
                        false
                }
            }
        }

        Task {
            try? await Task.sleep(
                nanoseconds:
                    6_000_000_000
            )

            await MainActor.run {
                guard
                    scanGeneration ==
                        generation,
                    isSearching
                else {
                    return
                }

                scanGeneration =
                    UUID()

                candidates =
                    []

                errorMessage =
                    "Scan timed out. Tap Scan Again to retry."

                isSearching =
                    false

                print(
                    "REMOTEMAC_DISCOVERY watchdog timed out"
                )
            }
        }
    }
}

struct PairDiscoveredDeviceView:
    View
{
    @ObservedObject var registry:
        DeviceRegistry

    @ObservedObject var client:
        RemoteClient

    let candidate:
        TailnetPeerCandidate

    let onAdded:
        () -> Void

    @State private var pairingStarted =
        false

    @State private var pairingRequested =
        false

    @State private var pairingComplete =
        false

    @State private var biometricMessage =
        ""

    @State private var errorMessage =
        ""

    private var provisionalDeviceID:
        String
    {
        "pending:\(candidate.id)"
    }

    var body: some View {
        Form {
            Section {
                VStack(
                    alignment:
                        .leading,
                    spacing:
                        8
                ) {
                    Label(
                        candidate.name,
                        systemImage:
                            "laptopcomputer"
                    )
                    .font(
                        .headline
                    )

                    Text(
                        "RemoteMac node detected"
                    )
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        .secondary
                    )
                }
            }

            Section(
                "Pairing"
            ) {
                Text(
                    "On \(candidate.name), open RemoteMac and click Enable Pairing."
                )

                if !pairingStarted {
                    Button {
                        beginPairing()
                    } label: {
                        Label(
                            "Pair Device",
                            systemImage:
                                "link.badge.plus"
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(
                        .borderedProminent
                    )
                    .controlSize(.large)

                } else if
                    !client.isConnected
                {
                    ProgressView(
                        "Connecting securely…"
                    )

                } else if
                    !pairingRequested
                {
                    Button {
                        sendPairRequest()
                    } label: {
                        Label(
                            "Send Pair Request",
                            systemImage:
                                "lock.shield"
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(
                        .borderedProminent
                    )
                    .controlSize(.large)

                } else if
                    !pairingComplete
                {
                    ProgressView(
                        "Waiting for approval on the Mac…"
                    )
                }

                if !client.pairingMessage.isEmpty {
                    Text(
                        client
                            .pairingMessage
                    )
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        .secondary
                    )
                }

                if !biometricMessage.isEmpty {
                    Text(
                        biometricMessage
                    )
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        .secondary
                    )
                }

                if !errorMessage.isEmpty {
                    Text(
                        errorMessage
                    )
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        .red
                    )
                }

                if pairingComplete {
                    Label(
                        "Device added",
                        systemImage:
                            "checkmark.circle.fill"
                    )

                    Button(
                        "Done"
                    ) {
                        onAdded()
                    }
                    .buttonStyle(
                        .borderedProminent
                    )
                }
            }

            Section(
                "Connection Details"
            ) {
                LabeledContent(
                    "Host",
                    value:
                        candidate
                            .endpoint
                            .host
                )

                if
                    !candidate
                        .dnsName
                        .isEmpty
                {
                    LabeledContent(
                        "Tailnet name",
                        value:
                            candidate
                                .dnsName
                    )
                }
            }
        }
        .navigationTitle(
            candidate.name
        )
        .navigationBarTitleDisplayMode(
            .inline
        )
        .onAppear {
            prepareCandidate()
        }
        .onChange(
            of:
                client.isConnected
        ) { _, connected in
            if
                pairingStarted,
                connected,
                !pairingRequested
            {
                sendPairRequest()
            }
        }
        .onChange(
            of:
                client.pairingMessage
        ) { _, message in
            if
                message.contains(
                    "Pairing complete"
                )
            {
                finalizePairing()

            } else if
                message.contains(
                    "rejected"
                )
            {
                pairingRequested =
                    false
            }
        }
        .onDisappear {
            if
                pairingStarted,
                !pairingComplete,
                client.isConnected
            {
                client.disconnect()
            }
        }
    }

    private func prepareCandidate() {
        try? DevicePairingStore
            .delete(
                for:
                    provisionalDeviceID
            )

        client.setActiveDevice(
            deviceID:
                provisionalDeviceID,
            endpoint:
                candidate.endpoint
        )

        client.refreshPairingState()
    }

    private func beginPairing() {
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

                pairingStarted =
                    true

                client.connect()

            case .failed(
                let message
            ):
                biometricMessage =
                    message
            }
        }
    }

    private func sendPairRequest() {
        pairingRequested =
            true

        client.requestPairing()
    }

    private func finalizePairing() {
        guard !pairingComplete else {
            return
        }

        do {
            let device =
                try registry
                    .finalizeDiscoveredPairing(
                        provisionalDeviceID:
                            provisionalDeviceID,
                        name:
                            candidate.name,
                        endpoint:
                            candidate.endpoint
                    )

            pairingComplete =
                true

            if client.isConnected {
                client.disconnect()
            }

            client.setActiveDevice(
                deviceID:
                    device.id,
                endpoint:
                    device
                        .resolvedEndpoint
            )

        } catch {
            errorMessage =
                error.localizedDescription
        }
    }
}
