@preconcurrency import FluidAudio

enum OfflineAudio {
  static func activate() {
    ModelHub.offlineMode = true
  }
}
