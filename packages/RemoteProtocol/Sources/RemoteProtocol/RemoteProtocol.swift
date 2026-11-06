import Foundation

public enum RemotePacketType: UInt8, Codable, Sendable {
    case ping = 1
    case pong = 2
    case disconnect = 3
    case requestFrame = 4
    case frame = 5
    case captureError = 6
    case startStream = 7
    case stopStream = 8
    case videoConfig = 9
    case videoFrame = 10
    case pointerDelta = 11
    case mouseButton = 12
    case scroll = 13
    case keyEvent = 14
    case textInput = 15
    case pairRequest = 16
    case pairApproved = 17
    case pairRejected = 18
    case authChallenge = 19
    case authResponse = 20
    case authAccepted = 21
    case authRejected = 22
    case pointerAbsolute = 23
    case taskCompleted = 24
    case apnsDeviceToken = 25
    case videoDatagramState = 26
    case requestVideoKeyFrame = 27
}

public struct RemoteH264Config: Equatable, Sendable {
    public let nalUnitHeaderLength: Int32
    public let sps: Data
    public let pps: Data

    public init(
        nalUnitHeaderLength: Int32,
        sps: Data,
        pps: Data
    ) {
        self.nalUnitHeaderLength = nalUnitHeaderLength
        self.sps = sps
        self.pps = pps
    }

    public var payload: Data {
        var data = Data()
        data.append(UInt8(nalUnitHeaderLength))

        Self.appendUInt32(
            UInt32(sps.count),
            to: &data
        )

        data.append(sps)

        Self.appendUInt32(
            UInt32(pps.count),
            to: &data
        )

        data.append(pps)

        return data
    }

    public init?(
        payload: Data
    ) {
        guard payload.count >= 9 else {
            return nil
        }

        var offset = 0

        let firstIndex = payload.index(
            payload.startIndex,
            offsetBy: offset
        )

        nalUnitHeaderLength = Int32(
            payload[firstIndex]
        )

        offset += 1

        guard let spsLength = Self.readUInt32(
            from: payload,
            offset: &offset
        ) else {
            return nil
        }

        guard let sps = Self.readData(
            from: payload,
            length: Int(spsLength),
            offset: &offset
        ) else {
            return nil
        }

        guard let ppsLength = Self.readUInt32(
            from: payload,
            offset: &offset
        ) else {
            return nil
        }

        guard let pps = Self.readData(
            from: payload,
            length: Int(ppsLength),
            offset: &offset
        ) else {
            return nil
        }

        guard offset == payload.count else {
            return nil
        }

        self.sps = sps
        self.pps = pps
    }

    private static func appendUInt32(
        _ value: UInt32,
        to data: inout Data
    ) {
        var bigEndian = value.bigEndian

        Swift.withUnsafeBytes(
            of: &bigEndian
        ) {
            data.append(
                contentsOf: $0
            )
        }
    }

    private static func readUInt32(
        from data: Data,
        offset: inout Int
    ) -> UInt32? {
        guard offset + 4 <= data.count else {
            return nil
        }

        var result: UInt32 = 0

        for indexOffset in 0..<4 {
            let index = data.index(
                data.startIndex,
                offsetBy: offset + indexOffset
            )

            result =
                (result << 8)
                | UInt32(data[index])
        }

        offset += 4

        return result
    }

    private static func readData(
        from data: Data,
        length: Int,
        offset: inout Int
    ) -> Data? {
        guard
            length >= 0,
            offset + length <= data.count
        else {
            return nil
        }

        let start = data.index(
            data.startIndex,
            offsetBy: offset
        )

        let end = data.index(
            start,
            offsetBy: length
        )

        offset += length

        return Data(
            data[start..<end]
        )
    }
}

public enum RemoteMouseButton: UInt8, Sendable {
    case left = 0
    case right = 1
    case middle = 2
}

public enum RemoteButtonAction: UInt8, Sendable {
    case down = 0
    case up = 1
    case click = 2
    case doubleClick = 3
}

public struct RemotePointerDelta: Equatable, Sendable {
    public let dx: Int32
    public let dy: Int32

    public init(dx: Int32, dy: Int32) {
        self.dx = dx
        self.dy = dy
    }

    public var payload: Data {
        var data = Data()
        Self.appendInt32(dx, to: &data)
        Self.appendInt32(dy, to: &data)
        return data
    }

    public init?(payload: Data) {
        guard payload.count == 8 else {
            return nil
        }

        var offset = 0

        guard
            let dx = Self.readInt32(from: payload, offset: &offset),
            let dy = Self.readInt32(from: payload, offset: &offset)
        else {
            return nil
        }

        self.dx = dx
        self.dy = dy
    }

