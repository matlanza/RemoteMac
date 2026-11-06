import Foundation
import CoreGraphics
import ApplicationServices
import RemoteProtocol

final class InputController: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.example.remotemac.input"
    )

    private var heldButton:
        RemoteMouseButton?

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let key =
            kAXTrustedCheckOptionPrompt
                .takeUnretainedValue()
                as String

        let options = [
            key: true
        ] as CFDictionary

        _ = AXIsProcessTrustedWithOptions(
            options
        )
    }

    func movePointer(
        dx: Int32,
        dy: Int32
    ) {
        queue.async {
            guard AXIsProcessTrusted() else {
                self.requestAccessibilityPermission()
                return
            }

            guard let currentEvent =
                CGEvent(source: nil)
            else {
                return
            }

            let current =
                currentEvent.location

            let sensitivity: CGFloat = 1.0

            let destination = CGPoint(
                x:
                    current.x
                    + CGFloat(dx) * sensitivity,
                y:
                    current.y
                    + CGFloat(dy) * sensitivity
            )

            let eventType: CGEventType
            let cgButton: CGMouseButton

            switch self.heldButton {
            case .left:
                eventType = .leftMouseDragged
                cgButton = .left

            case .right:
                eventType = .rightMouseDragged
                cgButton = .right

            case .middle:
                eventType = .otherMouseDragged
                cgButton = .center

            case nil:
                eventType = .mouseMoved
                cgButton = .left
            }

            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: eventType,
                mouseCursorPosition: destination,
                mouseButton: cgButton
            ) else {
                return
            }

            event.post(
                tap: .cghidEventTap
            )
        }
    }

    func movePointerAbsolute(
        normalizedX: Double,
        normalizedY: Double
    ) {
        queue.async {
            guard AXIsProcessTrusted() else {
                self.requestAccessibilityPermission()
                return
            }

            let displayID =
                CGMainDisplayID()

            let bounds =
                CGDisplayBounds(
                    displayID
                )

            let x =
                bounds.minX
                + CGFloat(
                    min(
                        1.0,
                        max(
                            0.0,
                            normalizedX
                        )
                    )
                )
                * bounds.width

            let y =
                bounds.minY
                + CGFloat(
                    min(
                        1.0,
                        max(
                            0.0,
                            normalizedY
                        )
                    )
                )
                * bounds.height

            let destination =
                CGPoint(
                    x: x,
                    y: y
                )

            let eventType:
                CGEventType

            let button:
                CGMouseButton

            switch self.heldButton {
            case .left:
                eventType =
                    .leftMouseDragged
                button = .left

            case .right:
                eventType =
                    .rightMouseDragged
                button = .right

            case .middle:
                eventType =
                    .otherMouseDragged
                button = .center

            case nil:
                eventType =
                    .mouseMoved
                button = .left
            }

            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: eventType,
                mouseCursorPosition:
                    destination,
                mouseButton: button
            ) else {
                return
            }

            event.post(
                tap: .cghidEventTap
            )
        }
    }

    func mouseButton(
        _ button: RemoteMouseButton,
        action: RemoteButtonAction
    ) {
        queue.async {
            guard AXIsProcessTrusted() else {
                self.requestAccessibilityPermission()
                return
            }

            guard let currentEvent =
                CGEvent(source: nil)
            else {
                return
            }

            let location =
                currentEvent.location

            let cgButton: CGMouseButton
            let downType: CGEventType
            let upType: CGEventType

            switch button {
            case .left:
                cgButton = .left
                downType = .leftMouseDown
                upType = .leftMouseUp

            case .right:
                cgButton = .right
                downType = .rightMouseDown
                upType = .rightMouseUp

            case .middle:
                cgButton = .center
                downType = .otherMouseDown
                upType = .otherMouseUp
            }

            switch action {
            case .down:
                self.heldButton = button

                self.postMouse(
                    type: downType,
                    button: cgButton,
                    location: location,
                    clickState: 1
                )

            case .up:
                self.postMouse(
                    type: upType,
                    button: cgButton,
                    location: location,
                    clickState: 1
                )

                if self.heldButton == button {
                    self.heldButton = nil
                }

            case .click:
                self.postClick(
                    downType: downType,
                    upType: upType,
                    button: cgButton,
                    location: location,
                    count: 1
                )

            case .doubleClick:
                self.postClick(
                    downType: downType,
                    upType: upType,
                    button: cgButton,
                    location: location,
                    count: 2
                )
            }
        }
    }

    func scroll(
        dx: Int32,
        dy: Int32
    ) {
        queue.async {
            guard AXIsProcessTrusted() else {
                self.requestAccessibilityPermission()
                return
            }

            let horizontal =
                self.clamp(-dx)

            let vertical =
                self.clamp(-dy)

            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: vertical,
                wheel2: horizontal,
                wheel3: 0
            ) else {
                return
            }

            event.post(
                tap: .cghidEventTap
            )
        }
    }

    func keyEvent(
        _ remoteEvent: RemoteKeyEvent
    ) {
        queue.async {
            guard AXIsProcessTrusted() else {
                self.requestAccessibilityPermission()
                return
            }

            let flags =
                self.cgFlags(
                    from: remoteEvent.modifiers
                )

            switch remoteEvent.action {
            case .down:
                self.postKey(
                    keyCode: remoteEvent.keyCode,
                    keyDown: true,
                    flags: flags
                )

            case .up:
                self.postKey(
                    keyCode: remoteEvent.keyCode,
                    keyDown: false,
                    flags: flags
                )

            case .press:
                if remoteEvent.modifiers == [.control],
                   remoteEvent.keyCode == 123
                    || remoteEvent.keyCode == 124
                    || remoteEvent.keyCode == 126
                {
                    self.postControlSystemShortcut(
                        keyCode: remoteEvent.keyCode
                    )

                    return
                }

                self.postKey(
                    keyCode: remoteEvent.keyCode,
                    keyDown: true,
                    flags: flags
                )

                self.postKey(
                    keyCode: remoteEvent.keyCode,
                    keyDown: false,
                    flags: flags
                )
            }
        }
    }

    private func postControlSystemShortcut(
        keyCode: UInt16
    ) {
        let scriptSource: String

        switch keyCode {
        case 123:
            scriptSource =
                #"tell application "System Events" to key code 123 using control down"#

        case 124:
            scriptSource =
                #"tell application "System Events" to key code 124 using control down"#

        case 126:
            scriptSource =
                #"tell application "System Events" to key code 126 using control down"#

        default:
            return
        }

        guard let script =
            NSAppleScript(
                source: scriptSource
            )
        else {
            print(
                "RemoteMac could not create Spaces AppleScript"
            )

            return
        }

        var errorInfo:
            NSDictionary?

        _ = script.executeAndReturnError(
            &errorInfo
        )

        if let errorInfo {
            print(
                "RemoteMac Spaces AppleScript error:",
                errorInfo
            )
        }
    }

    func typeText(
        _ text: String
    ) {
        queue.async {
            guard AXIsProcessTrusted() else {
                self.requestAccessibilityPermission()
                return
            }

            let characters =
                Array(text.utf16)

            guard !characters.isEmpty else {
                return
            }

            guard
                let down = CGEvent(
                    keyboardEventSource: nil,
                    virtualKey: 0,
                    keyDown: true
                ),
                let up = CGEvent(
                    keyboardEventSource: nil,
                    virtualKey: 0,
                    keyDown: false
                )
            else {
                return
            }

            characters.withUnsafeBufferPointer {
                buffer in

                down.keyboardSetUnicodeString(
                    stringLength:
                        buffer.count,
                    unicodeString:
                        buffer.baseAddress
                )

                up.keyboardSetUnicodeString(
                    stringLength:
                        buffer.count,
                    unicodeString:
                        buffer.baseAddress
                )
            }

            down.post(
                tap: .cghidEventTap
            )

            up.post(
                tap: .cghidEventTap
            )
        }
    }

    private func postKey(
        keyCode: UInt16,
        keyDown: Bool,
        flags: CGEventFlags
    ) {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyCode),
            keyDown: keyDown
        ) else {
            return
        }

        event.flags = flags

        event.post(
            tap: .cghidEventTap
        )
    }

    private func cgFlags(
        from modifiers: RemoteModifierFlags
    ) -> CGEventFlags {
        var flags: CGEventFlags = []

        if modifiers.contains(.shift) {
            flags.insert(.maskShift)
        }

        if modifiers.contains(.control) {
            flags.insert(.maskControl)
        }

        if modifiers.contains(.option) {
            flags.insert(.maskAlternate)
        }

        if modifiers.contains(.command) {
            flags.insert(.maskCommand)
        }

        if modifiers.contains(.function) {
            flags.insert(.maskSecondaryFn)
        }

        return flags
    }

    private func postClick(
        downType: CGEventType,
        upType: CGEventType,
        button: CGMouseButton,
        location: CGPoint,
        count: Int
    ) {
        for clickNumber in 1...count {
            postMouse(
                type: downType,
                button: button,
                location: location,
                clickState: Int64(clickNumber)
            )

            postMouse(
                type: upType,
                button: button,
                location: location,
                clickState: Int64(clickNumber)
            )
        }
    }

    private func postMouse(
        type: CGEventType,
        button: CGMouseButton,
        location: CGPoint,
        clickState: Int64
    ) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: button
        ) else {
            return
        }

        event.setIntegerValueField(
            .mouseEventClickState,
            value: clickState
        )

        event.post(
            tap: .cghidEventTap
        )
    }

    private func clamp(
        _ value: Int32
    ) -> Int32 {
        min(
            120,
            max(
                -120,
                value
            )
        )
    }
}
