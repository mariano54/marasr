import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
  private let appState: AppState
  private let statusItem: NSStatusItem
  private let statusMenuItem = NSMenuItem()
  private var cancellables: Set<AnyCancellable> = []

  init(appState: AppState) {
    self.appState = appState
    statusItem = NSStatusBar.system.statusItem(
      withLength: NSStatusItem.squareLength
    )
    super.init()

    statusMenuItem.isEnabled = false

    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(statusMenuItem)
    menu.addItem(.separator())
    menu.addItem(
      item(
        title: "History and Settings",
        action: #selector(showDashboard),
        symbol: "gearshape"
      ))
    menu.addItem(
      item(
        title: "Show Tutorial",
        action: #selector(showTutorial),
        symbol: "graduationcap"
      ))
    menu.addItem(.separator())
    menu.addItem(
      item(
        title: "Quit MaraSR",
        action: #selector(quitApp)
      ))
    statusItem.menu = menu

    appState.$dictationState
      .combineLatest(appState.$modelReady)
      .sink { [weak self] _, _ in
        self?.refresh()
      }
      .store(in: &cancellables)

    refresh()
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    refresh()
  }

  private func refresh() {
    statusMenuItem.title = statusText
    let image = NSImage(
      systemSymbolName: symbolName,
      accessibilityDescription: "MaraSR"
    )
    image?.isTemplate = true
    statusItem.button?.image = image
  }

  private var symbolName: String {
    switch appState.dictationState {
    case .idle:
      "waveform"
    case .recording:
      "waveform.circle.fill"
    case .transcribing:
      "ellipsis.circle"
    }
  }

  private var statusText: String {
    if !appState.modelReady {
      return "Preparing Parakeet…"
    }
    switch appState.dictationState {
    case .idle:
      return "Ready — hold Right Command"
    case .recording:
      return "Listening…"
    case .transcribing:
      return "Transcribing…"
    }
  }

  private func item(
    title: String,
    action: Selector,
    symbol: String? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    if let symbol {
      item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
    return item
  }

  @objc private func showDashboard() {
    appState.showDashboard()
  }

  @objc private func showTutorial() {
    appState.showOnboarding()
  }

  @objc private func quitApp() {
    NSApplication.shared.terminate(nil)
  }
}
