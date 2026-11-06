import SwiftUI
import UIKit
import RemoteProtocol

struct ImmersiveSessionView: View {
    @ObservedObject var client:
        RemoteClient

    @ObservedObject var renderer:
        H264VideoRenderer

    let onExit: () -> Void

    @State private var controlsVisible =
        false

    @State private var keyboardActive =
        false

    @State private var modifiers:
        RemoteModifierFlags = []

    @State private var typingMirror = ""

    @State private var viewportMode:
        RemoteViewportMode = .fit

    @State private var interactionMode:
        RemoteInteractionMode = .trackpad

    @State private var viewportResetGeneration =
        0

    @State private var spaceControlsVisible =
        false

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            H264VideoView(
                renderer: renderer,
                viewportMode:
                    viewportMode,
                interactionMode:
                    interactionMode,
                viewportResetGeneration:
                    viewportResetGeneration,
                onPointerDelta: { dx, dy in
                    client.movePointer(
                        dx: dx,
                        dy: dy
                    )
                },
                onAbsolutePointer: { x, y in
                    client.movePointerAbsolute(
                        x: x,
                        y: y
                    )
                },
                onLeftClick: {
                    client.leftClick()
                },
                onRightClick: {
                    client.rightClick()
                },
                onDoubleClick: {
                    client.doubleClick()
                },
                onLeftDown: {
                    client.leftMouseDown()
                },
                onLeftUp: {
                    client.leftMouseUp()
                },
                onScroll: { dx, dy in
                    client.scroll(
                        dx: dx,
                        dy: dy
                    )
                }
            )
            .allowsHitTesting(
                !controlsVisible
                && !keyboardActive
            )
            .aspectRatio(
                renderer.aspectRatio,
                contentMode: .fit
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )
            .ignoresSafeArea()

