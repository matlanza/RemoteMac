import SwiftUI
import UIKit
import AVFoundation
import QuartzCore

enum RemoteViewportMode:
    Equatable
{
    case fit
    case fill
}

enum RemoteInteractionMode:
    Equatable
{
    case trackpad
    case touch
}

final class H264DisplayView:
    UIView,
    UIGestureRecognizerDelegate
{
    let videoLayer =
        AVSampleBufferDisplayLayer()

    var sourceAspectRatio:
        CGFloat = 16.0 / 10.0
    {
        didSet {
            setNeedsLayout()
        }
    }

    var viewportMode:
        RemoteViewportMode = .fit
    {
        didSet {
            if oldValue != viewportMode {
                resetViewport()
            }
        }
    }

    var interactionMode:
        RemoteInteractionMode =
            .trackpad

    var viewportResetGeneration = 0
    {
        didSet {
            if oldValue
                != viewportResetGeneration
            {
                resetViewport()
            }
        }
    }

    var onPointerDelta:
        ((CGFloat, CGFloat) -> Void)?

    var onAbsolutePointer:
        ((CGFloat, CGFloat) -> Void)?

    var onLeftClick:
        (() -> Void)?

    var onRightClick:
        (() -> Void)?

    var onDoubleClick:
        (() -> Void)?

    var onLeftDown:
        (() -> Void)?

    var onLeftUp:
        (() -> Void)?

    var onScroll:
        ((CGFloat, CGFloat) -> Void)?

    private var zoomScale:
        CGFloat = 1.0

    private var panOffset:
        CGPoint = .zero

    private var pinchStartZoom:
        CGFloat = 1.0

    private var pinchSourceAnchor:
        CGPoint = CGPoint(
            x: 0.5,
            y: 0.5
        )

    private var isPinching =
        false

    private var isRemoteDragging =
        false

    private var lastDragPoint:
        CGPoint?

    override init(
        frame: CGRect
    ) {
        super.init(
            frame: frame
        )

        clipsToBounds = true

        backgroundColor = .black

        videoLayer.videoGravity =
            .resizeAspect

        layer.addSublayer(
            videoLayer
        )

        installGestures()
    }

    required init?(
        coder: NSCoder
    ) {
        fatalError(
            "init(coder:) has not been implemented"
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        clampPanOffset()
        updateVideoFrame()
    }

    func resetViewport() {
        zoomScale = 1.0
        panOffset = .zero
        pinchStartZoom = 1.0

        setNeedsLayout()

        updateVideoFrame()
    }

    private func installGestures() {
        let pointerPan =
            UIPanGestureRecognizer(
                target: self,
                action: #selector(
                    handlePointerPan(_:)
                )
            )

        pointerPan.minimumNumberOfTouches =
            1

        pointerPan.maximumNumberOfTouches =
            1

        pointerPan.delegate = self

        addGestureRecognizer(
            pointerPan
        )

        let remoteScrollPan =
            UIPanGestureRecognizer(
                target: self,
                action: #selector(
                    handleRemoteScroll(_:)
                )
            )

        remoteScrollPan.minimumNumberOfTouches =
            2

        remoteScrollPan.maximumNumberOfTouches =
            2

        remoteScrollPan.delegate = self

        addGestureRecognizer(
            remoteScrollPan
        )

        let viewportPan =
            UIPanGestureRecognizer(
                target: self,
                action: #selector(
                    handleViewportPan(_:)
                )
            )

        viewportPan.minimumNumberOfTouches =
            3

        viewportPan.maximumNumberOfTouches =
            3

        viewportPan.delegate = self

        addGestureRecognizer(
            viewportPan
        )

        let pinch =
            UIPinchGestureRecognizer(
                target: self,
                action: #selector(
                    handlePinch(_:)
                )
            )

        pinch.delegate = self

        addGestureRecognizer(
            pinch
        )

        let singleTap =
            UITapGestureRecognizer(
                target: self,
                action: #selector(
                    handleSingleTap(_:)
                )
            )

        let doubleTap =
            UITapGestureRecognizer(
                target: self,
                action: #selector(
                    handleDoubleTap(_:)
                )
            )

        doubleTap.numberOfTapsRequired =
            2

        singleTap.require(
            toFail: doubleTap
        )

        addGestureRecognizer(
            singleTap
        )

        addGestureRecognizer(
            doubleTap
        )

        let rightTap =
            UITapGestureRecognizer(
                target: self,
                action: #selector(
                    handleRightTap(_:)
                )
            )

        rightTap.numberOfTouchesRequired =
            2

        addGestureRecognizer(
            rightTap
        )

        let dragPress =
            UILongPressGestureRecognizer(
                target: self,
                action: #selector(
                    handleDragPress(_:)
                )
            )

        dragPress.minimumPressDuration =
            0.22

        dragPress.allowableMovement =
            14

        dragPress.numberOfTouchesRequired =
            1

        dragPress.delegate = self

        addGestureRecognizer(
            dragPress
        )
    }

    @objc
    private func handlePinch(
        _ recognizer:
            UIPinchGestureRecognizer
    ) {
        switch recognizer.state {
        case .began:
            isPinching = true

            pinchStartZoom =
                zoomScale

            let location =
                recognizer.location(
                    in: self
                )

            let rect =
                currentVideoRect()

            if rect.width > 0,
               rect.height > 0
            {
                pinchSourceAnchor =
                    CGPoint(
                        x:
                            min(
                                1,
                                max(
                                    0,
                                    (
                                        location.x
                                        - rect.minX
                                    )
                                    / rect.width
                                )
                            ),
                        y:
                            min(
                                1,
                                max(
                                    0,
                                    (
                                        location.y
                                        - rect.minY
                                    )
                                    / rect.height
                                )
                            )
                    )
            }

        case .changed:
            let newZoom =
                min(
                    4.0,
                    max(
                        1.0,
                        pinchStartZoom
                        * recognizer.scale
                    )
                )

            zoomScale =
                newZoom

            let location =
                recognizer.location(
                    in: self
                )

            let base =
                baseVideoRect()

            let scaledWidth =
                base.width
                * zoomScale

            let scaledHeight =
                base.height
                * zoomScale

            let desiredMinX =
                location.x
                - pinchSourceAnchor.x
                * scaledWidth

            let desiredMinY =
                location.y
                - pinchSourceAnchor.y
                * scaledHeight

            let desiredCenterX =
                desiredMinX
                + scaledWidth / 2

            let desiredCenterY =
                desiredMinY
                + scaledHeight / 2

            panOffset =
                CGPoint(
                    x:
                        desiredCenterX
                        - base.midX,
                    y:
                        desiredCenterY
                        - base.midY
                )

            clampPanOffset()
            updateVideoFrame()

        case .ended,
             .cancelled,
             .failed:
            isPinching = false

            if zoomScale < 1.02 {
                resetViewport()
            }

        default:
            break
        }
    }

    @objc
    private func handleViewportPan(
        _ recognizer:
            UIPanGestureRecognizer
    ) {
        guard zoomScale > 1.001 else {
            recognizer.setTranslation(
                .zero,
                in: self
            )

            return
        }

        let delta =
            recognizer.translation(
                in: self
            )

        recognizer.setTranslation(
            .zero,
            in: self
        )

        panOffset.x += delta.x
        panOffset.y += delta.y

        clampPanOffset()
        updateVideoFrame()
    }

    @objc
    private func handleRemoteScroll(
        _ recognizer:
            UIPanGestureRecognizer
    ) {
        if isPinching {
            recognizer.setTranslation(
                .zero,
                in: self
            )

            return
        }

        let delta =
            recognizer.translation(
                in: self
            )

        recognizer.setTranslation(
            .zero,
            in: self
        )

        guard
            delta.x != 0
            || delta.y != 0
        else {
            return
        }

        onScroll?(
            delta.x,
            delta.y
        )
    }

    @objc
    private func handlePointerPan(
        _ recognizer:
            UIPanGestureRecognizer
    ) {
        if isRemoteDragging {
            recognizer.setTranslation(
                .zero,
                in: self
            )

            return
        }

        switch interactionMode {
        case .trackpad:
            let delta =
                recognizer.translation(
                    in: self
                )

            let velocity =
                recognizer.velocity(
                    in: self
                )

            recognizer.setTranslation(
                .zero,
                in: self
            )

            guard
                delta.x != 0
                || delta.y != 0
            else {
                return
            }

            let adjusted =
                TrackpadMotionProfile.adjusted(
                    delta: delta,
                    velocity: velocity
                )

            onPointerDelta?(
                adjusted.x,
                adjusted.y
            )

        case .touch:
            sendAbsolutePoint(
                recognizer.location(
                    in: self
                )
            )
        }
    }

    @objc
    private func handleSingleTap(
        _ recognizer:
            UITapGestureRecognizer
    ) {
        if interactionMode == .touch {
            guard sendAbsolutePoint(
                recognizer.location(
                    in: self
                )
            ) else {
                return
            }
        }

        onLeftClick?()
    }

    @objc
    private func handleDoubleTap(
        _ recognizer:
            UITapGestureRecognizer
    ) {
        if interactionMode == .touch {
            guard sendAbsolutePoint(
                recognizer.location(
                    in: self
                )
            ) else {
                return
            }
        }

        onDoubleClick?()
    }

    @objc
    private func handleRightTap(
        _ recognizer:
            UITapGestureRecognizer
    ) {
        if interactionMode == .touch {
            _ = sendAbsolutePoint(
                recognizer.location(
                    in: self
                )
            )
        }

        onRightClick?()
    }

    @objc
    private func handleDragPress(
        _ recognizer:
            UILongPressGestureRecognizer
    ) {
        let location =
            recognizer.location(
                in: self
            )

        switch recognizer.state {
        case .began:
            isRemoteDragging =
                true

            lastDragPoint =
                location

            if interactionMode == .touch {
                _ = sendAbsolutePoint(
                    location
                )
            }

            onLeftDown?()

        case .changed:
            guard isRemoteDragging else {
                return
            }

            switch interactionMode {
            case .trackpad:
                guard let previous =
                    lastDragPoint
                else {
                    return
                }

                let dx =
                    location.x
                    - previous.x

                let dy =
                    location.y
                    - previous.y

                lastDragPoint =
                    location

                if dx != 0
                    || dy != 0
                {
                    onPointerDelta?(
                        dx,
                        dy
                    )
                }

            case .touch:
                _ = sendAbsolutePoint(
                    location
                )
            }

        case .ended,
             .cancelled,
             .failed:
            if isRemoteDragging {
                onLeftUp?()
            }

            isRemoteDragging =
                false

            lastDragPoint =
                nil

        default:
            break
        }
    }

    @discardableResult
    private func sendAbsolutePoint(
        _ location: CGPoint
    ) -> Bool {
        guard let point =
            normalizedVideoPoint(
                for: location
            )
        else {
            return false
        }

        onAbsolutePointer?(
            point.x,
            point.y
        )

        return true
    }

    private func normalizedVideoPoint(
        for location: CGPoint
    ) -> CGPoint? {
        let rect =
            currentVideoRect()

        guard
            rect.width > 0,
            rect.height > 0,
            rect.contains(
                location
            )
        else {
            return nil
        }

        let x =
            (
                location.x
                - rect.minX
            )
            / rect.width

        let y =
            (
                location.y
                - rect.minY
            )
            / rect.height

        return CGPoint(
            x:
                min(
                    1,
                    max(
                        0,
                        x
                    )
                ),
            y:
                min(
                    1,
                    max(
                        0,
                        y
                    )
                )
        )
    }

    private func baseVideoRect()
        -> CGRect
    {
        guard
            bounds.width > 0,
            bounds.height > 0,
            sourceAspectRatio > 0
        else {
            return bounds
        }

        let containerAspect =
            bounds.width
            / bounds.height

        let width: CGFloat
        let height: CGFloat

        switch viewportMode {
        case .fit:
            if containerAspect
                > sourceAspectRatio
            {
                height =
                    bounds.height

                width =
                    height
                    * sourceAspectRatio
            } else {
                width =
                    bounds.width

                height =
                    width
                    / sourceAspectRatio
            }

        case .fill:
            if containerAspect
                > sourceAspectRatio
            {
                width =
                    bounds.width

                height =
                    width
                    / sourceAspectRatio
            } else {
                height =
                    bounds.height

                width =
                    height
                    * sourceAspectRatio
            }
        }

        return CGRect(
            x:
                bounds.midX
                - width / 2,
            y:
                bounds.midY
                - height / 2,
            width: width,
            height: height
        )
    }

    private func currentVideoRect()
        -> CGRect
    {
        let base =
            baseVideoRect()

        let width =
            base.width
            * zoomScale

        let height =
            base.height
            * zoomScale

        return CGRect(
            x:
                base.midX
                - width / 2
                + panOffset.x,
            y:
                base.midY
                - height / 2
                + panOffset.y,
            width: width,
            height: height
        )
    }

    private func clampPanOffset() {
        let base =
            baseVideoRect()

        let scaledWidth =
            base.width
            * zoomScale

        let scaledHeight =
            base.height
            * zoomScale

        let maxX =
            max(
                0,
                (
                    scaledWidth
                    - bounds.width
                )
                / 2
            )

        let maxY =
            max(
                0,
                (
                    scaledHeight
                    - bounds.height
                )
                / 2
            )

        panOffset.x =
            min(
                maxX,
                max(
                    -maxX,
                    panOffset.x
                )
            )

        panOffset.y =
            min(
                maxY,
                max(
                    -maxY,
                    panOffset.y
                )
            )
    }

    private func updateVideoFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(
            true
        )

        videoLayer.frame =
            currentVideoRect()

        CATransaction.commit()
    }

    func gestureRecognizer(
        _ gestureRecognizer:
            UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer:
            UIGestureRecognizer
    ) -> Bool {
        true
    }
}

