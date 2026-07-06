APP := build/kiki.app
BIN := .build/release/Kiki
SIGN_ID ?= -

.PHONY: build test bundle run clean

build:
	swift build -c release

test:
	swift test

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp App/Info.plist $(APP)/Contents/Info.plist
	cp App/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp $(BIN) $(APP)/Contents/MacOS/Kiki
	# Bundles de recursos de dependencias SPM (si existen)
	-cp -R .build/release/*.bundle $(APP)/Contents/Resources/ 2>/dev/null
	codesign --force --sign "$(SIGN_ID)" $(APP)
	@echo "OK → $(APP)"

run: bundle
	open $(APP)

clean:
	rm -rf .build build
