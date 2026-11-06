import SwiftUI

@main
struct iPhoneClientApp: App {
    @UIApplicationDelegateAdaptor(
        RemoteMacAppDelegate.self
    )
    private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
