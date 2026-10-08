# VoiceShim

Local voice for [superterm](https://superterm.dev) on a Mac: dictation in, and
replies spoken back. Everything runs on your Mac.

* **On-device speech-to-text.** NVIDIA Parakeet TDT 0.6B v3 runs on the
  Apple Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio).
  Audio never leaves your Mac.
* **Text to speech on-device.** Kokoro (af_heart) also runs on the Neural
  Engine and speaks superterm's chat replies and screen readbacks: about
  0.15 to 0.3s a sentence once warm, on an M2.
* **A speechd for macOS.** `voice-shim --speechd` serves the same REST API as
  superterm's Linux speech daemon, so superterm on a Mac uses it unchanged:
  `/health`, `/v1/transcribe`, `/v1/preview`, and `/tts`, with bearer auth.
* **A menu-bar dictation app.** Click the icon or hold Option+Space, speak,
  and watch live previews in a floating panel. The text goes into the
  superterm session you're looking at, or the frontmost app if you prefer.
* **Optional polish.** It can route the transcript through any
  OpenAI-compatible endpoint for punctuation and cleanup. It fails open: if
  the endpoint is down, you get the raw transcript.

Needs Apple Silicon and macOS 14 or later. The models (about 1GB) download
to `~/Library/Application Support/FluidAudio` on first start.

## Set up with superterm (one command)

```sh
superterm speechd init
```

On a Mac this downloads the latest VoiceShim release, checks its sha256,
installs `~/Applications/VoiceShim.app`, starts it at login as a
LaunchAgent with a bearer token, waits while the models download, and adds
the `speech:` block to `~/.superterm/config.yaml`. Restart superterm and
you're done.

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

## Run it yourself

```sh
~/Applications/VoiceShim.app/Contents/MacOS/VoiceShim --install    # LaunchAgent + token
~/Applications/VoiceShim.app/Contents/MacOS/VoiceShim --uninstall  # remove the agent
```

Or in the foreground, with `--voice` to pick another Kokoro voice and
`--no-tts` to listen only:

```sh
VoiceShim --speechd --listen 127.0.0.1:8765 --token-file ~/.superterm/speechd-token
```

superterm reaches it with:

```yaml
speech:
  endpoint: http://127.0.0.1:8765
  readback_endpoint: http://127.0.0.1:8765
  token_file: ~/.superterm/speechd-token
```

## Releases

`arkade rel` cuts a release. The tag builds on GitHub's macOS runners and
uploads `VoiceShim-darwin-arm64.tar.gz` and the bare `voice-shim-darwin-arm64`
binary, each with a `.sha256`.

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
