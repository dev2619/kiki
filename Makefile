APP := build/kiki.app
XCODE_DERIVED := .build/xcode
XCODE_PRODUCTS := $(XCODE_DERIVED)/Build/Products/Release
BIN := $(XCODE_PRODUCTS)/Kiki
# Identidad local estable (cert self-signed "kiki-dev" en el login keychain).
# Mantiene la misma firma entre rebuilds → los permisos TCC (Accesibilidad) y
# el cache de compilación ANE/CoreML sobreviven. Fallback ad-hoc: make SIGN_ID=-
SIGN_ID ?= kiki-dev

.PHONY: build test bundle run clean dmg

# El target Cmlx de mlx-swift compila shaders .metal a un default.metallib vía
# el sistema de build de Xcode; el CLI de SwiftPM (`swift build`) no tiene esa
# integración, así que el binario de la app SIEMPRE se construye con
# xcodebuild (ver MARK en Sources/KikiRefine/LLMRefiner.swift). El scheme
# "kiki" es el auto-generado por SwiftPM/Xcode para el package completo
# (verificado con `xcodebuild -list`).
build:
	xcodebuild -scheme kiki -destination 'platform=macOS' -configuration Release \
		-derivedDataPath $(XCODE_DERIVED) build

test:
	swift test

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp App/Info.plist $(APP)/Contents/Info.plist
	cp App/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp App/MenuBarIcon.png App/MenuBarIcon@2x.png App/MenuBarIconActive.png App/MenuBarIconActive@2x.png $(APP)/Contents/Resources/
	cp $(BIN) $(APP)/Contents/MacOS/Kiki
	# Bundles de recursos de dependencias SPM — incluye
	# mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib (shaders Metal
	# de MLX, requeridos en runtime para GPU) y swift-transformers_Hub.bundle.
	-cp -R $(XCODE_PRODUCTS)/*.bundle $(APP)/Contents/Resources/ 2>/dev/null
	codesign --force --sign "$(SIGN_ID)" $(APP)
	@if [ -z "$$(find $(APP) -name '*.metallib' -print -quit)" ]; then \
		echo "ERROR: no se encontró ningún .metallib en $(APP) — MLX no podrá inicializar Metal en runtime." >&2; \
		exit 1; \
	fi
	@echo "OK → $(APP)"

run: bundle
	open $(APP)

# Empaquetado .dmg sin notarizar (Fase 4 — pendiente Apple Developer Program
# para notarización). Gatekeeper bloqueará el primer lanzamiento en Macs
# ajenos a este equipo; el usuario debe clic derecho → Abrir.
dmg: bundle
	rm -f build/kiki-*.dmg
	mkdir -p build/dmg-root
	cp -R $(APP) build/dmg-root/
	ln -sf /Applications build/dmg-root/Applications
	hdiutil create -volname "kiki" -srcfolder build/dmg-root -ov -format UDZO build/kiki-$$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' App/Info.plist).dmg
	rm -rf build/dmg-root
	@echo "DMG listo (sin notarizar — Gatekeeper pedirá clic derecho→Abrir en otros Macs)"

clean:
	rm -rf .build build
