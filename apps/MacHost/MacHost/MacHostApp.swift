import SwiftUI
import AppKit
import Combine

@MainActor
final class EmbeddedTransportManager:
    ObservableObject
{
    static let shared =
        EmbeddedTransportManager()

    @Published private(set)
    var status = "Stopped"

    @Published private(set)
    var ipv4: String?

    private var process: Process?
    private var outputPipe: Pipe?
    private var shouldRun = false
    private var restartWorkItem:
        DispatchWorkItem?

    private init() {}

    func start() {
        shouldRun = true
        launchIfNeeded()
    }

    func restart() {
        shouldRun = true
        stopProcess()

        status = "Restarting"

        scheduleLaunch(
            after: 0.75
        )
    }

    func stop() {
        shouldRun = false

        restartWorkItem?.cancel()
        restartWorkItem = nil

        stopProcess()

        status = "Stopped"
    }

    private func launchIfNeeded() {
        guard shouldRun else {
            return
        }

        guard process == nil else {
            return
        }

        guard let executable =
            Bundle.main.url(
                forAuxiliaryExecutable:
                    "RemoteMacTransport"
            )
        else {
            status =
                "Transport missing"
            return
        }

        do {
            let support =
                try transportStateDirectory()

            let child = Process()
            let pipe = Pipe()

            var environment =
                ProcessInfo
                .processInfo
                .environment

            environment[
                "REMOTEMAC_TSNET_STATE_DIR"
            ] = support.path

            child.executableURL =
                executable

            child.environment =
                environment

            child.standardOutput =
                pipe

            child.standardError =
                pipe

            outputPipe = pipe
            process = child

            pipe.fileHandleForReading
                .readabilityHandler =
            { [weak self] handle in
                let data =
                    handle.availableData

                guard !data.isEmpty else {
                    return
                }

                guard let text =
                    String(
                        data: data,
                        encoding: .utf8
                    )
                else {
                    return
                }

                Task { @MainActor in
                    self?.consume(text)
                }
            }

            child.terminationHandler =
            { [weak self, weak child]
                finished in

                Task { @MainActor in
                    guard let self else {
                        return
                    }

                    guard
                        let child,
                        self.process === child
                    else {
                        return
                    }

                    self.outputPipe?
                        .fileHandleForReading
                        .readabilityHandler = nil

                    self.outputPipe = nil
                    self.process = nil

                    if self.shouldRun {
                        self.status =
                            "Restarting"

                        self.scheduleLaunch(
                            after: 2.0
                        )
                    } else {
                        self.status =
                            "Stopped"
                    }
                }
            }

            status = "Starting"

            try child.run()

        } catch {
            process = nil
            outputPipe = nil

            status =
                "Transport error"

            if shouldRun {
                scheduleLaunch(
                    after: 3.0
                )
            }
        }
    }

    private func consume(
        _ text: String
    ) {
        for rawLine in
            text.split(
                whereSeparator:
                    \.isNewline
            )
        {
            let line =
                String(rawLine)

            if let range =
                line.range(
                    of: "IPv4: "
                )
            {
                let value =
                    String(
                        line[
                            range.upperBound...
                        ]
                    )
                    .trimmingCharacters(
                        in: .whitespaces
                    )

                if !value.isEmpty {
                    ipv4 = value
                }
            }

            if line.contains(
                "Tailnet TCP"
            ) {
                status = "Ready"
            }

            if line.contains(
                "NeedsLogin"
            ) ||
            line.contains(
                "AuthURL"
            ) {
                status =
                    "Authorization required"
            }
        }
    }

    private func scheduleLaunch(
        after delay: TimeInterval
    ) {
        restartWorkItem?.cancel()

        let item =
            DispatchWorkItem {
                Task { @MainActor in
                    self.launchIfNeeded()
                }
            }

        restartWorkItem = item

        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: item
        )
    }

    private func stopProcess() {
        restartWorkItem?.cancel()
        restartWorkItem = nil

        outputPipe?
            .fileHandleForReading
            .readabilityHandler = nil

        outputPipe = nil

        let child = process
        process = nil

        if let child,
           child.isRunning
        {
            child.terminate()
        }
    }

    private func transportStateDirectory()
        throws -> URL
    {
        let manager =
            FileManager.default

        let base =
            try manager.url(
                for:
                    .applicationSupportDirectory,
                in: .userDomainMask,
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
                "Transport",
                isDirectory: true
            )

        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories:
                true
        )

        return directory
    }
}

