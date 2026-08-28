import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var appState: AppState?
  private var statusItem: StatusItemController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let appState else {
      return
    }
    statusItem = StatusItemController(appState: appState)
    appState.launch()
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    appState?.refreshPermissions()
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    appState?.showPrimaryWindow()
    return false
  }
}
