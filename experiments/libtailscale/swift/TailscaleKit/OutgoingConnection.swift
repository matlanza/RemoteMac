// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import Combine

/// ConnectionState indicates the state of individual TSConnection instances
public enum ConnectionState {
    case idle           ///< Reads and writes are not possible.  Connections will transition to connected automatically
    case connected      ///< Connected and ready to read/write
    case closed         ///< Closed and ready to be disposed of.  Closed connections cannot be reconnected.
    case failed         ///< The attempt to dial the connection failed
}

/// ListenerState indicates the state of individual TSListener instances
public enum ListenerState {
    case idle           ///< Waiting.
    case listening      ///< Listening
    case closed         ///< Closed and ready to be disposed of.
    case failed         ///< The attempt to start the listener failed
}

public typealias TailscaleHandle = Int32
public typealias TailscaleConnection = Int32
public typealias TailscaleListener = Int32

/// Outgoing connections are used to send data to other endpoints
/// on the tailnet.
///
/// For HTTP(s), consider using URLSession.tailscaleSession
public actor OutgoingConnection {
    private var tailscale: TailscaleHandle
    private var proto: NetProtocol
    private var address: String
    private var conn: TailscaleConnection = 0

    private let logger: LogSink

    /// The state of the connection.  Listen for transitions to determine
    /// if the connection may be used for send/receive operations.
    public var state: ConnectionState = .idle

    /// Creates a new outgoing connection
    ///
    /// @param tailscale The tailscale Server to use
    /// @param address The remote address and port
    /// @param proto The ip protocol
    /// @param logger
    ///
    /// @throws TailscaleError on failure
    public init(tailscale: TailscaleHandle,
         to address: String,
         proto: NetProtocol,
         logger: LogSink) async throws {

        self.logger = logger
        self.proto = proto
        self.address = address
        self.tailscale = tailscale
    }

    /// Connects the outgoing connection to the remote.  On success, the
    /// connection state will be .connected.
    ///
    /// @See tailscale_dial in Tailscale.h
    ///
    /// @throws TailscaleError on failure
    public func connect() async throws  {
        let res = tailscale_dial(tailscale, proto.rawValue, address, &conn)

        guard res == 0 else {
            self.state = .failed
            throw TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())
        }

        self.state = .connected
    }

    deinit {
        if conn != 0 {
            Darwin.close(conn)
        }
    }

    /// Closes the outgoing connection.  Further sends are not possible.
    /// Connections will be closed on deallocation.  Sets the connection
    /// state to .closed
    public func close() {
        if conn != 0 {
            Darwin.close(conn)
            conn = 0
        }
        state = .closed
    }

    /// Receives up to maximumLength bytes from the connection.
    ///
    /// The blocking socket read runs off the actor executor so
    /// reads and writes can proceed concurrently.
    public func receive(
        maximumLength: Int = 65_536,
        timeout: Int32 = -1
    ) async throws -> Data {
        print(
            "TSOUT_RECEIVE enter state=\(state) conn=\(conn)"
        )

        guard state == .connected else {
            print(
                "TSOUT_RECEIVE CLOSED because state=\(state)"
            )
            throw TailscaleError.connectionClosed
        }

        guard conn != 0 else {
            print(
                "TSOUT_RECEIVE CLOSED because conn=0"
            )
            throw TailscaleError.connectionClosed
        }

        let socket = conn
        let length = max(1, maximumLength)

        return try await withCheckedThrowingContinuation {
            continuation in

            DispatchQueue.global(
                qos: .userInitiated
            ).async {
                var descriptor = pollfd(
                    fd: socket,
                    events: Int16(POLLIN),
                    revents: 0
                )

                let pollResult =
                    Darwin.poll(
                        &descriptor,
                        1,
                        timeout
                    )

                print(
                    "TSOUT_RECEIVE poll result=\(pollResult) revents=\(descriptor.revents)"
                )

                guard pollResult > 0 else {
                    print(
                        "TSOUT_RECEIVE readFailed at poll errno=\(errno)"
                    )

                    continuation.resume(
                        throwing:
                            TailscaleError.readFailed
                    )
                    return
                }

                var buffer =
                    [UInt8](
                        repeating: 0,
                        count: length
                    )

                let bytesRead =
                    buffer.withUnsafeMutableBytes {
                        rawBuffer -> Int in

                        Darwin.read(
                            socket,
                            rawBuffer.baseAddress,
                            length
                        )
                    }

                print(
                    "TSOUT_RECEIVE read bytes=\(bytesRead) errno=\(errno)"
                )

                guard bytesRead >= 0 else {
                    continuation.resume(
                        throwing:
                            TailscaleError.readFailed
                    )
                    return
                }

                guard bytesRead > 0 else {
                    print(
                        "TSOUT_RECEIVE CLOSED because read returned EOF"
                    )

                    continuation.resume(
                        throwing:
                            TailscaleError.connectionClosed
                    )
                    return
                }

                continuation.resume(
                    returning:
                        Data(
                            buffer[0..<bytesRead]
                        )
                )
            }
        }
    }

    /// Sends the given data to the connection
    ///
    /// @throws TailscaleError on failure
    public func send(_ data: Data) throws {
        guard state == .connected else {
            throw TailscaleError.connectionClosed
        }

        guard !data.isEmpty else {
            return
        }

        var totalWritten = 0

        while totalWritten < data.count {
            let bytesWritten: Int =
                data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress =
                        rawBuffer.baseAddress
                    else {
                        return 0
                    }

                    return Darwin.write(
                        conn,
                        baseAddress.advanced(
                            by: totalWritten
                        ),
                        data.count - totalWritten
                    )
                }

            if bytesWritten > 0 {
                totalWritten += bytesWritten
                continue
            }

            if bytesWritten == -1,
               errno == EINTR
            {
                continue
            }

            throw TailscaleError.shortWrite
        }
    }
}

