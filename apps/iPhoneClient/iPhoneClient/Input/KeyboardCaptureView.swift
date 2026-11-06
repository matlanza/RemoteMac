import SwiftUI
import UIKit

final class RemoteKeyboardTextView: UITextView {
    var onRemoteDelete: (() -> Void)?
    var shortcutMode = false

    override func deleteBackward() {
        onRemoteDelete?()

        if !shortcutMode {
            super.deleteBackward()
        }
    }
}

struct KeyboardCaptureView: UIViewRepresentable {
    @Binding var isActive: Bool
    @Binding var text: String

    let shortcutMode: Bool

    let onText: (String) -> Void
    let onDelete: () -> Void
    let onReturn: () -> Void
    let onCaretMove: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            shortcutMode: shortcutMode,
            onText: onText,
            onReturn: onReturn,
            onCaretMove: onCaretMove
        )
    }

    func makeUIView(
        context: Context
    ) -> RemoteKeyboardTextView {
        let view =
            RemoteKeyboardTextView()

        view.delegate =
            context.coordinator

        view.onRemoteDelete =
            onDelete

        view.shortcutMode =
            shortcutMode

        view.backgroundColor =
            .clear

        view.font =
            .monospacedSystemFont(
                ofSize: 14,
                weight: .regular
            )

        view.textColor =
            .label

        view.tintColor =
            .systemBlue

        view.textContainerInset =
            UIEdgeInsets(
                top: 10,
                left: 12,
                bottom: 10,
                right: 12
            )

        view.textContainer
            .lineFragmentPadding = 0

        view.textContainer
            .widthTracksTextView = true

        view.textContainer
            .maximumNumberOfLines = 0

        view.textContainer
            .lineBreakMode =
                .byWordWrapping

        view.isScrollEnabled =
            true

        view.showsHorizontalScrollIndicator =
            false

        view.showsVerticalScrollIndicator =
            false

        view.alwaysBounceHorizontal =
            false

        view.alwaysBounceVertical =
            false

        view.keyboardDismissMode =
            .none

        view.autocorrectionType =
            .no

        view.spellCheckingType =
            .no

        view.autocapitalizationType =
            .none

        view.smartDashesType =
            .no

        view.smartQuotesType =
            .no

        view.smartInsertDeleteType =
            .no

        view.text =
            text

        return view
    }

    func updateUIView(
        _ uiView: RemoteKeyboardTextView,
        context: Context
    ) {
        context.coordinator.text =
            $text

        context.coordinator.shortcutMode =
            shortcutMode

        context.coordinator.onText =
            onText

        context.coordinator.onReturn =
            onReturn

        context.coordinator.onCaretMove =
            onCaretMove

        uiView.onRemoteDelete =
            onDelete

        uiView.shortcutMode =
            shortcutMode

        if !uiView.isFirstResponder,
           uiView.text != text {

            uiView.text =
                text

            let length =
                (text as NSString).length

            uiView.selectedRange =
                NSRange(
                    location: length,
                    length: 0
                )

            context.coordinator
                .synchronizeCaret(
                    to: length
                )
        }

        if isActive {
            if !uiView.isFirstResponder {
                DispatchQueue.main.async {
                    uiView.becomeFirstResponder()
                }
            }
        } else if uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    final class Coordinator:
        NSObject,
        UITextViewDelegate
    {
        var text: Binding<String>

        var shortcutMode: Bool

        var onText: (String) -> Void
        var onReturn: () -> Void
        var onCaretMove: (Int) -> Void

        private var lastCaretOffset = 0

        private var expectedCaretOffset:
            Int?

        init(
            text: Binding<String>,
            shortcutMode: Bool,
            onText:
                @escaping (String) -> Void,
            onReturn:
                @escaping () -> Void,
            onCaretMove:
                @escaping (Int) -> Void
        ) {
            self.text =
                text

            self.shortcutMode =
                shortcutMode

            self.onText =
                onText

            self.onReturn =
                onReturn

            self.onCaretMove =
                onCaretMove
        }

        func synchronizeCaret(
            to offset: Int
        ) {
            expectedCaretOffset =
                offset

            lastCaretOffset =
                offset
        }

        func textViewDidBeginEditing(
            _ textView: UITextView
        ) {
            lastCaretOffset =
                textView
                    .selectedRange
                    .location

            revealCaret(
                textView
            )
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range:
                NSRange,
            replacementText:
                String
        ) -> Bool {
            if replacementText == "\n" {
                onReturn()

                expectedCaretOffset =
                    range.location

                return false
            }

            if replacementText.isEmpty {
                expectedCaretOffset =
                    range.location

                return !shortcutMode
            }

            onText(
                replacementText
            )

            if shortcutMode {
                expectedCaretOffset =
                    lastCaretOffset

                return false
            }

            expectedCaretOffset =
                range.location
                + (
                    replacementText
                        as NSString
                ).length

            return true
        }

        func textViewDidChange(
            _ textView: UITextView
        ) {
            revealCaret(
                textView
            )
        }

        func textViewDidEndEditing(
            _ textView: UITextView
        ) {
            text.wrappedValue =
                textView.text
        }

        func textViewDidChangeSelection(
            _ textView: UITextView
        ) {
            let current =
                textView
                    .selectedRange
                    .location

            if let expected =
                expectedCaretOffset,
               current == expected {

                expectedCaretOffset =
                    nil

                lastCaretOffset =
                    current

                revealCaret(
                    textView
                )

                return
            }

            expectedCaretOffset =
                nil

            let movement =
                current
                - lastCaretOffset

            if movement != 0 {
                onCaretMove(
                    movement
                )
            }

            lastCaretOffset =
                current

            revealCaret(
                textView
            )
        }

        private func revealCaret(
            _ textView: UITextView
        ) {
            DispatchQueue.main.async {
                textView.layoutIfNeeded()

                textView.scrollRangeToVisible(
                    textView.selectedRange
                )
            }
        }
    }
}
