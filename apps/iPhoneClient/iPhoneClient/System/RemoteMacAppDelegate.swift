import UIKit
import UserNotifications
import RemoteProtocol

extension Notification.Name {
    static let remoteMacAPNSTokenDidUpdate =
        Notification.Name(
            "RemoteMacAPNSTokenDidUpdate"
        )
}


@MainActor
final class RemoteMacAppDelegate:
    NSObject,
    UIApplicationDelegate,
    UNUserNotificationCenterDelegate
{
    static var supportedOrientations:
        UIInterfaceOrientationMask = .portrait

    private var hasBecomeActiveOnce =
        false

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions:
            [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center =
            UNUserNotificationCenter.current()

        center.delegate = self

        center.requestAuthorization(
            options: [
                .alert,
                .sound,
                .badge
            ]
        ) { granted, error in
            if let error {
                print(
                    "REMOTEMAC_NOTIFY permission error: \(error.localizedDescription)"
                )
            } else {
                print(
                    "REMOTEMAC_NOTIFY permission granted: \(granted)"
                )
            }
        }

        print(
            "REMOTEMAC_APNS requesting remote notification registration"
        )

        application.registerForRemoteNotifications()

        center.getNotificationSettings { settings in
            print(
                "REMOTEMAC_NOTIFY_SETTINGS auth=\(settings.authorizationStatus.rawValue) alert=\(settings.alertSetting.rawValue) sound=\(settings.soundSetting.rawValue) lock=\(settings.lockScreenSetting.rawValue) center=\(settings.notificationCenterSetting.rawValue)"
            )
        }

        NotificationCenter.default
            .addObserver(
                self,
                selector:
                    #selector(
                        handleDidBecomeActiveNotification(
                            _:
                        )
                    ),
                name:
                    UIApplication
                        .didBecomeActiveNotification,
                object:
                    nil
            )

        TailscaleKitProbe.shared.start()

        Task {
            await EmbeddedTailscaleBridge
                .shared
                .start()
        }

        return true
    }

    @objc
    private func handleDidBecomeActiveNotification(
        _ notification: Notification
    ) {

        UIApplication.shared
            .registerForRemoteNotifications()

        if !hasBecomeActiveOnce {
            hasBecomeActiveOnce =
                true

            print(
                "REMOTEMAC_LIFECYCLE initial active"
            )

            return
        }

        print(
            "REMOTEMAC_LIFECYCLE became active again"
        )

        Task {
            await EmbeddedTailscaleBridge
                .shared
                .markDidBecomeActive()
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token =
            deviceToken
                .map {
                    String(
                        format: "%02x",
                        $0
                    )
                }
                .joined()

        UserDefaults.standard.set(
            token,
            forKey: "RemoteMacAPNSDeviceToken"
        )

        NotificationCenter.default.post(
            name:
                .remoteMacAPNSTokenDidUpdate,
            object:
                token
        )

        let suffix =
            String(
                token.suffix(8)
            )

        print(
            "REMOTEMAC_APNS registered device token suffix=\(suffix)"
        )
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        print(
            "REMOTEMAC_APNS REGISTRATION FAILED: \(error.localizedDescription)"
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let content =
            notification.request.content

        print(
            "REMOTEMAC_APNS RECEIVED foreground id=\(notification.request.identifier) title=\(content.title)"
        )

        return [
            .banner,
            .list,
            .sound
        ]
    }

    static func postTaskCompletion(
        _ completion: RemoteTaskCompletion
    ) {
        let completedDate =
            Date(
                timeIntervalSince1970:
                    Double(
                        completion
                            .completedAtUnixMilliseconds
                    )
                    / 1000.0
            )

        let formatter =
            DateFormatter()

        formatter.timeStyle = .short
        formatter.dateStyle = .none

        let content =
            UNMutableNotificationContent()

        content.title =
            "\(completion.deviceName) finished a task"

        content.subtitle =
            completion.source

        content.body =
            "\(completion.task)\nCompleted at \(formatter.string(from: completedDate))"

        content.sound = .default

        content.interruptionLevel =
            .active

        content.relevanceScore =
            1.0

        content.threadIdentifier =
            "remotemac-task-completions"

        content.userInfo = [
            "deviceID":
                completion.deviceID,
            "deviceName":
                completion.deviceName,
            "source":
                completion.source,
            "task":
                completion.task
        ]

        let request =
            UNNotificationRequest(
                identifier:
                    "remotemac-task-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

        UNUserNotificationCenter
            .current()
            .add(request) { error in
                if let error {
                    print(
                        "REMOTEMAC_NOTIFY delivery error: \(error.localizedDescription)"
                    )
                } else {
                    print(
                        "REMOTEMAC_NOTIFY scheduled task completion"
                    )
                }
            }
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.supportedOrientations
    }
}