public enum DatagramConnectionError: Error, Sendable {
    case timeout
}

public actor DatagramConnection {
    private let tailscale: TailscaleHandle
    private let address: String
    private let logger: LogSink

    private var conn: Int32 = 0

    public private(set) var state: ConnectionState = .idle

    public init(
        tailscale: TailscaleHandle,
        to address: String,
        logger: LogSink
    ) {
        self.tailscale = tailscale
        self.address = address
        self.logger = logger
    }

    public func connect() throws {
        guard state == .idle else {
            return
        }

        let result =
            tailscale_udp_dial(
                tailscale,
                address,
                &conn
            )

        guard result == 0 else {
            state = .failed

            throw TailscaleError.fromPosixErrCode(
                result,
                tailscale.getErrorMessage()
            )
        }

        state = .connected

        logger.log(
            "UDP datagram connection established to \(address)"
        )
    }

    public func send(_ data: Data) throws {
        guard state == .connected,
              conn != 0
        else {
            throw TailscaleError.connectionClosed
        }

        guard !data.isEmpty else {
            return
        }

        let socket = conn

        let result: Int32 =
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress =
                    rawBuffer.baseAddress
                else {
                    return 0
                }

                return tailscale_udp_send(
                    socket,
                    baseAddress,
                    data.count
                )
            }

        guard result >= 0 else {
            throw TailscaleError.fromPosixErrCode(
                result,
                tailscale.getErrorMessage()
            )
        }

        guard Int(result) == data.count else {
            throw TailscaleError.shortWrite
        }
    }

    public func receive(
        maximumLength: Int = 65_535,
        timeout: Int32 = -1
    ) async throws -> Data {
        guard state == .connected,
              conn != 0
        else {
            throw TailscaleError.connectionClosed
        }

        let socket = conn
        let length =
            max(
                1,
                maximumLength
            )

        return try await withCheckedThrowingContinuation {
            continuation in

            DispatchQueue.global(
                qos: .userInitiated
            ).async {
                var buffer =
                    [UInt8](
                        repeating: 0,
                        count: length
                    )

                let result: Int32 =
                    buffer.withUnsafeMutableBytes {
                        rawBuffer in

                        tailscale_udp_recv(
                            socket,
                            rawBuffer.baseAddress,
                            length,
                            timeout
                        )
                    }

                if result == -2 {
                    continuation.resume(
                        throwing:
                            DatagramConnectionError.timeout
                    )
                    return
                }

                guard result >= 0 else {
                    continuation.resume(
                        throwing:
                            TailscaleError.readFailed
                    )
                    return
                }

                continuation.resume(
                    returning:
                        Data(
                            buffer.prefix(
                                Int(result)
                            )
                        )
                )
            }
        }
    }

    public func close() {
        guard conn != 0 else {
            state = .closed
            return
        }

        let socket = conn

        conn = 0
        state = .closed

        _ = tailscale_udp_close(
            socket
        )
    }
}

