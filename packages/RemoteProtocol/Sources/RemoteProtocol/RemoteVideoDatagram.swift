import Foundation

public struct RemoteVideoDatagramFlags:
    OptionSet,
    Equatable,
    Sendable
{
    public let rawValue: UInt8

    public init(
        rawValue: UInt8
    ) {
        self.rawValue =
            rawValue
    }

    public static let keyFrame =
        RemoteVideoDatagramFlags(
            rawValue: 1 << 0
        )
}

public enum RemoteVideoDatagramError:
    Error,
    Equatable,
    Sendable
{
    case emptyFrame
    case tooManyFragments
    case datagramTooSmall
    case datagramTooLarge
    case invalidMagic
    case unsupportedVersion
    case invalidFragmentMetadata
    case lengthMismatch
    case inconsistentFrameMetadata
}

public struct RemoteVideoDatagramFragment:
    Equatable,
    Sendable
{
    public let frameID: UInt32
    public let fragmentIndex: UInt16
    public let fragmentCount: UInt16
    public let flags: RemoteVideoDatagramFlags
    public let payload: Data

    public init(
        frameID: UInt32,
        fragmentIndex: UInt16,
        fragmentCount: UInt16,
        flags: RemoteVideoDatagramFlags,
        payload: Data
    ) {
        self.frameID =
            frameID

        self.fragmentIndex =
            fragmentIndex

        self.fragmentCount =
            fragmentCount

        self.flags =
            flags

        self.payload =
            payload
    }
}

public struct RemoteVideoCompletedFrame:
    Equatable,
    Sendable
{
    public let frameID: UInt32
    public let isKeyFrame: Bool
    public let data: Data

    public init(
        frameID: UInt32,
        isKeyFrame: Bool,
        data: Data
    ) {
        self.frameID =
            frameID

        self.isKeyFrame =
            isKeyFrame

        self.data =
            data
    }
}

public enum RemoteVideoDatagramCodec {
    public static let version:
        UInt8 = 1

    public static let headerSize =
        16

    public static let maxDatagramSize =
        1200

    public static let maxPayloadSize =
        maxDatagramSize
        - headerSize

    private static let magic:
        [UInt8] =
        [
            0x52,
            0x4D,
            0x56,
            0x44
        ]

    public static func packetize(
        frame: Data,
        frameID: UInt32,
        keyFrame: Bool
    ) throws -> [Data] {
        guard !frame.isEmpty else {
            throw RemoteVideoDatagramError
                .emptyFrame
        }

        let count =
            (
                frame.count
                + maxPayloadSize
                - 1
            )
            / maxPayloadSize

        guard
            count > 0,
            count <= Int(UInt16.max)
        else {
            throw RemoteVideoDatagramError
                .tooManyFragments
        }

        let fragmentCount =
            UInt16(count)

        let flags:
            RemoteVideoDatagramFlags =
            keyFrame
            ? [.keyFrame]
            : []

        var datagrams:
            [Data] = []

        datagrams.reserveCapacity(
            count
        )

        for index in 0..<count {
            let start =
                index
                * maxPayloadSize

            let end =
                min(
                    start
                    + maxPayloadSize,
                    frame.count
                )

            let payload =
                frame.subdata(
                    in:
                        start..<end
                )

            var datagram =
                Data()

            datagram.reserveCapacity(
                headerSize
                + payload.count
            )

            datagram.append(
                contentsOf:
                    magic
            )

            datagram.append(
                version
            )

            datagram.append(
                flags.rawValue
            )

            appendUInt16(
                UInt16(index),
                to:
                    &datagram
            )

            appendUInt16(
                fragmentCount,
                to:
                    &datagram
            )

            appendUInt32(
                frameID,
                to:
                    &datagram
            )

            appendUInt16(
                UInt16(
                    payload.count
                ),
                to:
                    &datagram
            )

            datagram.append(
                payload
            )

            guard
                datagram.count
                    <= maxDatagramSize
            else {
                throw RemoteVideoDatagramError
                    .datagramTooLarge
            }

            datagrams.append(
                datagram
            )
        }

        return datagrams
    }

    public static func decode(
        _ datagram: Data
    ) throws
        -> RemoteVideoDatagramFragment
    {
        guard
            datagram.count
                >= headerSize
        else {
            throw RemoteVideoDatagramError
                .datagramTooSmall
        }

        guard
            datagram.count
                <= maxDatagramSize
        else {
            throw RemoteVideoDatagramError
                .datagramTooLarge
        }

        let bytes =
            [UInt8](
                datagram
            )

        guard
            Array(
                bytes[0..<4]
            )
            == magic
        else {
            throw RemoteVideoDatagramError
                .invalidMagic
        }

        guard
            bytes[4]
                == version
        else {
            throw RemoteVideoDatagramError
                .unsupportedVersion
        }

        let flags =
            RemoteVideoDatagramFlags(
                rawValue:
                    bytes[5]
            )

        let fragmentIndex =
            readUInt16(
                bytes,
                at:
                    6
            )

        let fragmentCount =
            readUInt16(
                bytes,
                at:
                    8
            )

        let frameID =
            readUInt32(
                bytes,
                at:
                    10
            )

        let payloadLength =
            Int(
                readUInt16(
                    bytes,
                    at:
                        14
                )
            )

        guard
            fragmentCount > 0,
            fragmentIndex
                < fragmentCount
        else {
            throw RemoteVideoDatagramError
                .invalidFragmentMetadata
        }

        guard
            payloadLength
                <= maxPayloadSize,
            datagram.count
                == headerSize
                    + payloadLength
        else {
            throw RemoteVideoDatagramError
                .lengthMismatch
        }

        let payload =
            datagram.subdata(
                in:
                    headerSize
                    ..<
                    datagram.count
            )

        return RemoteVideoDatagramFragment(
            frameID:
                frameID,
            fragmentIndex:
                fragmentIndex,
            fragmentCount:
                fragmentCount,
            flags:
                flags,
            payload:
                payload
        )
    }

