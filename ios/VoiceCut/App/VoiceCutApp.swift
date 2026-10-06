import SwiftUI

@main
struct VoiceCutApp: App {
    @StateObject private var store = ProjectStore.shared
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .environmentObject(settings)
        }
    }
}
