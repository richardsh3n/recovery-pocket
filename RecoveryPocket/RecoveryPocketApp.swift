import SwiftUI

@main struct RecoveryPocketApp: App {
    @StateObject private var health = HealthStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            PocketRoot().environmentObject(health)
                .task { await health.resume() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await health.resume() } }
                }
        }
    }
}