    private static func appendInt32(
        _ value: Int32,
        to data: inout Data
    ) {
        var big = UInt32(bitPattern: value).bigEndian

        Swift.withUnsafeBytes(of: &big) {
            data.append(contentsOf: $0)
        }
    }

    private static func readInt32(
        from data: Data,
        offset: inout Int
    ) -> Int32? {
        guard offset + 4 <= data.count else {
            return nil
        }

        var value: UInt32 = 0

        for i in 0..<4 {
            let index = data.index(
                data.startIndex,
                offsetBy: offset + i
            )

            value =
                (value << 8)
                | UInt32(data[index])
        }

        offset += 4

        return Int32(bitPattern: value)
    }
}

public struct RemoteMouseButtonEvent: Equatable, Sendable {
    public let button: RemoteMouseButton
    public let action: RemoteButtonAction

    public init(
        button: RemoteMouseButton,
        action: RemoteButtonAction
    ) {
        self.button = button
        self.action = action
    }

    public var payload: Data {
        Data([
            button.rawValue,
            action.rawValue
        ])
    }

    public init?(payload: Data) {
        guard payload.count == 2 else {
            return nil
        }

        guard
            let button = RemoteMouseButton(
                rawValue: payload[payload.startIndex]
            ),
            let action = RemoteButtonAction(
                rawValue: payload[
                    payload.index(
                        after: payload.startIndex
                    )
                ]
            )
        else {
            return nil
        }

        self.button = button
        self.action = action
    }
}

public struct RemoteScrollDelta: Equatable, Sendable {
    public let dx: Int32
    public let dy: Int32

    public init(dx: Int32, dy: Int32) {
        self.dx = dx
        self.dy = dy
    }

    public var payload: Data {
        var data = Data()

        Self.appendInt32(dx, to: &data)
        Self.appendInt32(dy, to: &data)

        return data
    }

    public init?(payload: Data) {
        guard payload.count == 8 else {
            return nil
        }

        var offset = 0

        guard
            let dx = Self.readInt32(
                from: payload,
                offset: &offset
            ),
            let dy = Self.readInt32(
                from: payload,
                offset: &offset
            )
        else {
            return nil
        }

        self.dx = dx
        self.dy = dy
    }

    private static func appendInt32(
        _ value: Int32,
        to data: inout Data
    ) {
        var big =
            UInt32(bitPattern: value).bigEndian

        Swift.withUnsafeBytes(
            of: &big
        ) {
            data.append(contentsOf: $0)
        }
    }

    private static func readInt32(
        from data: Data,
        offset: inout Int
    ) -> Int32? {
        guard offset + 4 <= data.count else {
            return nil
        }

        var value: UInt32 = 0

        for i in 0..<4 {
            let index = data.index(
                data.startIndex,
                offsetBy: offset + i
            )

            value =
                (value << 8)
                | UInt32(data[index])
        }

        offset += 4

        return Int32(bitPattern: value)
    }
}

public struct RemoteModifierFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift =
        RemoteModifierFlags(rawValue: 1 << 0)

    public static let control =
        RemoteModifierFlags(rawValue: 1 << 1)

    public static let option =
        RemoteModifierFlags(rawValue: 1 << 2)

    public static let command =
        RemoteModifierFlags(rawValue: 1 << 3)

    public static let function =
        RemoteModifierFlags(rawValue: 1 << 4)
}

public enum RemoteKeyAction: UInt8, Sendable {
    case down = 0
    case up = 1
    case press = 2
}

public struct RemoteKeyEvent: Equatable, Sendable {
    public let keyCode: UInt16
    public let action: RemoteKeyAction
    public let modifiers: RemoteModifierFlags

    public init(
        keyCode: UInt16,
        action: RemoteKeyAction = .press,
        modifiers: RemoteModifierFlags = []
    ) {
        self.keyCode = keyCode
        self.action = action
        self.modifiers = modifiers
    }

    public var payload: Data {
        var data = Data()

        data.append(
            UInt8((keyCode >> 8) & 0xFF)
        )

        data.append(
            UInt8(keyCode & 0xFF)
        )

        data.append(action.rawValue)
        data.append(modifiers.rawValue)

        return data
    }

    public init?(payload: Data) {
        guard payload.count == 4 else {
            return nil
        }

        let bytes = Array(payload)

        keyCode =
            (UInt16(bytes[0]) << 8)
            | UInt16(bytes[1])

        guard let action =
            RemoteKeyAction(rawValue: bytes[2])
        else {
            return nil
        }

        self.action = action

        modifiers =
            RemoteModifierFlags(
                rawValue: bytes[3]
            )
    }
}

