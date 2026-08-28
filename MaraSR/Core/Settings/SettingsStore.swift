import Foundation

@MainActor
final class SettingsStore: ObservableObject {
  @Published var holdToTalkHotkey: HotkeyConfiguration {
    didSet { save(holdToTalkHotkey, key: Keys.holdToTalkHotkey) }
  }

  @Published var pasteLastHotkey: HotkeyConfiguration {
    didSet { save(pasteLastHotkey, key: Keys.pasteLastHotkey) }
  }

  @Published var glossary: [GlossaryEntry] {
    didSet { save(glossary, key: Keys.glossary) }
  }

  @Published var onboardingComplete: Bool {
    didSet { defaults.set(onboardingComplete, forKey: Keys.onboardingComplete) }
  }

  @Published var launchAtLogin: Bool {
    didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
  }

  private enum Keys {
    static let holdToTalkHotkey = "holdToTalkHotkey"
    static let pasteLastHotkey = "pasteLastHotkey"
    static let glossary = "glossary"
    static let onboardingComplete = "onboardingComplete"
    static let launchAtLogin = "launchAtLogin"
  }

  private let defaults: UserDefaults
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    holdToTalkHotkey =
      Self.decode(
        HotkeyConfiguration.self,
        key: Keys.holdToTalkHotkey,
        defaults: defaults
      ) ?? .holdToTalk
    pasteLastHotkey =
      Self.decode(
        HotkeyConfiguration.self,
        key: Keys.pasteLastHotkey,
        defaults: defaults
      ) ?? .pasteLast
    glossary =
      Self.decode(
        [GlossaryEntry].self,
        key: Keys.glossary,
        defaults: defaults
      ) ?? [.issen]
    onboardingComplete = defaults.bool(forKey: Keys.onboardingComplete)
    launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
  }

  private func save<T: Encodable>(_ value: T, key: String) {
    guard let data = try? encoder.encode(value) else {
      return
    }
    defaults.set(data, forKey: key)
  }

  private static func decode<T: Decodable>(
    _ type: T.Type,
    key: String,
    defaults: UserDefaults
  ) -> T? {
    guard let data = defaults.data(forKey: key) else {
      return nil
    }
    return try? JSONDecoder().decode(type, from: data)
  }
}
