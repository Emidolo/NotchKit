# Builds with Xcode or just the Command Line Tools.
ARCHS ?= $(shell uname -m)
CONFIG ?= release
APP = build/NotchKit.app
VERSION = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG = build/NotchKit-$(VERSION).dmg
# "-" signs ad hoc. For a release: make dmg SIGN="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=profile
SIGN ?= -
# A Developer ID signature needs the hardened runtime and a secure timestamp to be notarized.
SIGN_FLAGS = $(if $(filter -,$(SIGN)),--timestamp=none,--options runtime --timestamp --entitlements Resources/NotchKit.entitlements)
# One build per architecture, merged with lipo (multi-arch `swift build` needs Xcode's XCBuild).
BINS = $(foreach a,$(ARCHS),.build/$(a)-apple-macosx/$(CONFIG)/NotchKit)
# Swift Testing ships outside the default search path when only the CLT are installed.
CLT_FW = /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIB = /Library/Developer/CommandLineTools/Library/Developer/usr/lib
TEST_FLAGS = $(if $(wildcard $(CLT_FW)/Testing.framework),-Xswiftc -F$(CLT_FW) -Xlinker -rpath -Xlinker $(CLT_FW) -Xlinker -rpath -Xlinker $(CLT_LIB))

.PHONY: build test app run install dmg clean

build:
	for a in $(ARCHS); do swift build -c $(CONFIG) --arch $$a || exit 1; done

test:
	swift test $(TEST_FLAGS)

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	lipo -create $(BINS) -output $(APP)/Contents/MacOS/NotchKit
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Scripts/claude-hooks.py $(APP)/Contents/Resources/
	codesign --force --sign "$(SIGN)" $(SIGN_FLAGS) $(APP)

run: app
	-pkill -x NotchKit
	open $(APP)

# Replaces the copy in /Applications (the one Launch at Login starts) and opens it.
install: app
	-pkill -x NotchKit
	rm -rf /Applications/NotchKit.app
	cp -R $(APP) /Applications/NotchKit.app
	sleep 1
	open /Applications/NotchKit.app

# A universal build in a disk image with an Applications shortcut. Signed and notarized when SIGN and
# NOTARY_PROFILE (a `notarytool store-credentials` profile) are given.
dmg:
	$(MAKE) app ARCHS="arm64 x86_64"
	rm -rf build/dmg $(DMG)
	mkdir -p build/dmg
	cp -R $(APP) build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -quiet -volname NotchKit -srcfolder build/dmg -format UDZO -ov $(DMG)
	rm -rf build/dmg
ifneq ($(SIGN),-)
	codesign --force --sign "$(SIGN)" --timestamp $(DMG)
endif
ifdef NOTARY_PROFILE
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DMG)
endif
	@echo "Built $(DMG)"

clean:
	rm -rf .build build
