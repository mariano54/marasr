import AppKit
import SwiftData
import SwiftUI

@MainActor
final class DashboardWindowController: NSWindowController {
  init(appState: AppState, modelContainer: ModelContainer) {
    let view = DashboardView(appState: appState)
      .modelContainer(modelContainer)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "MaraSR"
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 680, height: 500)
    window.center()
    window.contentViewController = NSHostingController(rootView: view)
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  func show() {
    guard let window else {
      return
    }
    NSApp.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    NSApp.activate()
  }
}
