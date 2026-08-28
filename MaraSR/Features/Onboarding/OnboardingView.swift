import SwiftUI

struct OnboardingView: View {
  @ObservedObject var appState: AppState
  @ObservedObject var permissions: PermissionManager

  @State private var step = 0
  @State private var tutorialCompleted = false

  private let stepNames = ["Welcome", "Model", "Permissions", "Try it"]

  var body: some View {
    ZStack {
      Color(red: 0.095, green: 0.102, blue: 0.125)
        .ignoresSafeArea()

      VStack(spacing: 0) {
        progressHeader
          .padding(.top, 30)

        Group {
          switch step {
          case 0:
            welcomeStep
          case 1:
            modelStep
          case 2:
            permissionsStep
          default:
            tutorialStep
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 70)

        controls
          .padding(.horizontal, 40)
          .padding(.bottom, 30)
      }
    }
    .frame(minWidth: 720, minHeight: 580)
    .preferredColorScheme(.dark)
    .onChange(of: appState.tutorialHotkeyDown) { _, isDown in
      if step == 3, isDown {
        tutorialCompleted = true
      }
    }
    .onChange(of: step) { oldValue, newValue in
      if oldValue == 3 {
        appState.setTutorialMode(false)
      }
      if newValue == 3 {
        appState.setTutorialMode(true)
      }
    }
    .onDisappear {
      appState.setTutorialMode(false)
    }
  }

  private var progressHeader: some View {
    HStack(spacing: 10) {
      ForEach(stepNames.indices, id: \.self) { index in
        HStack(spacing: 7) {
          Circle()
            .fill(index <= step ? Color.accentColor : .white.opacity(0.15))
            .frame(width: 7, height: 7)
          Text(stepNames[index])
            .font(.caption.weight(index == step ? .semibold : .regular))
            .foregroundStyle(
              index == step ? .white : .white.opacity(0.42)
            )
        }
        if index < stepNames.count - 1 {
          Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 34, height: 1)
        }
      }
    }
  }

  private var welcomeStep: some View {
    VStack(spacing: 20) {
      Spacer()
      Image(systemName: "waveform.badge.mic")
        .font(.system(size: 48, weight: .medium))
        .foregroundStyle(Color.accentColor)
        .padding(22)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24))

      Text("Speak anywhere.")
        .font(.system(size: 38, weight: .bold, design: .rounded))
      Text(
        "Hold Right Command, speak naturally, and MaraSR pastes a private transcription. Audio and text never leave this Mac."
      )
      .font(.title3)
      .foregroundStyle(.white.opacity(0.58))
      .multilineTextAlignment(.center)
      .frame(maxWidth: 560)

