# Build the Sondr app. Output: build/<Configuration>/Build/Products/<Configuration>/Sondr.app
# Debug is about 7x slower at indexing than Release; use Release for real libraries.

DERIVED = build

.PHONY: debug release run-debug run-release project clean reset

project:
	xcodegen generate

debug: project
	xcodebuild -scheme Sondr -configuration Debug -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED)/Debug build

release: project
	xcodebuild -scheme Sondr -configuration Release -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED)/Release build

run-debug: debug
	open $(DERIVED)/Debug/Build/Products/Debug/Sondr.app

run-release: release
	open $(DERIVED)/Release/Build/Products/Release/Sondr.app

clean:
	rm -rf $(DERIVED)

# Forget everything the app knows: library database (locations, samples, tags, filters, map) and preferences.
# Keeps the downloaded models. Quit the app first. SONDR_DB overrides the database path, as in the app.
SONDR_DB ?= $(HOME)/Library/Application Support/Sondr/library.sqlite

reset:
	rm -f "$(SONDR_DB)" "$(SONDR_DB)-wal" "$(SONDR_DB)-shm"
	-defaults delete com.sebastianmika.sondr