final class RemoteMacAppDelegate:
    NSObject,
    NSApplicationDelegate
{
    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        let others =
            otherRemoteMacInstances()

        if others.isEmpty {
            startRemoteMac()
            return
        }

        for app in others {
            app.terminate()
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.6
        ) { [weak self] in
            guard let self else {
                return
            }

            let leftovers =
                self.otherRemoteMacInstances()

            for app in leftovers {
                app.forceTerminate()
            }

            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.35
            ) {
                self.startRemoteMac()
            }
        }
    }

    func applicationWillTerminate(
        _ notification: Notification
    ) {
        EmbeddedTransportManager
            .shared
            .stop()
    }

    private func otherRemoteMacInstances()
        -> [NSRunningApplication]
    {
        guard let bundleIdentifier =
            Bundle.main.bundleIdentifier
        else {
            return []
        }

        let currentPID =
            ProcessInfo
            .processInfo
            .processIdentifier

        return NSRunningApplication
            .runningApplications(
                withBundleIdentifier:
                    bundleIdentifier
            )
            .filter {
                $0.processIdentifier !=
                    currentPID
            }
    }

    private func startRemoteMac() {
        HostServer.shared.start()

        HostServer.shared
            .refreshPairingState()

        EmbeddedTransportManager
            .shared
            .start()
    }
}

@MainActor
final class RemoteMacSettingsWindow {
    static let shared =
        RemoteMacSettingsWindow()

    private var windowController:
        NSWindowController?

    private init() {}

    func show(
        server: HostServer,
        launchManager:
            LaunchAtLoginManager
    ) {
        if let window =
            windowController?.window
        {
            NSApplication.shared
                .activate(
                    ignoringOtherApps: true
                )

            window
                .makeKeyAndOrderFront(nil)

            return
        }

        let rootView =
            ContentView()
            .environmentObject(server)
            .environmentObject(
                launchManager
            )

        let hostingController =
            NSHostingController(
                rootView: rootView
            )

        let window =
            NSWindow(
                contentRect:
                    NSRect(
                        x: 0,
                        y: 0,
                        width: 540,
                        height: 640
                    ),
                styleMask: [
                    .titled,
                    .closable,
                    .miniaturizable,
                    .resizable
                ],
                backing: .buffered,
                defer: false
            )

        window.title =
            "RemoteMac Settings"

        window.contentViewController =
            hostingController

        window.center()
        window.isReleasedWhenClosed =
            false

        let controller =
            NSWindowController(
                window: window
            )

        windowController =
            controller

        NSApplication.shared
            .activate(
                ignoringOtherApps: true
            )

        controller.showWindow(nil)
    }
}

@main
struct MacHostApp: App {
    @NSApplicationDelegateAdaptor(
        RemoteMacAppDelegate.self
    )
    private var appDelegate

    @StateObject private var server =
        HostServer.shared

    @StateObject private var launchManager =
        LaunchAtLoginManager()

    @StateObject private var transport =
        EmbeddedTransportManager.shared

    var body: some Scene {
        MenuBarExtra {
            RemoteMacMenuView()
                .environmentObject(server)
                .environmentObject(
                    launchManager
                )
                .environmentObject(
                    transport
                )
        } label: {
            Image(
                systemName:
                    server.isAuthenticated
                    ? "checkmark.shield.fill"
                    : "dot.radiowaves.left.and.right"
            )
            .accessibilityLabel(
                "RemoteMac"
            )
        }
        .menuBarExtraStyle(.menu)
    }
}

struct RemoteMacMenuView: View {
    @EnvironmentObject
    private var server:
        HostServer

    @EnvironmentObject
    private var launchManager:
        LaunchAtLoginManager

    @EnvironmentObject
    private var transport:
        EmbeddedTransportManager

    var body: some View {
        Group {
            Label(
                server.isAuthenticated
                    ? "Connected"
                    : server.status,
                systemImage:
                    server.isAuthenticated
                    ? "checkmark.shield.fill"
                    : "dot.radiowaves.left.and.right"
            )

            if server.isAuthenticated {
                Text(
                    "Authenticated iPhone"
                )
            } else {
                Text(server.lastEvent)
            }

            Divider()

            if let ipv4 =
                transport.ipv4
            {
                Text(
                    "Embedded transport: \(transport.status) • \(ipv4)"
                )
            } else {
                Text(
                    "Embedded transport: \(transport.status)"
                )
            }

            Divider()

            Button(
                "Restart Connection"
            ) {
                server.restartConnection()
                transport.restart()
            }

            Button("Open Settings") {
                RemoteMacSettingsWindow
                    .shared
                    .show(
                        server: server,
                        launchManager:
                            launchManager
                    )
            }

            Divider()

            if launchManager.isEnabled {
                Label(
                    "Starts at Login",
                    systemImage:
                        "checkmark.circle"
                )

                Button(
                    "Disable Start at Login"
                ) {
                    launchManager.disable()
                }
            } else {
                Button(
                    "Enable Start at Login"
                ) {
                    launchManager.enable()
                }
            }

            if launchManager
                .requiresApproval
            {
                Button(
                    "Open Login Item Settings"
                ) {
                    launchManager
                        .openLoginItemSettings()
                }
            }

            Divider()

            Button("Quit RemoteMac") {
                NSApplication.shared
                    .terminate(nil)
            }
        }
        .onAppear {
            launchManager.refresh()
        }
    }
}
