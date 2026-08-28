# MaraSR

Private, on-device dictation for Apple Silicon Macs. Hold Right Command, speak,
and MaraSR pastes the transcript into the frontmost app.

Audio, models, and history stay on this Mac. The app is sandboxed and ships
**without a network entitlement**, so macOS blocks outbound connections at the
kernel boundary. FluidAudio is also locked to offline mode at launch, so it
cannot fetch models even if a future dependency tries.

## What it does

- Hold **Right Command** to dictate; release to paste
- **Control–Option–V** pastes the last transcript again
- Live overlay while you speak, then a local history in the dashboard
- Optional glossary for names and terms you want spelled a certain way

The recognizer is NVIDIA Parakeet TDT 0.6B v3 through FluidAudio / Core ML.
Voice activity uses Silero. Both run locally on the Neural Engine.

## Privacy

MaraSR does not open sockets, call APIs, or upload audio. There is no account,
analytics, crash reporter, or cloud sync.

The sandbox entitlements are only:

- App Sandbox
- Microphone (while the hotkey is held)

There is no `com.apple.security.network.client` or server entitlement.

Models are loaded from the local FluidAudio cache:

`~/Library/Application Support/FluidAudio/`

If those files are missing, the app fails locally. It will not download them.

## Requirements

- Apple Silicon Mac
- macOS 15 or newer
- Xcode 26 or newer
- Local Parakeet v3 and Silero Core ML caches already on disk

## Run

1. Open `MaraSR.xcodeproj`.
2. Select the `MaraSR` scheme and your Mac.
3. Set a development team on the app target.
4. Run and finish onboarding (permissions + a hotkey try-out).

Grant Microphone, Input Monitoring, and Accessibility. The menu-bar waveform
stays available after you close the dashboard.

## Tests

```sh
xcodebuild \
  -project MaraSR.xcodeproj \
  -scheme MaraSR \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGNING_ALLOWED=NO \
  test
```
