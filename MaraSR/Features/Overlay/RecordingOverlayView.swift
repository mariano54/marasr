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
  static let barCount = 24

  @Published var phase: OverlayPhase = .hidden {
    didSet {
      onContentChange?()
    }
  }
  @Published var levels: [Float] = Array(
    repeating: 0.08,
    count: OverlayViewModel.barCount
  )
  @Published var transcript = "" {
    didSet {
      onContentChange?()
    }
  }

  var onContentChange: (() -> Void)?

  func push(level: Float) {
    levels.append(max(0.06, level))
    if levels.count > Self.barCount {
      levels.removeFirst(levels.count - Self.barCount)
    }
  }

  func reset() {
    levels = Array(repeating: 0.08, count: Self.barCount)
    transcript = ""
  }
}

struct RecordingOverlayView: View {
  @ObservedObject var model: OverlayViewModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      phaseIndicator
        .frame(width: 22, height: 26)

      NeonWaveform(levels: model.levels, phase: model.phase)

      Group {
        switch model.phase {
        case .recording:
          TranscriptLine(
            text: model.transcript.isEmpty
              ? "Listening…"
              : model.transcript,
            isPlaceholder: model.transcript.isEmpty
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
      .font(.system(size: 12, weight: .medium, design: .monospaced))
      .foregroundStyle(.white.opacity(0.92))
      .shadow(color: OverlayPalette.cyan.opacity(0.35), radius: 5)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 5)
    }
    .padding(.horizontal, 8)
    .padding(.top, 4)
    .padding(.bottom, 8)
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

  private var phaseIndicator: some View {
    ZStack {
      switch model.phase {
      case .recording:
        RecordingOrb(energy: loudness(of: model.levels.last ?? 0))
          .transition(.scale(scale: 0.2).combined(with: .opacity))
      case .transcribing:
        Image(systemName: "sparkles")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(
            LinearGradient(
              colors: [OverlayPalette.cyan, OverlayPalette.violet],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .symbolEffect(
            .variableColor.iterative.reversing,
            isActive: !reduceMotion
          )
          .transition(.scale(scale: 0.4).combined(with: .opacity))
      case .success:
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.green)
          .shadow(color: .green.opacity(0.7), radius: 4)
          .transition(.scale(scale: 0.4).combined(with: .opacity))
      case .failed:
        Image(systemName: "exclamationmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.orange)
          .shadow(color: .orange.opacity(0.7), radius: 4)
          .transition(.scale(scale: 0.4).combined(with: .opacity))
      case .hidden:
        EmptyView()
      }
    }
    .animation(
      reduceMotion ? nil : .bouncy(duration: 0.4, extraBounce: 0.25),
      value: model.phase
    )
  }
}

private enum OverlayPalette {
  static var cyan: Color { Color(red: 0.31, green: 0.93, blue: 1) }
  static var violet: Color { Color(red: 0.58, green: 0.45, blue: 1) }
  static var magenta: Color { Color(red: 1, green: 0.36, blue: 0.8) }

  static var orbHighlight: Color { Color(red: 1, green: 0.68, blue: 0.76) }
  static var orbCore: Color { Color(red: 1, green: 0.27, blue: 0.44) }
  static var orbRim: Color { Color(red: 0.76, green: 0.07, blue: 0.27) }
}

/// Maps a dB-normalized mic level to 0...1, treating room noise as silence.
private func loudness(of level: Float) -> Double {
  min(1, max(0, (Double(level) - 0.12) / 0.68))
}

/// A glossy jelly button that breathes, squishes with your voice, and sends
/// out soft ripples while recording.
private struct RecordingOrb: View {
  let energy: Double

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(
      .animation(minimumInterval: 1.0 / 60, paused: reduceMotion)
    ) { context in
      let time =
        reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
      ZStack {
        if !reduceMotion {
          ZStack {
            ripple(at: time, delay: 0)
            ripple(at: time, delay: 0.5)
          }
          .animation(.easeOut(duration: 0.25)) { content in
            content.opacity(0.4 + 0.6 * energy)
          }
        }
        halo
        jelly(at: time)
      }
    }
    .frame(width: 22, height: 26)
  }

  private func ripple(at time: TimeInterval, delay: Double) -> some View {
    let progress = (time / 1.6 + delay).truncatingRemainder(dividingBy: 1)
    return Circle()
      .stroke(OverlayPalette.orbCore.opacity(0.75), lineWidth: 1.2)
      .frame(width: 11, height: 11)
      .scaleEffect(1 + CGFloat(progress) * 1.1)
      .opacity((1 - progress) * 0.85)
  }

  private var halo: some View {
    Circle()
      .fill(
        RadialGradient(
          colors: [OverlayPalette.orbCore.opacity(0.55), .clear],
          center: .center,
          startRadius: 1,
          endRadius: 11
        )
      )
      .frame(width: 22, height: 22)
      .scaleEffect(0.7 + CGFloat(energy) * 0.5)
      .animation(.spring(response: 0.25, dampingFraction: 0.6), value: energy)
  }

  private func jelly(at time: TimeInterval) -> some View {
    let breath = 0.05 * sin(time * 2 * .pi / 1.5)
    let squish = 0.045 * sin(time * 2 * .pi * 1.1)
    return ZStack {
      Circle()
        .fill(
          RadialGradient(
            colors: [
              OverlayPalette.orbHighlight,
              OverlayPalette.orbCore,
              OverlayPalette.orbRim,
            ],
            center: UnitPoint(x: 0.35, y: 0.3),
            startRadius: 0,
            endRadius: 8
          )
        )
      Ellipse()
        .fill(.white.opacity(0.85))
        .frame(width: 3.6, height: 2.2)
        .rotationEffect(.degrees(-30))
        .offset(x: -1.8, y: -2.3)
    }
    .frame(width: 11, height: 11)
    .scaleEffect(
      x: CGFloat(1 + breath + squish),
      y: CGFloat(1 + breath - squish)
    )
    .animation(.spring(response: 0.22, dampingFraction: 0.45)) { content in
      content
        .shadow(
          color: OverlayPalette.orbCore.opacity(0.85),
          radius: 2.5 + CGFloat(energy) * 4
        )
        .scaleEffect(1 + CGFloat(energy) * 0.35)
    }
  }
}

/// Mirrored neon bars with a glow and a fading history trail. A scan beam
/// sweeps across while listening, and faster while finishing.
private struct NeonWaveform: View {
  let levels: [Float]
  let phase: OverlayPhase

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let barWidth: CGFloat = 2.5
  private let barSpacing: CGFloat = 2
  private let height: CGFloat = 26

  var body: some View {
    ZStack {
      ZStack {
        neonGradient
          .frame(height: 0.75)
          .opacity(0.3)
          .mask { trailFade }

        neonBars
          .blur(radius: 3)
          .opacity(0.9)

        neonBars
      }
      .opacity(phase == .recording ? 1 : 0.55)

      if let scanPeriod, !reduceMotion {
        scanBeam(period: scanPeriod)
      }
    }
    .frame(width: width, height: height)
    .animation(.easeOut(duration: 0.3), value: phase)
  }

  private var width: CGFloat {
    let count = CGFloat(levels.count)
    return count * barWidth + max(0, count - 1) * barSpacing
  }

  private var scanPeriod: Double? {
    switch phase {
    case .recording:
      2.6
    case .transcribing:
      0.9
    default:
      nil
    }
  }

  private var neonGradient: LinearGradient {
    LinearGradient(
      colors: [
        OverlayPalette.magenta,
        OverlayPalette.violet,
        OverlayPalette.cyan,
      ],
      startPoint: .leading,
      endPoint: .trailing
    )
  }

  private var trailFade: LinearGradient {
    LinearGradient(
      stops: [
        .init(color: .clear, location: 0),
        .init(color: .black, location: 0.35),
      ],
      startPoint: .leading,
      endPoint: .trailing
    )
  }

  private var neonBars: some View {
    neonGradient.mask { barShapes }
  }

  private var barShapes: some View {
    HStack(alignment: .center, spacing: barSpacing) {
      ForEach(Array(levels.enumerated()), id: \.offset) {
        _, level in
        Capsule()
          .frame(width: barWidth, height: barHeight(for: level))
          .animation(
            .spring(response: 0.18, dampingFraction: 0.7),
            value: level
          )
      }
    }
    .frame(width: width, height: height)
    .mask { trailFade }
  }

  private func barHeight(for level: Float) -> CGFloat {
    2.5 + CGFloat(loudness(of: level)) * 21.5
  }

  private func scanBeam(period: Double) -> some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
      let progress =
        context.date.timeIntervalSinceReferenceDate
        .truncatingRemainder(dividingBy: period) / period
      let beamWidth: CGFloat = 24
      LinearGradient(
        colors: [.clear, .white.opacity(0.85), .clear],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: beamWidth)
      .offset(x: (width + beamWidth) * CGFloat(progress) - beamWidth)
      .frame(width: width, alignment: .leading)
    }
    .mask { barShapes }
    .blendMode(.plusLighter)
  }
}

/// Transcript text with a blinking neon cursor, like a terminal prompt.
private struct TranscriptLine: View {
  let text: String
  let isPlaceholder: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.5)) { context in
      Text("\(transcript)\(cursor(at: context.date))")
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
  }

  private var transcript: Text {
    let line = Text(verbatim: text)
    guard isPlaceholder else {
      return line
    }
    return line.foregroundStyle(.white.opacity(0.5))
  }

  private func cursor(at date: Date) -> Text {
    let isVisible =
      reduceMotion
      || Int(date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2)
    return Text(verbatim: " ▍")
      .foregroundStyle(isVisible ? OverlayPalette.cyan : Color.clear)
  }
}