            sessionOverlay
                .zIndex(1000)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(
            .hidden
        )
        .onAppear {
            ImmersiveSessionManager.enter()

            if !client.isStreaming {
                renderer.reset()
                client.startStream()
            }
        }
        .onDisappear {
            keyboardActive = false
            modifiers = []
            typingMirror = ""

            ImmersiveSessionManager.exit()
        }
        .safeAreaInset(
            edge: .bottom,
            spacing: 0
        ) {
            if keyboardActive {
                VStack(spacing: 0) {
                    typingField
                    modifierBar
                }
            }
        }
    }

    private var sessionOverlay:
        some View
    {
        VStack(spacing: 2) {
            Button {
                withAnimation(
                    .easeInOut(
                        duration: 0.15
                    )
                ) {
                    controlsVisible.toggle()

                    if !controlsVisible {
                        spaceControlsVisible = false
                    }
                }
            } label: {
                ZStack {
                    Color.clear

                    Capsule()
                        .fill(
                            .white.opacity(0.65)
                        )
                        .frame(
                            width: 50,
                            height: 6
                        )
                }
                .frame(
                    width: 100,
                    height: 44
                )
                .contentShape(
                    Rectangle()
                )
            }
            .buttonStyle(.plain)

            if controlsVisible {
                HStack(spacing: 10) {
                    Button {
                        viewportMode =
                            viewportMode == .fit
                            ? .fill
                            : .fit
                    } label: {
                        Label(
                            viewportMode == .fit
                                ? "Fit"
                                : "Fill",
                            systemImage:
                                viewportMode == .fit
                                ? "rectangle.arrowtriangle.2.inward"
                                : "rectangle.arrowtriangle.2.outward"
                        )
                    }

                    Button {
                        viewportResetGeneration &+= 1
                    } label: {
                        Label(
                            "Reset",
                            systemImage:
                                "arrow.counterclockwise"
                        )
                    }

                    Button {
                        interactionMode =
                            interactionMode == .trackpad
                            ? .touch
                            : .trackpad
                    } label: {
                        Label(
                            interactionMode == .trackpad
                                ? "Trackpad"
                                : "Touch",
                            systemImage:
                                interactionMode == .trackpad
                                ? "hand.draw"
                                : "hand.tap"
                        )
                    }

                    Button {
                        withAnimation(
                            .easeInOut(
                                duration: 0.15
                            )
                        ) {
                            spaceControlsVisible
                                .toggle()
                        }
                    } label: {
                        Label(
                            "Spaces",
                            systemImage:
                                "rectangle.3.group"
                        )
                    }

                    Button {
                        typingMirror = ""
                        keyboardActive = true
                        controlsVisible = false
                        spaceControlsVisible = false
                    } label: {
                        Label(
                            "Keyboard",
                            systemImage: "keyboard"
                        )
                    }

                    Button {
                        keyboardActive = false
                        modifiers = []
                        typingMirror = ""
                        spaceControlsVisible = false

                        client.stopStream()
                        onExit()
                    } label: {
                        Label(
                            "Exit",
                            systemImage:
                                "rectangle.portrait.and.arrow.right"
                        )
                    }
                }
                .buttonStyle(
                    .borderedProminent
                )
                .padding(8)
                .background(
                    .ultraThinMaterial,
                    in: Capsule()
                )
                .transition(
                    .opacity
                        .combined(
                            with: .scale(
                                scale: 0.95
                            )
                        )
                )

                if spaceControlsVisible {
                    spaceControls
                        .transition(
                            .opacity
                                .combined(
                                    with: .move(
                                        edge: .top
                                    )
                                )
                        )
                }
            }

            Spacer()
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .padding(
            .top,
            2
        )
    }

    private var spaceControls:
        some View
    {
        HStack(spacing: 8) {
            Button {
                client.sendKey(
                    MacKeyCode.leftArrow,
                    modifiers: [.control]
                )

                closeSessionControls()
            } label: {
                Image(
                    systemName:
                        "chevron.left"
                )
                .frame(
                    width: 34,
                    height: 28
                )
            }

            Button {
                client.sendKey(
                    MacKeyCode.upArrow,
                    modifiers: [.control]
                )

                closeSessionControls()
            } label: {
                Label(
                    "Mission",
                    systemImage:
                        "rectangle.3.group"
                )
            }

            Button {
                client.sendKey(
                    MacKeyCode.rightArrow,
                    modifiers: [.control]
                )

                closeSessionControls()
            } label: {
                Image(
                    systemName:
                        "chevron.right"
                )
                .frame(
                    width: 34,
                    height: 28
                )
            }
        }
        .buttonStyle(
            .borderedProminent
        )
        .padding(8)
        .background(
            .ultraThinMaterial,
            in: Capsule()
        )
    }

    private var typingField:
        some View
    {
        KeyboardCaptureView(
            isActive:
                $keyboardActive,
            text:
                $typingMirror,
            shortcutMode:
                modifiers.contains(
                    .command
                )
                || modifiers.contains(
                    .control
                )
                || modifiers.contains(
                    .option
                )
                || modifiers.contains(
                    .function
                ),
            onText: { text in
                client.sendText(
                    text,
                    modifiers:
                        modifiers
                )
            },
            onDelete: {
                client.sendKey(
                    MacKeyCode.deleteBackward,
                    modifiers:
                        modifiers
                )
            },
            onReturn: {
                client.sendKey(
                    MacKeyCode.returnKey,
                    modifiers:
                        modifiers
                )
            },
            onCaretMove: { movement in
                moveRemoteCaret(
                    by: movement
                )
            }
        )
        .frame(
            minHeight: 110,
            idealHeight: 130,
            maxHeight: 150
        )
        .padding(
            .horizontal,
            12
        )
        .background(
            .ultraThinMaterial
        )
    }

    private var modifierBar:
        some View
    {
        HStack(spacing: 8) {
            modifierButton(
                "⌘",
                .command
            )

            modifierButton(
                "⌥",
                .option
            )

            modifierButton(
                "⌃",
                .control
            )

            modifierButton(
                "⇧",
                .shift
            )

            Button("Esc") {
                client.sendKey(
                    MacKeyCode.escape,
                    modifiers:
                        modifiers
                )
            }

            Button("Tab") {
                client.sendKey(
                    MacKeyCode.tab,
                    modifiers:
                        modifiers
                )
            }

            Button("Done") {
                keyboardActive = false
                modifiers = []
                typingMirror = ""
            }
        }
        .buttonStyle(.bordered)
        .padding(8)
        .background(
            .ultraThinMaterial
        )
    }

    private func closeSessionControls() {
        withAnimation(
            .easeInOut(
                duration: 0.15
            )
        ) {
            spaceControlsVisible = false
            controlsVisible = false
        }
    }

    private func moveRemoteCaret(
        by movement: Int
    ) {
        guard movement != 0 else {
            return
        }

        let keyCode =
            movement < 0
            ? MacKeyCode.leftArrow
            : MacKeyCode.rightArrow

        let count =
            min(
                abs(movement),
                200
            )

        for _ in 0..<count {
            client.sendKey(
                keyCode
            )
        }
    }

    @ViewBuilder
    private func modifierButton(
        _ title: String,
        _ flag: RemoteModifierFlags
    ) -> some View {
        if modifiers.contains(flag) {
            Button(title) {
                modifiers.remove(flag)
            }
            .buttonStyle(
                .borderedProminent
            )
        } else {
            Button(title) {
                modifiers.insert(flag)
            }
            .buttonStyle(.bordered)
        }
    }
}