public struct RemotePointerPosition: Equatable, Sendable {
    public let x: UInt32
    public let y: UInt32

    private static let scale: Double = 1_000_000

    public init(
        normalizedX: Double,
        normalizedY: Double
    ) {
        let clampedX = min(
            1.0,
            max(0.0, normalizedX)
        )

        let clampedY = min(
            1.0,
            max(0.0, normalizedY)
        )

        x = UInt32(
            (clampedX * Self.scale).rounded()
        )

        y = UInt32(
            (clampedY * Self.scale).rounded()
        )
    }

    public var normalizedX: Double {
        Double(x) / Self.scale
    }

    public var normalizedY: Double {
        Double(y) / Self.scale
    }

    public var payload: Data {
        var data = Data()

        Self.appendUInt32(
            x,
            to: &data
        )

        Self.appendUInt32(
            y,
            to: &data
        )

        return data
    }

    public init?(
        payload: Data
    ) {
        guard payload.count == 8 else {
            return nil
        }

        var offset = 0

        guard
            let x = Self.readUInt32(
                from: payload,
                offset: &offset
            ),
            let y = Self.readUInt32(
                from: payload,
                offset: &offset
            ),
            x <= 1_000_000,
            y <= 1_000_000
        else {
            return nil
        }

        self.x = x
        self.y = y
    }

    private static func appendUInt32(
        _ value: UInt32,
        to data: inout Data
    ) {
        var big = value.bigEndian

        Swift.withUnsafeBytes(
            of: &big
        ) {
            data.append(
                contentsOf: $0
            )
        }
    }

    private static func readUInt32(
        from data: Data,
        offset: inout Int
    ) -> UInt32? {
        guard offset + 4 <= data.count else {
            return nil
        }

        var result: UInt32 = 0

        for i in 0..<4 {
            let index = data.index(
                data.startIndex,
                offsetBy: offset + i
            )

            result =
                (result << 8)
                | UInt32(data[index])
        }

        offset += 4

        return result
    }
}

public struct RemoteTaskCompletion: Codable, Equatable, Sendable {
    public let deviceID: String
    public let deviceName: String
    public let source: String
    public let task: String
    public let completedAtUnixMilliseconds: UInt64

    public init(
        deviceID: String,
        deviceName: String,
        source: String,
        task: String,
        completedAtUnixMilliseconds: UInt64
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.source = source
        self.task = task
        self.completedAtUnixMilliseconds =
            completedAtUnixMilliseconds
    }

    public var payload: Data {
        (try? JSONEncoder().encode(self))
            ?? Data()
    }

    public init?(
        payload: Data
    ) {
        guard
            let decoded =
                try? JSONDecoder().decode(
                    Self.self,
                    from: payload
                )
        else {
            return nil
        }

        self = decoded
    }
}

public struct RemotePacket: Equatable, Sendable {
    public let type: RemotePacketType
    public let payload: Data

    public init(
        type: RemotePacketType,
        payload: Data = Data()
    ) {
        self.type = type
        self.payload = payload
    }

    public var wireData: Data {
        var data = Data()
        data.append(type.rawValue)

        var length =
            UInt32(payload.count).bigEndian

        Swift.withUnsafeBytes(
            of: &length
        ) {
            data.append(
                contentsOf: $0
            )
        }

        data.append(payload)

        return data
    }

    public static var ping: RemotePacket {
        RemotePacket(type: .ping)
    }

    public static var pong: RemotePacket {
        RemotePacket(type: .pong)
    }

    public static var disconnect: RemotePacket {
        RemotePacket(type: .disconnect)
    }

    public static var requestFrame: RemotePacket {
        RemotePacket(type: .requestFrame)
    }

    public static var startStream: RemotePacket {
        RemotePacket(type: .startStream)
    }

    public static var stopStream: RemotePacket {
        RemotePacket(type: .stopStream)
    }

    public static func frame(
        _ data: Data
    ) -> RemotePacket {
        RemotePacket(
            type: .frame,
            payload: data
        )
    }

    public static func captureError(
        _ message: String
    ) -> RemotePacket {
        RemotePacket(
            type: .captureError,
            payload: Data(message.utf8)
        )
    }

    public static func videoConfig(
        _ config: RemoteH264Config
    ) -> RemotePacket {
        RemotePacket(
            type: .videoConfig,
            payload: config.payload
        )
    }

    public static func videoFrame(
        _ data: Data
    ) -> RemotePacket {
        RemotePacket(
            type: .videoFrame,
            payload: data
        )
    }

    public static func pointerDelta(
        _ delta: RemotePointerDelta
    ) -> RemotePacket {
        RemotePacket(
            type: .pointerDelta,
            payload: delta.payload
        )
    }

