import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController {
  init(appState: AppState) {
    let view = OnboardingView(
      appState: appState,
      permissions: appState.permissions
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 610),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Welcome to MaraSR"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
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
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    NSApp.activate()
  }
}
