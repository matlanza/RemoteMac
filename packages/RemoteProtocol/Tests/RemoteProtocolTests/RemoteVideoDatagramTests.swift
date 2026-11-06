import XCTest
@testable import RemoteProtocol

final class RemoteVideoDatagramTests:
    XCTestCase
{
    func testDatagramsNeverExceed1200Bytes()
        throws
    {
        let frame =
            Data(
                repeating:
                    0xA5,
                count:
                    100_000
            )

        let packets =
            try RemoteVideoDatagramCodec
                .packetize(
                    frame:
                        frame,
                    frameID:
                        42,
                    keyFrame:
                        false
                )

        XCTAssertGreaterThan(
            packets.count,
            1
        )

        for packet in packets {
            XCTAssertLessThanOrEqual(
                packet.count,
                1200
            )
        }
    }

    func testRoundTripOutOfOrder()
        throws
    {
        let frame =
            Data(
                (0..<12_345)
                    .map {
                        UInt8(
                            truncatingIfNeeded:
                                $0
                        )
                    }
            )

        let packets =
            try RemoteVideoDatagramCodec
                .packetize(
                    frame:
                        frame,
                    frameID:
                        100,
                    keyFrame:
                        true
                )

        var assembler =
            RemoteVideoFrameAssembler()

        var completed:
            RemoteVideoCompletedFrame?

        for packet
            in packets.reversed()
        {
            if let frame =
                try assembler.ingest(
                    packet
                )
            {
                completed =
                    frame
            }
        }

        XCTAssertEqual(
            completed?.frameID,
            100
        )

        XCTAssertEqual(
            completed?.isKeyFrame,
            true
        )

        XCTAssertEqual(
            completed?.data,
            frame
        )
    }

    func testDuplicateFragmentDoesNotBreakFrame()
        throws
    {
        let frame =
            Data(
                repeating:
                    0x4C,
                count:
                    5_000
            )

        let packets =
            try RemoteVideoDatagramCodec
                .packetize(
                    frame:
                        frame,
                    frameID:
                        200,
                    keyFrame:
                        false
                )

        var assembler =
            RemoteVideoFrameAssembler()

        XCTAssertNil(
            try assembler.ingest(
                packets[0]
            )
        )

        XCTAssertNil(
            try assembler.ingest(
                packets[0]
            )
        )

        var completed:
            RemoteVideoCompletedFrame?

        for packet
            in packets.dropFirst()
        {
            if let result =
                try assembler.ingest(
                    packet
                )
            {
                completed =
                    result
            }
        }

        XCTAssertEqual(
            completed?.data,
            frame
        )
    }

    func testNewerFrameSupersedesIncompleteOlderFrame()
        throws
    {
        let oldFrame =
            Data(
                repeating:
                    0x11,
                count:
                    8_000
            )

        let newFrame =
            Data(
                repeating:
                    0x22,
                count:
                    4_000
            )

        let oldPackets =
            try RemoteVideoDatagramCodec
                .packetize(
                    frame:
                        oldFrame,
                    frameID:
                        300,
                    keyFrame:
                        false
                )

        let newPackets =
            try RemoteVideoDatagramCodec
                .packetize(
                    frame:
                        newFrame,
                    frameID:
                        301,
                    keyFrame:
                        false
                )

        var assembler =
            RemoteVideoFrameAssembler()

        XCTAssertNil(
            try assembler.ingest(
                oldPackets[0]
            )
        )

        var completed:
            RemoteVideoCompletedFrame?

        for packet
            in newPackets
        {
            if let result =
                try assembler.ingest(
                    packet
                )
            {
                completed =
                    result
            }
        }

        XCTAssertEqual(
            completed?.frameID,
            301
        )

        XCTAssertEqual(
            completed?.data,
            newFrame
        )

        for packet
            in oldPackets.dropFirst()
        {
            XCTAssertNil(
                try assembler.ingest(
                    packet
                )
            )
        }
    }

    func testHeaderFieldsRoundTrip()
        throws
    {
        let frame =
            Data(
                repeating:
                    0x7E,
                count:
                    2_000
            )

        let packets =
            try RemoteVideoDatagramCodec
                .packetize(
                    frame:
                        frame,
                    frameID:
                        0x1234_5678,
                    keyFrame:
                        true
                )

        let first =
            try RemoteVideoDatagramCodec
                .decode(
                    packets[0]
                )

        XCTAssertEqual(
            first.frameID,
            0x1234_5678
        )

        XCTAssertEqual(
            first.fragmentIndex,
            0
        )

        XCTAssertEqual(
            first.fragmentCount,
            UInt16(
                packets.count
            )
        )

        XCTAssertTrue(
            first.flags
                .contains(
                    .keyFrame
                )
        )

        XCTAssertEqual(
            packets[0].count,
            RemoteVideoDatagramCodec
                .headerSize
            + first.payload.count
        )
    }

    func testCorruptMagicIsRejected()
        throws
    {
        let packets =
            try RemoteVideoDatagramCodec
                .packetize(
                    frame:
                        Data(
                            repeating:
                                1,
                            count:
                                100
                        ),
                    frameID:
                        1,
                    keyFrame:
                        false
                )

        var corrupt =
            packets[0]

        corrupt[0] =
            0

        XCTAssertThrowsError(
            try RemoteVideoDatagramCodec
                .decode(
                    corrupt
                )
        ) {
            XCTAssertEqual(
                $0 as?
                    RemoteVideoDatagramError,
                .invalidMagic
            )
        }
    }

    func testUInt32FrameWrapOrdering()
        throws
    {
        let beforeWrap =
            try RemoteVideoDatagramCodec
                .packetize(
                    frame:
                        Data(
                            repeating:
                                0xAA,
                            count:
                                2_000
                        ),
                    frameID:
                        UInt32.max,
                    keyFrame:
                        false
                )

        let afterWrap =
            try RemoteVideoDatagramCodec
                .packetize(
                    frame:
                        Data(
                            repeating:
                                0xBB,
                            count:
                                2_000
                        ),
                    frameID:
                        0,
                    keyFrame:
                        false
                )

        var assembler =
            RemoteVideoFrameAssembler()

        XCTAssertNil(
            try assembler.ingest(
                beforeWrap[0]
            )
        )

        var completed:
            RemoteVideoCompletedFrame?

        for packet
            in afterWrap
        {
            if let result =
                try assembler.ingest(
                    packet
                )
            {
                completed =
                    result
            }
        }

        XCTAssertEqual(
            completed?.frameID,
            0
        )
    }
}