@MainActor
struct H264VideoView:
    UIViewRepresentable
{
    @ObservedObject var renderer:
        H264VideoRenderer

    let viewportMode:
        RemoteViewportMode

    let interactionMode:
        RemoteInteractionMode

    let viewportResetGeneration:
        Int

    let onPointerDelta:
        (CGFloat, CGFloat) -> Void

    let onAbsolutePointer:
        (CGFloat, CGFloat) -> Void

    let onLeftClick:
        () -> Void

    let onRightClick:
        () -> Void

    let onDoubleClick:
        () -> Void

    let onLeftDown:
        () -> Void

    let onLeftUp:
        () -> Void

    let onScroll:
        (CGFloat, CGFloat) -> Void

    func makeUIView(
        context: Context
    ) -> H264DisplayView {
        let view =
            H264DisplayView()

        renderer.attach(
            displayLayer:
                view.videoLayer
        )

        configure(
            view
        )

        return view
    }

    func updateUIView(
        _ uiView:
            H264DisplayView,
        context: Context
    ) {
        renderer.attach(
            displayLayer:
                uiView.videoLayer
        )

        configure(
            uiView
        )
    }

    private func configure(
        _ view: H264DisplayView
    ) {
        view.sourceAspectRatio =
            renderer.aspectRatio

        view.viewportMode =
            viewportMode

        view.interactionMode =
            interactionMode

        view.viewportResetGeneration =
            viewportResetGeneration

        view.onPointerDelta =
            onPointerDelta

        view.onAbsolutePointer =
            onAbsolutePointer

        view.onLeftClick =
            onLeftClick

        view.onRightClick =
            onRightClick

        view.onDoubleClick =
            onDoubleClick

        view.onLeftDown =
            onLeftDown

        view.onLeftUp =
            onLeftUp

        view.onScroll =
            onScroll
    }
}
