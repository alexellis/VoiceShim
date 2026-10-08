APP := VoiceShim
BUNDLE_ID := com.openfaas.VoiceShim
BIN := voice-shim
DIST := dist/$(APP).app
# Override with a real identity to keep TCC grants across updates,
# e.g. make bundle SIGN_ID="Apple Development: you@example.com (TEAMID)"
SIGN_ID := -

.PHONY: build bundle run clean

build:
	swift build -c release

bundle: build
	rm -rf $(DIST)
	mkdir -p $(DIST)/Contents/MacOS
	cp .build/release/$(BIN) $(DIST)/Contents/MacOS/$(APP)
	sed -e 's/@APP@/$(APP)/g' -e 's/@BUNDLE_ID@/$(BUNDLE_ID)/g' \
		Info.plist.in > $(DIST)/Contents/Info.plist
	codesign --force --sign "$(SIGN_ID)" $(DIST)

run: bundle
	open $(DIST)

clean:
	rm -rf .build dist
