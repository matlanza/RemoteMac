import Foundation

enum RemotePlatform:
    String,
    Codable,
    Sendable
{
    case macOS
    case windows
    case linux
    case iOS
    case iPadOS
    case unknown
}

enum RemoteCapability:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case screen
    case pointer
    case keyboard
    case notifications
}

enum RemotePresence:
    String,
    Codable,
    Sendable
{
    case unknown
    case checking
    case available
    case sleeping
    case offline
    case lowBattery
    case noNetwork
}

struct RemoteEndpoint:
    Codable,
    Equatable,
    Sendable
{
    var host: String
    var port: UInt16

    var dialAddress: String {
        let cleaned =
            host.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        if
            cleaned.contains(":"),
            !cleaned.hasPrefix("[")
        {
            return
                "[\(cleaned)]:\(port)"
        }

        return
            "\(cleaned):\(port)"
    }
}

struct RemoteDevice:
    Identifiable,
    Codable,
    Equatable,
    Sendable
{
    let id: String

    var name: String
    var platform: RemotePlatform

    var identityFingerprint: String?

    var automaticEndpoint:
        RemoteEndpoint?

    var manualEndpointOverride:
        RemoteEndpoint?

    var capabilities:
        Set<RemoteCapability>

    var presence:
        RemotePresence

    var lastSeen:
        Date?

    var resolvedEndpoint:
        RemoteEndpoint?
    {
        manualEndpointOverride
            ?? automaticEndpoint
    }
}
