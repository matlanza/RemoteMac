import SwiftUI
import Combine
import RemoteProtocol

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var deviceRegistry =
        DeviceRegistry()

    @StateObject private var client =
        RemoteClient()

    @StateObject private var renderer =
        H264VideoRenderer()

    @State private var immersiveSession =
        false

    @State private var addDevicePresented =
        false

    var body: some View {
        NavigationStack {
            Group {
                if deviceRegistry
                    .devices
                    .isEmpty
                {
                    ContentUnavailableView(
                        "No Devices",
                        systemImage:
                            "rectangle.connected.to.line.below",
                        description:
                            Text(
                                "Pair a device to begin."
                            )
                    )

                } else {
                    List {
                        Section(
                            "My Devices"
                        ) {
                            ForEach(
                                deviceRegistry
                                    .devices
                            ) { device in
                                NavigationLink {
                                    DeviceDetailsView(
                                        registry:
                                            deviceRegistry,
                                        client:
                                            client,
                                        renderer:
                                            renderer,
                                        deviceID:
                                            device.id,
                                        immersiveSession:
                                            $immersiveSession
                                    )
                                } label: {
                                    DeviceTerminalRow(
                                        device:
                                            device,
                                        connected:
                                            client
                                                .isConnected
                                            && client
                                                .isAuthenticated
                                            && device.id
                                                == deviceRegistry
                                                    .selectedDeviceID
                                    )
                                }
                            }
                        }

                        Section {
                            Button {
                                addDevicePresented =
                                    true
                            } label: {
                                Label(
                                    "Add Device",
                                    systemImage:
                                        "plus.circle"
                                )
                            }
                            .disabled(
                                client.isConnected
                            )
                        } footer: {
                            Text(
                                "Discover and securely pair another RemoteMac device."
                            )
                        }
                    }
                    .refreshable {
                        if !client.isConnected {
                            await deviceRegistry
                                .refreshPresence()
                        }
                    }
                }
            }
            .navigationTitle(
                "RemoteMac"
            )
        }
        .onAppear {
            deviceRegistry
                .refreshLegacyDevice()

            configureSelectedDevice()

            client.setVideoHandlers(
                onConfig: { config in
                    Task { @MainActor in
                        renderer.configure(
                            config
                        )
                    }
                },
                onFrame: { data in
                    Task { @MainActor in
                        renderer.enqueue(
                            data
                        )
                    }
                }
            )
        }
        .task(
            id:
                scenePhase
        ) {
            guard
                scenePhase == .active
            else {
                return
            }

            while !Task.isCancelled {
                if !client.isConnected {
                    await deviceRegistry
                        .refreshPresence()
                }

                do {
                    try await Task.sleep(
                        nanoseconds:
                            3_000_000_000
                    )
                } catch {
                    return
                }
            }
        }
        .onChange(
            of:
                scenePhase
        ) { _, phase in
            if phase != .active {
                deviceRegistry
                    .invalidateAllPresenceEvidence()
            }

            if
                phase == .background,
                client.isConnected
            {
                client.disconnect()
            }
        }
        .onChange(
            of:
                client.isConnected
        ) { wasConnected, connected in
            guard
                wasConnected,
                !connected,
                scenePhase == .active
            else {
                return
            }

            deviceRegistry
                .invalidatePresenceEvidence(
                    deviceID:
                        deviceRegistry
                            .selectedDeviceID
                )

            Task {
                await deviceRegistry
                    .refreshPresence()
            }
        }
        .onReceive(
            NotificationCenter.default
                .publisher(
                    for:
                        .remoteMacAPNSTokenDidUpdate
                )
        ) { _ in
            client.syncAPNSTokenIfPossible()
        }
        .sheet(
            isPresented:
                $addDevicePresented
        ) {
            NavigationStack {
                AddDeviceView(
                    registry:
                        deviceRegistry,
                    client:
                        client
                )
            }
        }
        .fullScreenCover(
            isPresented:
                $immersiveSession
        ) {
            ImmersiveSessionView(
                client:
                    client,
                renderer:
                    renderer,
                onExit: {
                    immersiveSession =
                        false
                }
            )
        }
    }

    private func configureSelectedDevice() {
        guard
            let device =
                deviceRegistry
                    .selectedDevice
        else {
            client.setActiveDevice(
                deviceID:
                    nil,
                endpoint:
                    nil
            )

            return
        }

        client.setActiveDevice(
            deviceID:
                device.id,
            endpoint:
                device
                    .resolvedEndpoint
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
}

#Preview {
    ContentView()
}
