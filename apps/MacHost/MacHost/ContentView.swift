import SwiftUI
import RemoteProtocol

struct ContentView: View {
    @EnvironmentObject private var server:
        HostServer

    @EnvironmentObject private var launchManager:
        LaunchAtLoginManager

    var body: some View {
        VStack(spacing: 16) {
            Image(
                systemName:
                    "desktopcomputer"
            )
            .font(
                .system(size: 34)
            )

            Text("RemoteMac Host")
                .font(.title2)
                .fontWeight(.semibold)

            Text(server.status)
                .font(.headline)

            Text(server.lastEvent)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if server.isStreaming {
                Label(
                    "H.264",
                    systemImage:
                        "dot.radiowaves.left.and.right"
                )
            }

            Divider()

            if server.isAuthenticated {
                Label(
                    "Authenticated iPhone",
                    systemImage:
                        "checkmark.shield.fill"
                )
                .font(.headline)
            }

            DeviceIdentityBadge()

            if let paired =
                server.pairedPeerFingerprint
            {
                VStack(spacing: 6) {
                    Text("Paired iPhone")
                        .font(.caption)

                    Text(paired)
                        .font(.caption2)
                        .monospaced()

                    Button(
                        "Forget Paired iPhone"
                    ) {
                        server.forgetPairedPeer()
                    }
                    .buttonStyle(.bordered)
                }

            } else {
                Text("No paired iPhone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let pending =
                server.pendingPairFingerprint
            {
                VStack(spacing: 7) {
                    Text("Pair Request")
                        .font(.headline)

                    Text(pending)
                        .monospaced()
                        .font(.caption)

                    Text(
                        "Confirm this matches the Device ID shown on your iPhone."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                    HStack {
                        Button(
                            "Approve iPhone"
                        ) {
                            server.approvePendingPair()
                        }
                        .buttonStyle(
                            .borderedProminent
                        )

                        Button(
                            "Reject"
                        ) {
                            server.rejectPendingPair()
                        }
                        .buttonStyle(.bordered)
                    }
                }

            } else if server.pairingMode {
                HStack {
                    ProgressView()

                    Text(
                        "Waiting for pair request…"
                    )
                    .font(.caption)
                }

                Button(
                    "Cancel Pairing"
                ) {
                    server.disablePairing()
                }

            } else {
                Button(
                    "Enable Pairing"
                ) {
                    server.enablePairing()
                }
                .buttonStyle(
                    .borderedProminent
                )
            }

            Divider()

            VStack(spacing: 6) {
                Text(launchManager.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !launchManager.isEnabled {
                    Button("Enable Launch at Login") {
                        launchManager.enable()
                    }
                    .buttonStyle(.borderedProminent)
                }

                if launchManager.requiresApproval {
                    Button("Open Login Item Settings") {
                        launchManager.openLoginItemSettings()
                    }
                }
            }

            Divider()

            Text(
                "Local TCP \(RemoteProtocolInfo.localHostPort)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("Restart Connection") {
                server.restartConnection()
            }
            .buttonStyle(.bordered)

            Text("Tailscale transport")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(
                "Protocol v\(RemoteProtocolInfo.version) • Pairing"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(
            minWidth: 480,
            minHeight: 520
        )
        .padding(30)
        .onAppear {
            server.refreshPairingState()
            launchManager.refresh()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(
            HostServer.shared
        )
        .environmentObject(
            LaunchAtLoginManager()
        )
}
