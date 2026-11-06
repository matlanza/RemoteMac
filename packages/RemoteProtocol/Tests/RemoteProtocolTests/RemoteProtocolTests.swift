import XCTest
@testable import RemoteProtocol

final class RemoteProtocolTests: XCTestCase {
    func testProtocolVersion() {
        XCTAssertEqual(RemoteProtocolInfo.version, 13)
    }

    func testPingPacketRoundTrip() throws {
        var parser = RemotePacketParser()

        let packets = try parser.append(
            RemotePacket.ping.wireData
        )

        XCTAssertEqual(
            packets,
            [.ping]
        )
    }

    func testFramePacketRoundTrip() throws {
        let original = Data(
            [1, 2, 3, 4, 5, 6]
        )

        var parser = RemotePacketParser()

        let packets = try parser.append(
            RemotePacket.frame(original).wireData
        )

        XCTAssertEqual(
            packets[0].payload,
            original
        )
    }

    func testFragmentedPacket() throws {
        let data = RemotePacket.videoFrame(
            Data(repeating: 42, count: 10_000)
        ).wireData

        var parser = RemotePacketParser()

        XCTAssertTrue(
            try parser.append(
                data.prefix(123)
            ).isEmpty
        )

        let packets = try parser.append(
            data.dropFirst(123)
        )

        XCTAssertEqual(
            packets.count,
            1
        )

        XCTAssertEqual(
            packets[0].type,
            .videoFrame
        )

        XCTAssertEqual(
            packets[0].payload.count,
            10_000
        )
    }

    func testMultiplePacketsTogether() throws {
        var data = Data()

        data.append(
            RemotePacket.ping.wireData
        )

        data.append(
            RemotePacket.startStream.wireData
        )

        data.append(
            RemotePacket.stopStream.wireData
        )

        var parser = RemotePacketParser()

        let packets = try parser.append(
            data
        )

        XCTAssertEqual(
            packets.map(\.type),
            [
                .ping,
                .startStream,
                .stopStream
            ]
        )
    }

    func testCaptureErrorPayload() throws {
        let message = "Permission denied"

        var parser = RemotePacketParser()

        let packets = try parser.append(
            RemotePacket.captureError(
                message
            ).wireData
        )

        XCTAssertEqual(
            String(
                data: packets[0].payload,
                encoding: .utf8
            ),
            message
        )
    }

    func testH264ConfigRoundTrip() throws {
        let original = RemoteH264Config(
            nalUnitHeaderLength: 4,
            sps: Data(
                [0x67, 0x64, 0x00, 0x1F]
            ),
            pps: Data(
                [0x68, 0xEE, 0x3C, 0x80]
            )
        )

        var parser = RemotePacketParser()

        let packets = try parser.append(
            RemotePacket.videoConfig(
                original
            ).wireData
        )

        XCTAssertEqual(
            packets.count,
            1
        )

        XCTAssertEqual(
            packets[0].type,
            .videoConfig
        )

        XCTAssertEqual(
            RemoteH264Config(
                payload: packets[0].payload
            ),
            original
        )
    }

    func testH264VideoFrameRoundTrip() throws {
        let encoded = Data(
            repeating: 0xAB,
            count: 8192
        )

        var parser = RemotePacketParser()

        let packets = try parser.append(
            RemotePacket.videoFrame(
                encoded
            ).wireData
        )

        XCTAssertEqual(
            packets[0].type,
            .videoFrame
        )

        XCTAssertEqual(
            packets[0].payload,
            encoded
        )
    }

    func testPointerDeltaRoundTrip() throws {
        let original = RemotePointerDelta(
            dx: 145,
            dy: -82
        )

        var parser = RemotePacketParser()

        let packets = try parser.append(
            RemotePacket.pointerDelta(
                original
            ).wireData
        )

        XCTAssertEqual(
            RemotePointerDelta(
                payload: packets[0].payload
            ),
            original
        )
    }

    func testMouseButtonRoundTrip() throws {
        let original = RemoteMouseButtonEvent(
            button: .right,
            action: .click
        )

        var parser = RemotePacketParser()

        let packets = try parser.append(
            RemotePacket.mouseButton(
                original
            ).wireData
        )

        XCTAssertEqual(
            RemoteMouseButtonEvent(
                payload: packets[0].payload
            ),
            original
        )
    }



