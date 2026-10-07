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
                .preferredColorScheme(.dark)
                .onAppear {
                    // 舊版可能選了辨識不出字的 Base／Small：改回自動
                    if Transcriber.broken.contains(settings.model) { settings.model = "" }
                    Transcriber.shared.prewarm(model: settings.resolvedModel)
                }
        }
    }
}