    private static func appendUInt16(
        _ value: UInt16,
        to data: inout Data
    ) {
        data.append(
            UInt8(
                (
                    value >> 8
                )
                & 0xFF
            )
        )

        data.append(
            UInt8(
                value
                & 0xFF
            )
        )
    }

    private static func appendUInt32(
        _ value: UInt32,
        to data: inout Data
    ) {
        data.append(
            UInt8(
                (
                    value >> 24
                )
                & 0xFF
            )
        )

        data.append(
            UInt8(
                (
                    value >> 16
                )
                & 0xFF
            )
        )

        data.append(
            UInt8(
                (
                    value >> 8
                )
                & 0xFF
            )
        )

        data.append(
            UInt8(
                value
                & 0xFF
            )
        )
    }

    private static func readUInt16(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt16 {
        (
            UInt16(
                bytes[offset]
            )
            << 8
        )
        |
        UInt16(
            bytes[offset + 1]
        )
    }

    private static func readUInt32(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt32 {
        (
            UInt32(
                bytes[offset]
            )
            << 24
        )
        |
        (
            UInt32(
                bytes[offset + 1]
            )
            << 16
        )
        |
        (
            UInt32(
                bytes[offset + 2]
            )
            << 8
        )
        |
        UInt32(
            bytes[offset + 3]
        )
    }
}

public struct RemoteVideoFrameAssembler:
    Sendable
{
    private struct PendingFrame:
        Sendable
    {
        let frameID: UInt32
        let fragmentCount: UInt16
        let flags: RemoteVideoDatagramFlags

        var fragments:
            [Data?]

        var receivedCount:
            Int
    }

    private var pending:
        PendingFrame?

    private var newestFrameID:
        UInt32?

    public init() {}

    public mutating func reset() {
        pending =
            nil

        newestFrameID =
            nil
    }

    public mutating func ingest(
        _ datagram: Data
    ) throws
        -> RemoteVideoCompletedFrame?
    {
        let fragment =
            try RemoteVideoDatagramCodec
                .decode(
                    datagram
                )

        if let newestFrameID {
            if
                fragment.frameID
                    == newestFrameID
            {
                guard
                    pending != nil
                else {
                    return nil
                }

            } else if Self.isNewer(
                fragment.frameID,
                than:
                    newestFrameID
            ) {
                begin(
                    fragment
                )

            } else {
                return nil
            }

        } else {
            begin(
                fragment
            )
        }

        guard
            var current =
                pending
        else {
            return nil
        }

        guard
            current.frameID
                == fragment.frameID,
            current.fragmentCount
                == fragment.fragmentCount,
            current.flags
                == fragment.flags
        else {
            throw RemoteVideoDatagramError
                .inconsistentFrameMetadata
        }

        let index =
            Int(
                fragment.fragmentIndex
            )

        if
            current.fragments[index]
                == nil
        {
            current.fragments[index] =
                fragment.payload

            current.receivedCount +=
                1
        }

        pending =
            current

        guard
            current.receivedCount
                == Int(
                    current.fragmentCount
                )
        else {
            return nil
        }

        var frame =
            Data()

        let totalBytes =
            current.fragments.reduce(
                0
            ) {
                partial,
                part in

                partial
                + (
                    part?.count
                    ?? 0
                )
            }

        frame.reserveCapacity(
            totalBytes
        )

        for fragmentData
            in current.fragments
        {
            guard
                let fragmentData
            else {
                return nil
            }

            frame.append(
                fragmentData
            )
        }

        pending =
            nil

        return RemoteVideoCompletedFrame(
            frameID:
                current.frameID,
            isKeyFrame:
                current.flags
                    .contains(
                        .keyFrame
                    ),
            data:
                frame
        )
    }

    private mutating func begin(
        _ fragment:
            RemoteVideoDatagramFragment
    ) {
        newestFrameID =
            fragment.frameID

        pending =
            PendingFrame(
                frameID:
                    fragment.frameID,
                fragmentCount:
                    fragment.fragmentCount,
                flags:
                    fragment.flags,
                fragments:
                    Array(
                        repeating:
                            nil,
                        count:
                            Int(
                                fragment
                                    .fragmentCount
                            )
                    ),
                receivedCount:
                    0
            )
    }

    private static func isNewer(
        _ candidate: UInt32,
        than reference: UInt32
    ) -> Bool {
        let delta =
            candidate
            &- reference

        return
            delta != 0
            && delta
                < 0x8000_0000
    }
}
