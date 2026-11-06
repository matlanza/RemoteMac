import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

struct H264StreamConfig: Sendable {
    let nalUnitHeaderLength: Int32
    let sps: Data
    let pps: Data
}

struct H264EncodedFrame: Sendable {
    let frameNumber: Int
    let data: Data
    let isKeyFrame: Bool
    let hardwareAccelerated: Bool
}

enum H264EncoderError: LocalizedError {
    case sessionCreation(OSStatus)
    case property(String, OSStatus)
    case prepare(OSStatus)
    case hardwareUnavailable
    case encode(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sessionCreation(let status):
            return "H.264 session creation failed with OSStatus \(status)."

        case .property(let name, let status):
            return "Could not set \(name). OSStatus \(status)."

        case .prepare(let status):
            return "Could not prepare H.264 encoder. OSStatus \(status)."

        case .hardwareUnavailable:
            return "VideoToolbox did not provide a hardware H.264 encoder."

        case .encode(let status):
            return "H.264 frame encoding failed. OSStatus \(status)."
        }
    }
}

final class H264Encoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private let frameDuration: CMTime

    private let onStreamConfig: @Sendable (H264StreamConfig) -> Void
    private let onEncodedFrame: @Sendable (H264EncodedFrame) -> Void
    private let onError: @Sendable (String) -> Void

    private let lock = NSLock()

    private var frameNumber = 0
    private var submittedFrames = 0
    private var didEmitConfig = false
    private var forceNextKeyFrame = false

    private(set) var hardwareAccelerated = false

    init(
        width: Int,
        height: Int,
        fps: Int32,
        bitrate: Int,
        onStreamConfig: @escaping @Sendable (H264StreamConfig) -> Void,
        onEncodedFrame: @escaping @Sendable (H264EncodedFrame) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) throws {
        self.frameDuration = CMTime(
            value: 1,
            timescale: fps
        )

        self.onStreamConfig = onStreamConfig
        self.onEncodedFrame = onEncodedFrame
        self.onError = onError

        var specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]

        if #available(macOS 11.3, *) {
            specification[
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl
            ] = true
        }

        var createdSession: VTCompressionSession?

        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &createdSession
        )

        guard
            createStatus == noErr,
            let createdSession
        else {
            throw H264EncoderError.sessionCreation(
                createStatus
            )
        }

        self.session = createdSession

        try setProperty(
            kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanTrue,
            name: "RealTime"
        )

        try setProperty(
            kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse,
            name: "AllowFrameReordering"
        )

        try setProperty(
            kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: fps),
            name: "ExpectedFrameRate"
        )

        try setProperty(
            kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: bitrate),
            name: "AverageBitRate"
        )

        try setProperty(
            kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(
                value: Int(fps)
            ),
            name: "MaxKeyFrameInterval"
        )

        try setProperty(
            kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Main_AutoLevel,
            name: "H264ProfileLevel"
        )

        let prepareStatus =
            VTCompressionSessionPrepareToEncodeFrames(
                createdSession
            )

        guard prepareStatus == noErr else {
            VTCompressionSessionInvalidate(
                createdSession
            )

            self.session = nil

            throw H264EncoderError.prepare(
                prepareStatus
            )
        }

        var hardwareValue: CFTypeRef?

        let hardwareStatus = VTSessionCopyProperty(
            createdSession,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: kCFAllocatorDefault,
            valueOut: &hardwareValue
        )

        if hardwareStatus == noErr,
           let number = hardwareValue as? NSNumber {
            guard number.boolValue else {
                VTCompressionSessionInvalidate(
                    createdSession
                )

                self.session = nil

                throw H264EncoderError.hardwareUnavailable
            }
        }

        self.hardwareAccelerated = true
    }

    @discardableResult
    func updateBitrate(
        _ bitrate: Int
    ) -> OSStatus {
        guard let session else {
            return -1
        }

        return VTSessionSetProperty(
            session,
            key:
                kVTCompressionPropertyKey_AverageBitRate,
            value:
                NSNumber(value: bitrate)
        )
    }

    func requestKeyFrame() {
        lock.lock()

        forceNextKeyFrame =
            true

        lock.unlock()
    }

    func encode(
        pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime
    ) {
        guard let session else {
            return
        }

        lock.lock()

        let shouldForceKeyFrame =
            submittedFrames == 0
            || forceNextKeyFrame

        forceNextKeyFrame =
            false

        submittedFrames += 1

        lock.unlock()

        let frameProperties: CFDictionary?

        if shouldForceKeyFrame {
            frameProperties = [
                kVTEncodeFrameOptionKey_ForceKeyFrame:
                    kCFBooleanTrue as Any
            ] as CFDictionary
        } else {
            frameProperties = nil
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: frameDuration,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else {
                return
            }

            guard status == noErr else {
                self.onError(
                    H264EncoderError.encode(
                        status
                    ).localizedDescription
                )
                return
            }

            guard
                let sampleBuffer,
                CMSampleBufferDataIsReady(
                    sampleBuffer
                )
            else {
                return
            }

            let isKeyFrame: Bool = {
                guard
                    let attachments =
                        CMSampleBufferGetSampleAttachmentsArray(
                            sampleBuffer,
                            createIfNecessary:
                                false
                        ),
                    CFArrayGetCount(
                        attachments
                    ) > 0
                else {
                    return true
                }

                let dictionary =
                    unsafeBitCast(
                        CFArrayGetValueAtIndex(
                            attachments,
                            0
                        ),
                        to:
                            CFDictionary.self
                    )

                let notSyncKey =
                    Unmanaged
                        .passUnretained(
                            kCMSampleAttachmentKey_NotSync
                        )
                        .toOpaque()

                return !CFDictionaryContainsKey(
                    dictionary,
                    notSyncKey
                )
            }()

            self.emitConfigIfNeeded(
                from: sampleBuffer
            )

            guard
                let blockBuffer =
                    CMSampleBufferGetDataBuffer(
                        sampleBuffer
                    )
            else {
                self.onError(
                    "Encoded H.264 frame had no data buffer."
                )
                return
            }

            let dataLength =
                CMBlockBufferGetDataLength(
                    blockBuffer
                )

            guard dataLength > 0 else {
                return
            }

            var encodedData = Data(
                count: dataLength
            )

            let copyStatus =
                encodedData.withUnsafeMutableBytes {
                    destination -> OSStatus in

                    guard let baseAddress =
                        destination.baseAddress
                    else {
                        return -1
                    }

                    return CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: dataLength,
                        destination: baseAddress
                    )
                }

            guard copyStatus == noErr else {
                self.onError(
                    "Could not copy encoded H.264 bytes. OSStatus \(copyStatus)."
                )
                return
            }

            self.lock.lock()
            self.frameNumber += 1
            let number = self.frameNumber
            self.lock.unlock()

            self.onEncodedFrame(
                H264EncodedFrame(
                    frameNumber: number,
                    data: encodedData,
                    isKeyFrame:
                        isKeyFrame,
                    hardwareAccelerated:
                        self.hardwareAccelerated
                )
            )
        }

        if status != noErr {
            onError(
                H264EncoderError.encode(
                    status
                ).localizedDescription
            )
        }
    }

    func stop() {
        guard let session else {
            return
        }

        VTCompressionSessionCompleteFrames(
            session,
            untilPresentationTimeStamp: .invalid
        )

        VTCompressionSessionInvalidate(
            session
        )

        self.session = nil
    }

    private func emitConfigIfNeeded(
        from sampleBuffer: CMSampleBuffer
    ) {
        lock.lock()

        if didEmitConfig {
            lock.unlock()
            return
        }

        lock.unlock()

        guard let formatDescription =
            CMSampleBufferGetFormatDescription(
                sampleBuffer
            )
        else {
            return
        }

        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0

        let spsStatus =
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: &spsPointer,
                parameterSetSizeOut: &spsSize,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: &nalUnitHeaderLength
            )

        guard
            spsStatus == noErr,
            let spsPointer
        else {
            return
        }

        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0

        let ppsStatus =
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPointer,
                parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )

        guard
            ppsStatus == noErr,
            let ppsPointer
        else {
            return
        }

        let config = H264StreamConfig(
            nalUnitHeaderLength:
                nalUnitHeaderLength,
            sps: Data(
                bytes: spsPointer,
                count: spsSize
            ),
            pps: Data(
                bytes: ppsPointer,
                count: ppsSize
            )
        )

        lock.lock()

        guard !didEmitConfig else {
            lock.unlock()
            return
        }

        didEmitConfig = true
        lock.unlock()

        onStreamConfig(
            config
        )
    }

    private func setProperty(
        _ key: CFString,
        value: CFTypeRef,
        name: String
    ) throws {
        guard let session else {
            throw H264EncoderError.hardwareUnavailable
        }

        let status = VTSessionSetProperty(
            session,
            key: key,
            value: value
        )

        guard status == noErr else {
            throw H264EncoderError.property(
                name,
                status
            )
        }
    }

    deinit {
        if let session {
            VTCompressionSessionInvalidate(
                session
            )
        }
    }
}