      HStack(spacing: 18) {
        feature("lock.fill", "Offline only")
        feature("bolt.fill", "Fast pauses")
        feature("keyboard.fill", "Works everywhere")
      }
      .padding(.top, 12)
      Spacer()
    }
  }

  private var modelStep: some View {
    VStack(spacing: 18) {
      Spacer()
      Image(systemName: "cpu")
        .font(.system(size: 44))
        .foregroundStyle(Color.accentColor)

      Text("Prepare Parakeet v3")
        .font(.system(size: 30, weight: .bold, design: .rounded))
      Text(
        "MaraSR loads Parakeet v3 and Silero from the local Core ML cache. It has no network entitlement and will not download models."
      )
      .foregroundStyle(.white.opacity(0.58))
      .multilineTextAlignment(.center)
      .frame(maxWidth: 520)

      VStack(spacing: 9) {
        ProgressView(value: appState.modelProgress)
          .progressViewStyle(.linear)
          .tint(Color.accentColor)
        HStack {
          Text(modelStatus)
          Spacer()
          Text("\(Int(appState.modelProgress * 100))%")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white.opacity(0.48))
      }
      .padding(20)
      .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
      .frame(maxWidth: 500)
      .task {
        appState.prepareModels()
      }

      if let error = appState.errorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red.opacity(0.9))
          .multilineTextAlignment(.center)
      }
      Spacer()
    }
  }

  private var permissionsStep: some View {
    VStack(spacing: 18) {
      Spacer()
      Text("Allow required permissions")
        .font(.system(size: 30, weight: .bold, design: .rounded))
      Text(
        "MaraSR needs microphone access for recording, Input Monitoring for the hotkey, and Accessibility to paste."
      )
      .foregroundStyle(.white.opacity(0.58))
      .multilineTextAlignment(.center)
      .frame(maxWidth: 560)

      permissionRow(
        icon: "mic.fill",
        title: "Microphone",
        detail: "Capture your voice only while the hotkey is held.",
        granted: permissions.microphoneGranted
      ) {
        Task {
          await permissions.requestMicrophone()
        }
      }

      permissionRow(
        icon: "keyboard",
        title: "Input Monitoring",
        detail: "Listen for the hold-to-talk hotkey.",
        granted: permissions.inputMonitoringGranted
      ) {
        permissions.requestInputMonitoring()
      }

      permissionRow(
        icon: "accessibility",
        title: "Accessibility",
        detail: "Paste transcribed text into the active app.",
        granted: permissions.accessibilityGranted
      ) {
        permissions.requestAccessibility()
      }

      Button("Recheck permissions") {
        appState.refreshPermissions()
      }
      .buttonStyle(.plain)
      .foregroundStyle(Color.accentColor)
      Spacer()
    }
  }

  private var tutorialStep: some View {
    VStack(spacing: 22) {
      Spacer()
      Text("Try your hotkey")
        .font(.system(size: 30, weight: .bold, design: .rounded))
      Text("Press and release Right Command once.")
        .foregroundStyle(.white.opacity(0.58))

      ZStack {
        Circle()
          .stroke(.white.opacity(0.11), lineWidth: 6)
        Circle()
          .trim(
            from: 0,
            to: appState.tutorialHotkeyDown ? 1 : 0.08
          )
          .stroke(
            Color.accentColor,
            style: StrokeStyle(
              lineWidth: 6,
              lineCap: .round
            )
          )
          .rotationEffect(.degrees(-90))
          .animation(
            .easeOut(duration: 0.18),
            value: appState.tutorialHotkeyDown
          )
        Image(
          systemName: tutorialCompleted
            ? "checkmark"
            : "command"
        )
        .font(.system(size: 38, weight: .semibold))
        .foregroundStyle(
          tutorialCompleted ? Color.accentColor : .white
        )
      }
      .frame(width: 116, height: 116)

      Text(
        tutorialCompleted
          ? "Perfect. Hold it while speaking, then release to paste."
          : "MaraSR detects the right-side Command key without taking focus."
      )
      .font(.callout)
      .foregroundStyle(.white.opacity(0.58))
      Spacer()
    }
  }

  private var controls: some View {
    HStack {
      Button("Back") {
        step = max(0, step - 1)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.white.opacity(0.65))
      .disabled(step == 0)

      Spacer()

      Button(step == 3 ? "Start using MaraSR" : "Continue") {
        if step == 3 {
          appState.finishOnboarding()
        } else {
          step += 1
        }
      }
      .buttonStyle(PrimaryButtonStyle())
      .disabled(
        (step == 1 && !appState.modelReady)
          || (step == 2 && !permissions.allRequiredGranted)
      )
    }
  }

  private var modelStatus: String {
    if appState.modelReady {
      return "Ready"
    }
    if !appState.modelFile.isEmpty {
      return appState.modelFile
    }
    return "Preparing models…"
  }

  private func feature(
    _ icon: String,
    _ title: String
  ) -> some View {
    Label(title, systemImage: icon)
      .font(.caption.weight(.medium))
      .foregroundStyle(.white.opacity(0.68))
      .padding(.horizontal, 13)
      .padding(.vertical, 9)
      .background(.white.opacity(0.055), in: Capsule())
  }

  private func permissionRow(
    icon: String,
    title: String,
    detail: String,
    granted: Bool,
    action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 14) {
      Image(systemName: granted ? "checkmark" : icon)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(granted ? Color.accentColor : .white)
        .frame(width: 34, height: 34)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.white.opacity(0.48))
      }
      Spacer()
      Button(granted ? "Granted" : "Allow", action: action)
        .buttonStyle(.bordered)
        .disabled(granted)
    }
    .padding(15)
    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    .frame(maxWidth: 560)
  }
}

private struct PrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .foregroundStyle(.white)
      .padding(.horizontal, 24)
      .padding(.vertical, 11)
      .background(
        Color.accentColor.opacity(configuration.isPressed ? 0.72 : 1),
        in: RoundedRectangle(cornerRadius: 11)
      )
  }
}
