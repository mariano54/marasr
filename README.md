# MaraSR

On-device dictation for Apple Silicon Macs. Hold Right Command, speak, and
MaraSR pastes the transcript into the frontmost app.

Audio, models, and history stay on this Mac. The app is sandboxed and ships
**without a network entitlement**, so macOS blocks outbound connections at the
kernel boundary. FluidAudio is also locked to offline mode at launch, so it
cannot fetch models even if a future dependency tries.

## What it does

- Hold **Right Command** to dictate; release to paste
- **Control–Option–V** pastes the last transcript again
- Live overlay while you speak, then a local history in the dashboard
- Optional glossary for names and terms you want spelled a certain way

The recognizer is Parakeet Ultra, Moondream's post-trained NVIDIA Parakeet TDT
0.6B v3 (CC-BY-4.0), through FluidAudio / Core ML. Voice activity uses Silero.
Both run locally on the Neural Engine.

## Privacy

MaraSR does not open sockets, call APIs, or upload audio. There is no account,
analytics, crash reporter, or cloud sync.

The sandbox entitlements are only:

- App Sandbox
- Microphone (while the hotkey is held)

There is no `com.apple.security.network.client` or server entitlement.

Models are loaded from the local FluidAudio cache inside the app's sandbox
container:

`~/Library/Containers/com.mariano.marasr/Data/Library/Application Support/FluidAudio/Models/`

It needs two folders there. FluidAudio drops the `-coreml` suffix from the
Hugging Face repo name:

- `parakeet-ultra` (from `FluidInference/parakeet-ultra-coreml`)
- `silero-vad` (from `FluidInference/silero-vad-coreml`)

If those files are missing, the app fails locally. It will not download them.

## Requirements

- Apple Silicon Mac
- macOS 15 or newer
- Xcode 26 or newer
- Local Parakeet Ultra and Silero Core ML caches already on disk

## Run

1. Open `MaraSR.xcodeproj`.
2. Select the `MaraSR` scheme and your Mac.
3. Set a development team on the app target.
4. Run and finish onboarding (permissions + a hotkey try-out).

Grant Microphone, Input Monitoring, and Accessibility. The menu-bar waveform
stays available after you close the dashboard.

## Diagnostics

MaraSR logs app lifecycle, audio device changes, and dictation errors to the
local unified log under the subsystem `com.mariano.marasr`. Transcript text is
never logged. After a crash or failed dictation:

```sh
/usr/bin/log show --last 1h --info --predicate 'subsystem == "com.mariano.marasr"'
```

Crash reports land in `~/Library/Logs/DiagnosticReports/MaraSR-*.ips`.

## Tests

```sh
xcodebuild \
  -project MaraSR.xcodeproj \
  -scheme MaraSR \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## License

MaraSR is MIT-licensed. FluidAudio is Apache 2.0 and pulled in via Swift
Package Manager. This repository does not include model weights.
