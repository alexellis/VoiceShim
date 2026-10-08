# VoiceShim

Local voice for [superterm](https://superterm.dev) on a Mac: dictation in,
and (next) replies spoken back. Everything runs on your Mac.

* **On-device speech-to-text.** NVIDIA Parakeet TDT 0.6B v3 runs on the
  Apple Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio).
  Audio never leaves your Mac.
* **A speechd for macOS.** `voice-shim --speechd` serves the same REST API as
  superterm's Linux speech daemon, so superterm on a Mac dictates through it
  unchanged: `/health`, `/v1/transcribe`, and `/v1/preview`, with bearer
  auth.
* **A menu-bar dictation app.** Click the icon or hold Option+Space, speak,
  and watch live previews in a floating panel. The text goes into the
  superterm session you're looking at, or the frontmost app if you prefer.
* **Optional polish.** It can route the transcript through any
  OpenAI-compatible endpoint for punctuation and cleanup. It fails open: if
  the endpoint is down, you get the raw transcript.
* **Speaking back (planned).** Read replies aloud through a local TTS server
  such as Kokoro or Chatterbox.

Needs Apple Silicon and macOS 14 or later. The ASR model (~500MB) downloads
to `~/Library/Application Support/FluidAudio` on first use.

## Build

```sh
make bundle   # builds dist/VoiceShim.app (ad-hoc signed)
make run      # build and launch
```

Only the Xcode Command Line Tools are needed. CI builds the app on GitHub's
macOS runners for every push and pull request.

Ad-hoc signing changes on every build, so macOS forgets the microphone
grant each time. Sign with your own identity to keep it:

```sh
make bundle SIGN_ID="Apple Development: you@example.com (TEAMID)"
```

## Run as superterm's speech daemon

```sh
dist/VoiceShim.app/Contents/MacOS/VoiceShim --speechd \
  --listen 127.0.0.1:8765 --token-file ~/.superterm/speechd-token
```

Then point superterm at it in `~/.superterm/config.yaml`:

```yaml
speech:
  endpoint: http://127.0.0.1:8765
  token_file: ~/.superterm/speechd-token
```

## Configure the menu-bar app

Every setting is optional. They live in `~/.config/voice-shim/config.json`:

```json
{
  "mode": "superterm",
  "keyCode": 49,
  "modifiers": ["option"],

  "serverURL": "https://superterm.example.com",
  "token": "<a superterm API token>",
  "session": "my-session",

  "polish": false,
  "polishEndpoint": "http://gpu-box:8087",
  "polishModel": "local-speech-polish"
}
```

Modes:

* `superterm` (default): sends the text into a superterm session through
  its HTTP API. With no `session` set, it picks the session you last viewed.
  With no `serverURL`, it finds a local superterm by itself.
* `paste`: copies the text and presses Cmd+V in the frontmost app. macOS
  asks once for Accessibility permission.
* `clipboard`: copies the text and nothing else.

## From a terminal

The same binary, built with `swift build -c release`:

```sh
.build/release/voice-shim --transcribe recording.wav   # transcribe a file
.build/release/voice-shim --send "deploy it"           # send text to superterm
```

## Licence

MIT © OpenFaaS Ltd
