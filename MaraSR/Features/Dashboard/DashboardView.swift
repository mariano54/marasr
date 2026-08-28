import SwiftUI

struct DashboardView: View {
  @ObservedObject var appState: AppState

  var body: some View {
    TabView {
      HistoryView(appState: appState)
        .tabItem {
          Label("History", systemImage: "clock.arrow.circlepath")
        }

      SettingsView(
        appState: appState,
        settings: appState.settings,
        permissions: appState.permissions
      )
      .tabItem {
        Label("Settings", systemImage: "gearshape")
      }
    }
    .frame(minWidth: 680, minHeight: 500)
  }
}
