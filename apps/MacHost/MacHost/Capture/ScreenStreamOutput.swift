import Foundation
import ScreenCaptureKit
import CoreMedia

final class ScreenStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onFrame: @Sendable (CMSampleBuffer) -> Void

    init(
        onFrame: @escaping @Sendable (CMSampleBuffer) -> Void
    ) {
        self.onFrame = onFrame
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else {
            return
        }

        guard CMSampleBufferIsValid(sampleBuffer) else {
            return
        }

        onFrame(sampleBuffer)
    }
}
