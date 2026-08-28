import SwiftUI

struct SettingsView: View {
  @ObservedObject var appState: AppState
  @ObservedObject var settings: SettingsStore
  @ObservedObject var permissions: PermissionManager

  @State private var captureTarget: CaptureTarget?
  @State private var hotkeyError: String?

  private enum CaptureTarget {
    case holdToTalk
    case pasteLast
  }

  var body: some View {
    Form {
      Section("Hotkeys") {
        hotkeyRow(
          title: "Hold to talk",
          detail: "Recording starts on press and finishes on release.",
          configuration: settings.holdToTalkHotkey,
          target: .holdToTalk
        )
        hotkeyRow(
          title: "Paste last transcription",
          detail: "Repeats the most recent result without recording.",
          configuration: settings.pasteLastHotkey,
          target: .pasteLast
        )
        if let hotkeyError {
          Text(hotkeyError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      Section("Permissions") {
        permissionStatus(
          "Microphone",
          granted: permissions.microphoneGranted
        ) {
          Task {
            await permissions.requestMicrophone()
          }
        }
        permissionStatus(
          "Input Monitoring",
          granted: permissions.inputMonitoringGranted
        ) {
          permissions.requestInputMonitoring()
        }
        permissionStatus(
          "Accessibility",
          granted: permissions.accessibilityGranted
        ) {
          permissions.requestAccessibility()
        }
        Button("Recheck") {
          appState.refreshPermissions()
        }
      }

      Section("Keywords") {
        Text(
          "MaraSR applies these exact terms after transcription. Add comma-separated aliases for common mishearings."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        ForEach($settings.glossary) { $entry in
          HStack(alignment: .firstTextBaseline) {
            TextField("Canonical term", text: $entry.canonical)
              .frame(width: 150)
            TextField(
              "Aliases",
              text: aliasesBinding(for: $entry)
            )
            Button(role: .destructive) {
              settings.glossary.removeAll {
                $0.id == entry.id
              }
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
          }
        }

        Button {
          settings.glossary.append(
            GlossaryEntry(canonical: "", aliases: [])
          )
        } label: {
          Label("Add keyword", systemImage: "plus")
        }
      }

      Section("General") {
        Toggle(
          "Launch MaraSR at login",
          isOn: Binding(
            get: { settings.launchAtLogin },
            set: { appState.setLaunchAtLogin($0) }
          )
        )

        LabeledContent("Parakeet v3") {
          HStack(spacing: 6) {
            Circle()
              .fill(appState.modelReady ? .green : .orange)
              .frame(width: 7, height: 7)
            Text(appState.modelReady ? "Ready" : "Preparing")
          }
        }
      }
    }
    .formStyle(.grouped)
    .padding(12)
    .onDisappear {
      appState.cancelHotkeyCapture()
      captureTarget = nil
    }
  }

  private func hotkeyRow(
    title: String,
    detail: String,
    configuration: HotkeyConfiguration,
    target: CaptureTarget
  ) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button(
        captureTarget == target
          ? "Press shortcut…"
          : configuration.displayName
      ) {
        captureTarget = target
        hotkeyError = nil
        appState.beginHotkeyCapture { captured in
          apply(captured, to: target)
        }
      }
      .buttonStyle(.bordered)
    }
  }

  private func apply(
    _ configuration: HotkeyConfiguration,
    to target: CaptureTarget
  ) {
    defer { captureTarget = nil }
    switch target {
    case .holdToTalk:
      guard configuration != settings.pasteLastHotkey else {
        hotkeyError = "The two actions cannot use the same shortcut."
        return
      }
      settings.holdToTalkHotkey = configuration
    case .pasteLast:
      guard configuration != settings.holdToTalkHotkey else {
        hotkeyError = "The two actions cannot use the same shortcut."
        return
      }
      settings.pasteLastHotkey = configuration
    }
  }

  private func permissionStatus(
    _ title: String,
    granted: Bool,
    request: @escaping () -> Void
  ) -> some View {
    LabeledContent(title) {
      Button(granted ? "Granted" : "Allow", action: request)
        .disabled(granted)
    }
  }

  private func aliasesBinding(
    for entry: Binding<GlossaryEntry>
  ) -> Binding<String> {
    Binding(
      get: {
        entry.wrappedValue.aliases.joined(separator: ", ")
      },
      set: { value in
        entry.wrappedValue.aliases =
          value
          .split(separator: ",")
          .map {
            $0.trimmingCharacters(
              in: .whitespacesAndNewlines
            )
          }
          .filter { !$0.isEmpty }
      }
    )
  }
}
