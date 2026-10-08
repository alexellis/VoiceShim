APP := VoiceShim
BUNDLE_ID := com.openfaas.VoiceShim
BIN := voice-shim
DIST := dist/$(APP).app
# A release passes its tag; local builds are "dev".
VERSION ?= dev
# Override with a real identity to keep TCC grants across updates,
# e.g. make bundle SIGN_ID="Apple Development: you@example.com (TEAMID)"
SIGN_ID := -

.PHONY: build bundle run release clean

build:
	@if ! grep -q '"$(VERSION)"' Sources/VoiceShim/Version.swift; then \
		printf '// Stamped by `make VERSION=...`; a release build carries its tag.\nlet voiceShimVersion = "%s"\n' "$(VERSION)" > Sources/VoiceShim/Version.swift; fi
	swift build -c release

bundle: build
	rm -rf $(DIST)
	mkdir -p $(DIST)/Contents/MacOS
	cp .build/release/$(BIN) $(DIST)/Contents/MacOS/$(APP)
	sed -e 's/@APP@/$(APP)/g' -e 's/@BUNDLE_ID@/$(BUNDLE_ID)/g' -e 's/@VERSION@/$(VERSION)/g' \
		Info.plist.in > $(DIST)/Contents/Info.plist
	codesign --force --sign "$(SIGN_ID)" $(DIST)

# Release assets in bin/, as arkade publishes them: the bare binary and
# its .sha256. speechd needs nothing else; the app bundle only matters for
# the menu-bar app's microphone prompt, and `make bundle` builds it.
release: build
	rm -rf bin && mkdir -p bin
	cp .build/release/$(BIN) bin/$(BIN)-darwin-arm64
	cd bin && shasum -a 256 $(BIN)-darwin-arm64 > $(BIN)-darwin-arm64.sha256

run: bundle
	open $(DIST)

clean:
	rm -rf .build dist bin
