import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class PermissionManager: ObservableObject {
  @Published private(set) var microphoneGranted = false
  @Published private(set) var inputMonitoringGranted = false
  @Published private(set) var accessibilityGranted = false

  var allRequiredGranted: Bool {
    microphoneGranted
      && inputMonitoringGranted
      && accessibilityGranted
  }

  init() {
    refresh()
  }

  func refresh() {
    microphoneGranted =
      AVCaptureDevice.authorizationStatus(
        for: .audio
      ) == .authorized
    inputMonitoringGranted = CGPreflightListenEventAccess()
    accessibilityGranted = CGPreflightPostEventAccess()
  }

  func requestMicrophone() async {
    microphoneGranted = await AVCaptureDevice.requestAccess(
      for: .audio
    )
  }

  func requestInputMonitoring() {
    inputMonitoringGranted = CGRequestListenEventAccess()
    if !inputMonitoringGranted {
      openInputMonitoringSettings()
    }
  }

  func requestAccessibility() {
    accessibilityGranted = CGRequestPostEventAccess()
    if !accessibilityGranted {
      openAccessibilitySettings()
    }
  }

  func openMicrophoneSettings() {
    openPrivacyPane(anchor: "Privacy_Microphone")
  }

  func openAccessibilitySettings() {
    openPrivacyPane(anchor: "Privacy_Accessibility")
  }

  func openInputMonitoringSettings() {
    openPrivacyPane(anchor: "Privacy_ListenEvent")
  }

  private func openPrivacyPane(anchor: String) {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
      )
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}
