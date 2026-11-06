import UIKit

@MainActor
enum ImmersiveSessionManager {
    static func enter() {
        UIApplication.shared.isIdleTimerDisabled = true

        RemoteMacAppDelegate.supportedOrientations =
            .landscape

        updateSupportedOrientations()

        requestOrientation(
            .landscape
        )
    }

    static func exit() {
        UIApplication.shared.isIdleTimerDisabled = false

        RemoteMacAppDelegate.supportedOrientations =
            .portrait

        updateSupportedOrientations()

        requestOrientation(
            .portrait
        )
    }

    private static func updateSupportedOrientations() {
        guard
            let scene = activeScene(),
            let root =
                scene.windows
                    .first(where: \.isKeyWindow)?
                    .rootViewController
        else {
            return
        }

        root.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private static func requestOrientation(
        _ orientation:
            UIInterfaceOrientationMask
    ) {
        guard let scene =
            activeScene()
        else {
            return
        }

        scene.requestGeometryUpdate(
            .iOS(
                interfaceOrientations:
                    orientation
            )
        ) { error in
            print(
                "RemoteMac orientation error:",
                error.localizedDescription
            )
        }
    }

    private static func activeScene()
        -> UIWindowScene?
    {
        UIApplication.shared
            .connectedScenes
            .compactMap {
                $0 as? UIWindowScene
            }
            .first {
                $0.activationState
                    == .foregroundActive
            }
    }
}