    func testScrollRoundTrip() throws {
        let original = RemoteScrollDelta(
            dx: -73,
            dy: 142
        )

        var parser = RemotePacketParser()

        let packets = try parser.append(
            RemotePacket.scroll(
                original
            ).wireData
        )

        XCTAssertEqual(
            RemoteScrollDelta(
                payload: packets[0].payload
            ),
            original
        )
    }

    func testDoubleClickRoundTrip() throws {
        let original = RemoteMouseButtonEvent(
            button: .left,
            action: .doubleClick
        )

        var parser = RemotePacketParser()

        let packets = try parser.append(
            RemotePacket.mouseButton(
                original
            ).wireData
        )

        XCTAssertEqual(
            RemoteMouseButtonEvent(
                payload: packets[0].payload
            ),
            original
        )
    }


    func testKeyboardEventRoundTrip() throws {
        let original = RemoteKeyEvent(
            keyCode: 0x08,
            action: .press,
            modifiers: [
                .command,
                .shift
            ]
        )

        var parser = RemotePacketParser()

        let packets = try parser.append(
            RemotePacket.keyEvent(
                original
            ).wireData
        )

        XCTAssertEqual(
            RemoteKeyEvent(
                payload: packets[0].payload
            ),
            original
        )
    }

    func testTextInputRoundTrip() throws {
        let original = "Hello 👋"

        var parser = RemotePacketParser()

        let packets = try parser.append(
            RemotePacket.textInput(
                original
            ).wireData
        )

        XCTAssertEqual(
            String(
                data: packets[0].payload,
                encoding: .utf8
            ),
            original
        )
    }


    func testPairingPacketsRoundTrip() throws {
        let publicKey = Data(
            repeating: 0xA7,
            count: 32
        )

        var parser = RemotePacketParser()

        var combined = Data()

        combined.append(
            RemotePacket.pairRequest(
                publicKey: publicKey
            ).wireData
        )

        combined.append(
            RemotePacket.pairApproved(
                publicKey: publicKey
            ).wireData
        )

        combined.append(
            RemotePacket.pairRejected.wireData
        )

        let packets = try parser.append(
            combined
        )

        XCTAssertEqual(
            packets.map(\.type),
            [
                .pairRequest,
                .pairApproved,
                .pairRejected
            ]
        )

        XCTAssertEqual(
            packets[0].payload,
            publicKey
        )

        XCTAssertEqual(
            packets[1].payload,
            publicKey
        )
    }


    func testAuthenticationPacketsRoundTrip() throws {
        let challenge = Data(
            repeating: 0x42,
            count: 32
        )

        let signature = Data(
            repeating: 0x99,
            count: 64
        )

        var data = Data()

        data.append(
            RemotePacket.authChallenge(
                challenge
            ).wireData
        )

        data.append(
            RemotePacket.authResponse(
                signature
            ).wireData
        )

        data.append(
            RemotePacket.authAccepted.wireData
        )

        data.append(
            RemotePacket.authRejected.wireData
        )

        var parser = RemotePacketParser()

        let packets = try parser.append(
            data
        )

        XCTAssertEqual(
            packets.map(\.type),
            [
                .authChallenge,
                .authResponse,
                .authAccepted,
                .authRejected
            ]
        )

        XCTAssertEqual(
            packets[0].payload,
            challenge
        )

        XCTAssertEqual(
            packets[1].payload,
            signature
        )
    }


    func testAbsolutePointerRoundTrip() throws {
        let original = RemotePointerPosition(
            normalizedX: 0.237,
            normalizedY: 0.814
        )

        var parser = RemotePacketParser()

        let packets = try parser.append(
            RemotePacket.pointerAbsolute(
                original
            ).wireData
        )

        XCTAssertEqual(
            packets[0].type,
            .pointerAbsolute
        )

        XCTAssertEqual(
            RemotePointerPosition(
                payload: packets[0].payload
            ),
            original
        )
    }

}