    public static func pointerAbsolute(
        _ position: RemotePointerPosition
    ) -> RemotePacket {
        RemotePacket(
            type: .pointerAbsolute,
            payload: position.payload
        )
    }

    public static func mouseButton(
        _ event: RemoteMouseButtonEvent
    ) -> RemotePacket {
        RemotePacket(
            type: .mouseButton,
            payload: event.payload
        )
    }

    public static func scroll(
        _ delta: RemoteScrollDelta
    ) -> RemotePacket {
        RemotePacket(
            type: .scroll,
            payload: delta.payload
        )
    }

    public static func keyEvent(
        _ event: RemoteKeyEvent
    ) -> RemotePacket {
        RemotePacket(
            type: .keyEvent,
            payload: event.payload
        )
    }

    public static func textInput(
        _ text: String
    ) -> RemotePacket {
        RemotePacket(
            type: .textInput,
            payload: Data(text.utf8)
        )
    }

    public static func pairRequest(
        publicKey: Data
    ) -> RemotePacket {
        RemotePacket(
            type: .pairRequest,
            payload: publicKey
        )
    }

    public static func pairApproved(
        publicKey: Data
    ) -> RemotePacket {
        RemotePacket(
            type: .pairApproved,
            payload: publicKey
        )
    }

    public static var pairRejected: RemotePacket {
        RemotePacket(
            type: .pairRejected
        )
    }

    public static func authChallenge(
        _ challenge: Data
    ) -> RemotePacket {
        RemotePacket(
            type: .authChallenge,
            payload: challenge
        )
    }

    public static func authResponse(
        _ signature: Data
    ) -> RemotePacket {
        RemotePacket(
            type: .authResponse,
            payload: signature
        )
    }

    public static func taskCompleted(
        _ completion: RemoteTaskCompletion
    ) -> RemotePacket {
        RemotePacket(
            type: .taskCompleted,
            payload: completion.payload
        )
    }

    public static func apnsDeviceToken(
        _ token: String
    ) -> RemotePacket {
        RemotePacket(
            type: .apnsDeviceToken,
            payload: Data(token.utf8)
        )
    }

    public static var authAccepted: RemotePacket {
        RemotePacket(
            type: .authAccepted
        )
    }

    public static var authRejected: RemotePacket {
        RemotePacket(
            type: .authRejected
        )
    }
}

public struct RemotePacketParser: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(
        _ data: Data
    ) throws -> [RemotePacket] {
        buffer.append(data)

        var packets: [RemotePacket] = []

        while true {
            guard buffer.count >= RemoteProtocolInfo.headerSize else {
                break
            }

            let typeByte =
                buffer[buffer.startIndex]

            guard let type = RemotePacketType(
                rawValue: typeByte
            ) else {
                throw RemoteProtocolError.unknownPacketType(
                    typeByte
                )
            }

            let lengthStart = buffer.index(
                after: buffer.startIndex
            )

            let lengthEnd = buffer.index(
                lengthStart,
                offsetBy: 4
            )

            let lengthData =
                buffer[lengthStart..<lengthEnd]

            var length: UInt32 = 0

            _ = Swift.withUnsafeMutableBytes(
                of: &length
            ) { destination in
                lengthData.copyBytes(
                    to: destination
                )
            }

            let payloadLength = Int(
                UInt32(bigEndian: length)
            )

            guard payloadLength <= RemoteProtocolInfo.maxPayloadSize else {
                throw RemoteProtocolError.payloadTooLarge(
                    payloadLength
                )
            }

            let totalLength =
                RemoteProtocolInfo.headerSize
                + payloadLength

            guard buffer.count >= totalLength else {
                break
            }

            let payloadStart = buffer.index(
                buffer.startIndex,
                offsetBy: RemoteProtocolInfo.headerSize
            )

            let payloadEnd = buffer.index(
                payloadStart,
                offsetBy: payloadLength
            )

            let payload = Data(
                buffer[payloadStart..<payloadEnd]
            )

            packets.append(
                RemotePacket(
                    type: type,
                    payload: payload
                )
            )

            buffer.removeSubrange(
                buffer.startIndex..<payloadEnd
            )
        }

        return packets
    }
}

public enum RemoteProtocolError: Error, Equatable {
    case unknownPacketType(UInt8)
    case payloadTooLarge(Int)
}

public enum RemoteProtocolInfo {
    public static let version: UInt = 13
    public static let port: UInt16 = 42424
    public static let localHostPort: UInt16 = 42425
    public static let headerSize = 5
    public static let maxPayloadSize = 16 * 1024 * 1024
}
