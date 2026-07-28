APP := .build/PRMaster.app
BIN := .build/release/PRMaster
DIST := dist
INSTALL_DIR := /Applications
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

# Deliberately not versioned. The in-app updater looks the release asset up by
# exact name, and the README's installer relies on
# releases/latest/download/PRMaster.app.zip being a stable URL. Putting the
# version in the filename would break both on every release.
ZIP := PRMaster.app.zip

# Ad-hoc by default. Override with a Developer ID once one exists:
#   make dist SIGN_ID="Developer ID Application: Your Name (TEAMID)"
# Ad-hoc signing is enough to run locally, but Gatekeeper will refuse the app
# on any other Mac — see `make dist`.
SIGN_ID ?= -

# Swift Testing ships with the Command Line Tools but is not on SPM's search
# path there, and Testing.framework loads lib_TestingInterop.dylib from a
# *different* directory. Both must be wired up or `swift test` fails: first at
# `no such module 'Testing'`, then at dlopen. Harmless no-ops under full Xcode.
DEVDIR := $(shell xcode-select -p)
FW     := $(DEVDIR)/Library/Developer/Frameworks
INTEROP := $(DEVDIR)/Library/Developer/usr/lib
TESTFLAGS := -Xswiftc -F -Xswiftc $(FW) \
             -Xlinker -F -Xlinker $(FW) \
             -Xlinker -rpath -Xlinker $(FW) \
             -Xlinker -rpath -Xlinker $(INTEROP)

.PHONY: build test bundle run install uninstall dist verify-version clean

build:
	swift build -c release

# Pass extra args through: make test ARGS="--filter ReadinessTests"
test:
	swift test $(TESTFLAGS) $(ARGS)

# UNUserNotificationCenter refuses to work without a bundle identifier and a
# code signature, so a bare `swift build` binary is not runnable as an app.
bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/PRMaster
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign -s "$(SIGN_ID)" --force --options runtime --timestamp=none $(APP)
	@codesign --verify --strict $(APP) && echo "signed: $(SIGN_ID)"

run: bundle
	open $(APP)

# Install for real use. Worth doing beyond convenience: macOS treats an app
# living in /Applications more like a real app than one run out of .build,
# which is the leading suspect for notification authorization being refused.
install: bundle
	rm -rf "$(INSTALL_DIR)/PRMaster.app"
	ditto $(APP) "$(INSTALL_DIR)/PRMaster.app"
	@echo "Installed $(INSTALL_DIR)/PRMaster.app ($(VERSION))"
	@echo "Launch it from Spotlight, then grant notifications in System Settings."

uninstall:
	rm -rf "$(INSTALL_DIR)/PRMaster.app"
	@echo "Removed $(INSTALL_DIR)/PRMaster.app"

# Zip for sharing. ditto is used rather than `zip` because it preserves the
# bundle's symlinks and signature.
dist: bundle
	mkdir -p $(DIST)
	rm -f "$(DIST)/$(ZIP)"
	ditto -c -k --keepParent $(APP) "$(DIST)/$(ZIP)"
	@echo
	@echo "Wrote $(DIST)/$(ZIP) ($(VERSION))"
	@if [ "$(SIGN_ID)" = "-" ]; then \
	  echo; \
	  echo "WARNING: ad-hoc signed, NOT notarized."; \
	  echo "This runs on this Mac but Gatekeeper will block it elsewhere."; \
	  echo "A recipient has to run:"; \
	  echo "    xattr -dr com.apple.quarantine /Applications/PRMaster.app"; \
	  echo "For real distribution you need an Apple Developer ID, then:"; \
	  echo "    make dist SIGN_ID=\"Developer ID Application: NAME (TEAMID)\""; \
	  echo "    xcrun notarytool submit ... --wait && xcrun stapler staple ..."; \
	fi

# Guards the one number that has to agree in two places.
#
# The updater compares a release tag against the running
# CFBundleShortVersionString, so a tag that disagrees with the plist either
# offers an update the user already has — forever — or never fires at all.
# Called first by the release workflow, so a mismatch fails before anything is
# built or published rather than after.
#
# TAG is read as `$$TAG` from the environment rather than expanded as `$(TAG)`
# into the recipe. Make sends command-line variables to the recipe's environment,
# and a tag name may legally contain backticks or `$(…)` — `git tag 'v1.0.0`id`'`
# is accepted. Expanding it into the recipe would both run it and, because the
# substitution leaves the surrounding text behind, make a mismatched tag compare
# equal and pass the very check this target exists to perform.
verify-version:
	@test -n "$$TAG" || { echo "usage: make verify-version TAG=vX.Y.Z"; exit 1; }
	@test "$$TAG" = "v$(VERSION)" || { \
	  printf "tag '%s' does not match 'v%s' from Resources/Info.plist\n" "$$TAG" "$(VERSION)"; \
	  echo "bump CFBundleShortVersionString, or tag v$(VERSION) instead."; \
	  exit 1; \
	}
	@printf 'tag %s matches Resources/Info.plist\n' "$$TAG"

clean:
	rm -rf .build $(DIST)
