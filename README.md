# RemoteMac

Experimental native iPhone-to-Mac remote control, built with Swift and Go.

RemoteMac explores the full remote desktop path: capture a Mac display, encode and transport video, render it on an iPhone, and send pointer and keyboard input back to the host. This is a development project, not a production remote-access product.

## Implemented in source

- Native SwiftUI macOS host and iOS client.
- ScreenCaptureKit capture and VideoToolbox H.264 encoding/rendering.
- Adaptive video bitrate and a fragmented UDP video path with reassembly.
- Pointer movement, clicks, scrolling, keyboard events and text input.
- Manual pairing, Ed25519 challenge-response authentication, Keychain-backed identities and an iOS biometric gate.
- Embedded Tailscale networking: Go tsnet host transport and an iOS TailscaleKit bridge.
- Device registry and presence UI, plus background/menu-bar host operation and launch-at-login integration.

These are source-level implementation claims. The publication snapshot has not been freshly built or exercised end to end.

## Architecture

The iPhone client connects through embedded Tailscale to a Go transport process on the Mac. That process forwards control traffic to the native host. A shared Swift package defines packets and video datagrams. The host captures and encodes the display and injects authenticated input; the client renders video and sends user actions.

- `apps/MacHost`: macOS application.
- `apps/iPhoneClient`: iOS application.
- `packages/RemoteProtocol`: shared protocol and 24 XCTest methods covering serialization, framing and video datagrams.
- `experiments/tsnet-probe`: Go transport used by the host.
- `experiments/libtailscale`: vendored third-party Tailscale source, not original RemoteMac work.

## Build and configuration

See [BUILD.md](docs/BUILD.md). Personal signing details and connection endpoints have been replaced with placeholders. Compiled dependencies, device state and private notification-forwarding utilities are intentionally excluded.

## Security and limitations

Read [SECURITY.md](SECURITY.md) before running. Do not expose the host directly to the public Internet. RemoteMac is intended for a private, access-controlled tailnet and has not received an independent security audit. Authentication signatures do not provide application-level payload encryption.

Known development issues include session teardown/reconnect desynchronization. Launch-at-login after a real restart remains an acceptance test, not a verified result for this snapshot. Platform enum values for Windows and Linux do not mean those host implementations exist. Native rendezvous/relay networking independent of Tailscale is a future direction, not a completed feature.

## Attribution and rights

The embedded network dependency is Tailscale, not an original VPN protocol. Vendored libtailscale retains its BSD-3-Clause license and copyright notices. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). No open-source license is granted for the original RemoteMac code in this publication snapshot.
