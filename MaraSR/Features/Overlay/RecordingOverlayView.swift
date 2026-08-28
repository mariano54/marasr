import SwiftUI

enum OverlayPhase: Equatable {
  case hidden
  case recording
  case transcribing
  case success
  case failed(String)
}

@MainActor
final class OverlayViewModel: ObservableObject {
  @Published var phase: OverlayPhase = .hidden {
    didSet {
      onContentChange?()
    }
  }
  @Published var levels: [Float] = Array(repeating: 0.08, count: 18)
  @Published var transcript = "" {
    didSet {
      onContentChange?()
    }
  }

  var onContentChange: (() -> Void)?

  func push(level: Float) {
    levels.append(max(0.06, level))
    if levels.count > 18 {
      levels.removeFirst(levels.count - 18)
    }
  }

  func reset() {
    levels = Array(repeating: 0.08, count: 18)
    transcript = ""
  }
}

struct RecordingOverlayView: View {
  @ObservedObject var model: OverlayViewModel

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      phaseIndicator
        .frame(width: 16, height: 26)

      waveform
        .frame(width: 100, height: 26)

      Group {
        switch model.phase {
        case .recording:
          Text(
            model.transcript.isEmpty
              ? "Listening…"
              : model.transcript
          )
        case .transcribing:
          Label("Finishing…", systemImage: "sparkles")
        case .success:
          Label("Pasted", systemImage: "checkmark")
        case .failed(let message):
          Label(message, systemImage: "exclamationmark.triangle")
        case .hidden:
          EmptyView()
        }
      }
      .font(.system(size: 12, weight: .medium, design: .rounded))
      .foregroundStyle(.white.opacity(0.92))
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 5)
    }
    .padding(.horizontal, 8)
    .padding(.top, 4)
    .padding(.bottom, 5)
    .frame(width: 640, alignment: .topLeading)
    .frame(minHeight: 36, alignment: .topLeading)
    .background(
      .black.opacity(0.82),
      in: panelShape
    )
    .overlay {
      panelShape
        .stroke(.white.opacity(0.09), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
  }

  private var panelShape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(
      bottomLeadingRadius: 12,
      bottomTrailingRadius: 12,
      style: .continuous
    )
  }

  @ViewBuilder
  private var phaseIndicator: some View {
    switch model.phase {
    case .recording:
      RecordingPulseIndicator()
    case .transcribing:
      Image(systemName: "sparkles")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.72))
    case .success:
      Image(systemName: "checkmark")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.green)
    case .failed:
      Image(systemName: "exclamationmark")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.orange)
    case .hidden:
      EmptyView()
    }
  }

  private var waveform: some View {
    HStack(alignment: .center, spacing: 3) {
      ForEach(Array(model.levels.enumerated()), id: \.offset) {
        _, level in
        Capsule()
          .fill(.white.opacity(0.88))
          .frame(
            width: 2.5,
            height: max(3, CGFloat(level) * 24)
          )
          .animation(
            .easeOut(duration: 0.1),
            value: level
          )
      }
    }
  }
}

private struct RecordingPulseIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isPulsing = false

  var body: some View {
    ZStack {
      Circle()
        .stroke(.red.opacity(0.5), lineWidth: 1.5)
        .frame(width: 12, height: 12)
        .scaleEffect(isPulsing ? 1.5 : 0.72)
        .opacity(isPulsing ? 0 : 0.85)

      Circle()
        .fill(.red)
        .frame(width: 7, height: 7)
        .shadow(color: .red.opacity(0.75), radius: 4)
    }
    .frame(width: 16, height: 26)
    .animation(
      reduceMotion
        ? nil
        : .easeOut(duration: 0.9)
          .repeatForever(autoreverses: false),
      value: isPulsing
    )
    .onAppear {
      isPulsing = !reduceMotion
    }
  }
}
