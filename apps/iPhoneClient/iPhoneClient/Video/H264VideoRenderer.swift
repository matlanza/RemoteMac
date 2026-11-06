import Foundation
import AVFoundation
import CoreMedia
import Combine
import RemoteProtocol

@MainActor
final class H264VideoRenderer: ObservableObject, @unchecked Sendable {
    @Published private(set) var status = "Waiting for H.264"
    @Published private(set) var framesDisplayed = 0
    @Published private(set) var aspectRatio: CGFloat = 16.0 / 10.0

    @Published private(set) var submitFPS:
        Double = 0

    private var totalSubmittedFrames = 0
    private var statsSubmittedFrames = 0

    private var statsStart =
        ProcessInfo.processInfo.systemUptime

    private var formatDescription: CMVideoFormatDescription?
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    func attach(
        displayLayer: AVSampleBufferDisplayLayer
    ) {
        self.displayLayer = displayLayer
    }

    func configure(
        _ config: RemoteH264Config
    ) {
        var description: CMVideoFormatDescription?

        let createStatus: OSStatus =
            config.sps.withUnsafeBytes { spsRawBuffer in
                config.pps.withUnsafeBytes { ppsRawBuffer in
                    guard
                        let spsBase = spsRawBuffer
                            .bindMemory(to: UInt8.self)
                            .baseAddress,
                        let ppsBase = ppsRawBuffer
                            .bindMemory(to: UInt8.self)
                            .baseAddress
                    else {
                        return -1
                    }

                    let pointers: [UnsafePointer<UInt8>] = [
                        spsBase,
                        ppsBase
                    ]

                    let sizes: [Int] = [
                        config.sps.count,
                        config.pps.count
                    ]

                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: config.nalUnitHeaderLength,
                        formatDescriptionOut: &description
                    )
                }
            }

        guard
            createStatus == noErr,
            let description
        else {
            status = "Format error \(createStatus)"
            return
        }

        formatDescription = description

        let dimensions =
            CMVideoFormatDescriptionGetDimensions(
                description
            )

        if dimensions.height > 0 {
            aspectRatio =
                CGFloat(dimensions.width)
                / CGFloat(dimensions.height)
        }

        framesDisplayed = 0
        submitFPS = 0

        totalSubmittedFrames = 0
        statsSubmittedFrames = 0

        statsStart =
            ProcessInfo.processInfo.systemUptime

        status =
            "H.264 configured • \(dimensions.width)×\(dimensions.height)"

        if let displayLayer {
            legacyFlush(
                displayLayer
            )
        }
    }

    func enqueue(
        _ encodedData: Data
    ) {
        guard
            let formatDescription,
            let displayLayer
        else {
            status = "Waiting for format/display layer"
            return
        }

        var blockBuffer: CMBlockBuffer?

        let blockStatus =
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: encodedData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: encodedData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

        guard
            blockStatus == kCMBlockBufferNoErr,
            let blockBuffer
        else {
            status = "Block buffer error \(blockStatus)"
            return
        }

        let copyStatus =
            encodedData.withUnsafeBytes { source -> OSStatus in
                guard let baseAddress =
                    source.baseAddress
                else {
                    return -1
                }

                return CMBlockBufferReplaceDataBytes(
                    with: baseAddress,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: encodedData.count
                )
            }

        guard copyStatus == kCMBlockBufferNoErr else {
            status = "H.264 copy error \(copyStatus)"
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = encodedData.count

        let sampleStatus =
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: 1,
                sampleTimingEntryCount: 0,
                sampleTimingArray: nil,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            )

        guard
            sampleStatus == noErr,
            let sampleBuffer
        else {
            status = "Sample buffer error \(sampleStatus)"
            return
        }

        if let attachments =
            CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: true
            ),
           CFArrayGetCount(attachments) > 0 {

            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(
                    attachments,
                    0
                ),
                to: CFMutableDictionary.self
            )

            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(
                    kCMSampleAttachmentKey_DisplayImmediately
                ).toOpaque(),
                Unmanaged.passUnretained(
                    kCFBooleanTrue
                ).toOpaque()
            )
        }

        let renderer =
            displayLayer.sampleBufferRenderer

        if let message =
            legacyFailureMessage(
                from: renderer
            ) {

            status =
                "Decoder failed: \(message)"

            legacyFlush(
                displayLayer
            )

            return
        }

        guard legacyEnqueue(
            sampleBuffer,
            on: renderer
        ) else {
            status = "Decoder enqueue unavailable"
            return
        }

        if let message =
            legacyFailureMessage(
                from: renderer
            ) {

            status =
                "Decoder failed: \(message)"

            return
        }

        totalSubmittedFrames += 1
        statsSubmittedFrames += 1

        let now =
            ProcessInfo.processInfo
                .systemUptime

        let elapsed =
            now - statsStart

        if elapsed >= 1.0 {
            let fps =
                Double(
                    statsSubmittedFrames
                )
                / elapsed

            framesDisplayed =
                totalSubmittedFrames

            submitFPS =
                fps

            statsSubmittedFrames = 0
            statsStart = now

            print(
                String(
                    format:
                        "RemoteMac RENDER • %.1f submitted FPS • ready %@",
                    fps,
                    displayLayer.isReadyForDisplay
                        ? "YES"
                        : "NO"
                )
            )

            if displayLayer.isReadyForDisplay {
                status =
                    String(
                        format:
                            "Displaying • %.1f FPS submitted",
                        fps
                    )
            } else {
                status =
                    "H.264 waiting for decoded image"
            }
        }
    }

    private func legacyEnqueue(
        _ sampleBuffer: CMSampleBuffer,
        on renderer:
            AVSampleBufferVideoRenderer
    ) -> Bool {
        let selector =
            NSSelectorFromString(
                "enqueueSampleBuffer:"
            )

        guard
            renderer.responds(
                to: selector
            )
        else {
            return false
        }

        _ = renderer.perform(
            selector,
            with: sampleBuffer
        )

        return true
    }

    private func legacyFailureMessage(
        from renderer:
            AVSampleBufferVideoRenderer
    ) -> String? {
        guard
            let error =
                renderer.value(
                    forKey: "error"
                ) as? NSError
        else {
            return nil
        }

        return error.localizedDescription
    }

    private func legacyFlush(
        _ displayLayer:
            AVSampleBufferDisplayLayer
    ) {
        let removeSelector =
            NSSelectorFromString(
                "flushAndRemoveImage"
            )

        if displayLayer.responds(
            to: removeSelector
        ) {
            _ = displayLayer.perform(
                removeSelector
            )

            return
        }

        let renderer =
            displayLayer
                .sampleBufferRenderer

        let flushSelector =
            NSSelectorFromString(
                "flush"
            )

        if renderer.responds(
            to: flushSelector
        ) {
            _ = renderer.perform(
                flushSelector
            )
        }
    }

    func reset() {
        formatDescription = nil
        framesDisplayed = 0
        submitFPS = 0

        totalSubmittedFrames = 0
        statsSubmittedFrames = 0

        statsStart =
            ProcessInfo.processInfo.systemUptime

        status = "Waiting for H.264"

        if let displayLayer {
            legacyFlush(
                displayLayer
            )
        }
    }
}
