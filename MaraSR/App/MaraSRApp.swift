import SwiftData
import SwiftUI

@main
struct MaraSRApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  init() {
    OfflineAudio.activate()
    do {
      let container = try ModelContainer(
        for: TranscriptionRecord.self
      )
      let state = AppState(
        settings: SettingsStore(),
        permissions: PermissionManager(),
        modelContainer: container
      )
      appDelegate.appState = state
    } catch {
      fatalError("Unable to create MaraSR storage: \(error)")
    }
  }

  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}
