APP := build/kiki.app
BIN := .build/release/Kiki
# Identidad local estable (cert self-signed "kiki-dev" en el login keychain).
# Mantiene la misma firma entre rebuilds → los permisos TCC (Accesibilidad) y
# el cache de compilación ANE/CoreML sobreviven. Fallback ad-hoc: make SIGN_ID=-
SIGN_ID ?= kiki-dev

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
