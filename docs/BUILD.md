# Build and configuration notes

This is a sanitized source snapshot, not a turnkey release. Commands below are preparation guidance and have not been validated against the cleaned snapshot.

## Requirements observed in source

- RemoteProtocol declares Swift tools 6.4.
- Xcode projects target iOS 27.0 and macOS 26.5. Use an Xcode/SDK combination that supports those targets.
- The host transport declares Go 1.26.5 and tailscale.com v1.102.2.
- The vendored libtailscale module separately declares Go 1.25.5 and tailscale.com v1.94.1. Do not silently equate the two dependency versions.
- A private Tailscale account/tailnet, Apple signing appropriate to your own devices, and the required macOS Screen Recording and Accessibility permissions.

## Dependency preparation

The iOS project references `apps/iPhoneClient/Frameworks/TailscaleKit.xcframework`; the compiled framework is not distributed here. The retained third-party source provides `experiments/libtailscale/swift/Makefile` and its upstream README. Review those build steps and run `make ios-fat` from that directory with compatible Go and Apple toolchains, then copy its resulting TailscaleKit.xcframework into the path expected by the iOS project. Build reproducibility and compatibility with this application snapshot still require verification.

The Mac app expects a helper named `RemoteMacTransport` inside its app bundle executable directory. Build it from `experiments/tsnet-probe` using `go build -mod=readonly -o RemoteMacTransport .`, and integrate/sign it with your own development build. Do not run transport helpers with someone else’s saved state. The host supplies a per-installation state directory; a standalone helper requires `REMOTEMAC_TSNET_STATE_DIR`.

## Personal configuration

1. Open `RemoteMac.xcworkspace` and select your own signing team. No original signing team is included.
2. Replace the `com.example.remotemac` bundle/Keychain namespace consistently with one you control. Changing this namespace creates distinct identity storage; it does not reuse any original paired identity.
3. Configure your host through the device UI. The legacy default and diagnostic probes use `your-mac.your-tailnet.ts.net` placeholders in RemoteClient.swift, EmbeddedTailscaleBridge.swift and TailscaleKitProbe.swift; replace these for your own tailnet before using those paths.
4. Enroll your own devices and pair them explicitly. Review the security limitations before granting capture/input permissions.

## Tests

From `packages/RemoteProtocol`, run `swift test` with Swift 6.4 or newer. Tests cover packet serialization/framing and video datagram sizing, ordering, duplicate fragments, incomplete frames and invalid headers. They do not establish end-to-end streaming, authentication security, device permissions or reconnect reliability.

No test execution is claimed for this cleaned publication. Fresh app builds and real-device smoke tests remain outstanding. Private install/launch automation was excluded to avoid accidentally altering a developer’s devices.
