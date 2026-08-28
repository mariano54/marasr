import AppKit
import SwiftUI

@MainActor
final class OverlayPanelController {
  let model: OverlayViewModel

  private let panel: NSPanel
  private let hostingView: NSHostingView<RecordingOverlayView>
  private var hideTask: Task<Void, Never>?

  init() {
    let model = OverlayViewModel()
    self.model = model
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 36),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .stationary,
      .ignoresCycle,
    ]
    hostingView = NSHostingView(
      rootView: RecordingOverlayView(model: model)
    )
    hostingView.sizingOptions = [.intrinsicContentSize]
    panel.contentView = hostingView

    model.onContentChange = { [weak self] in
      Task { @MainActor in
        await Task.yield()
        self?.resizeAndPositionPanel(animated: self?.panel.isVisible == true)
      }
    }
  }

  func showRecording() {
    hideTask?.cancel()
    model.reset()
    model.phase = .recording
    resizeAndPositionPanel(animated: false)
    panel.orderFrontRegardless()
  }

  func showTranscribing() {
    hideTask?.cancel()
    model.phase = .transcribing
    resizeAndPositionPanel(animated: panel.isVisible)
    panel.orderFrontRegardless()
  }

  func showSuccess() {
    model.phase = .success
    scheduleHide(after: .milliseconds(650))
  }

  func showError(_ message: String) {
    model.phase = .failed(message)
    resizeAndPositionPanel(animated: panel.isVisible)
    panel.orderFrontRegardless()
    scheduleHide(after: .seconds(2))
  }

  func hide() {
    hideTask?.cancel()
    model.phase = .hidden
    panel.orderOut(nil)
  }

  private func resizeAndPositionPanel(animated: Bool) {
    let screen = NSScreen.main ?? NSScreen.screens.first
    guard let visibleFrame = screen?.visibleFrame else {
      return
    }

    hostingView.invalidateIntrinsicContentSize()
    hostingView.layoutSubtreeIfNeeded()
    let height = max(36, hostingView.fittingSize.height)
    let frame = NSRect(
      x: visibleFrame.midX - 320,
      y: visibleFrame.maxY - height,
      width: 640,
      height: height
    )

    guard animated else {
      panel.setFrame(frame, display: true)
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(
        name: .easeOut
      )
      panel.animator().setFrame(frame, display: true)
    }
  }

  private func scheduleHide(after duration: Duration) {
    hideTask?.cancel()
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: duration)
      guard !Task.isCancelled else {
        return
      }
      self?.hide()
    }
  }
}
