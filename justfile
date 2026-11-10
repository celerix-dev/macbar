# CelerixMacBar Workflow Automation
# Configurable build flags (defaults to '--build-system native' for Command Line Tools compatibility)
swift_flags := env("SWIFT_FLAGS", "--build-system native")
app_bundle := ".build/CelerixMacBar.app"
debug_executable := ".build/arm64-apple-macosx/debug/CelerixMacBar"
release_executable := ".build/arm64-apple-macosx/release/CelerixMacBar"

# Default action: build UI and run in foreground for development
default: run

# Build debug target (bundles UI and compiles Swift binary)
build *args="":
    swift build {{ swift_flags }} {{ args }}
    mkdir -p {{ app_bundle }}/Contents/MacOS
    cp {{ debug_executable }} {{ app_bundle }}/Contents/MacOS/CelerixMacBar
    cp Sources/CelerixMacBar/App/Info.plist {{ app_bundle }}/Contents/Info.plist
    codesign --force --deep --sign - {{ app_bundle }}

# Build optimized release binary
release:
    swift build -c release {{ swift_flags }}
    mkdir -p {{ app_bundle }}/Contents/MacOS
    cp {{ release_executable }} {{ app_bundle }}/Contents/MacOS/CelerixMacBar
    cp Sources/CelerixMacBar/App/Info.plist {{ app_bundle }}/Contents/Info.plist
    codesign --force --deep --sign - {{ app_bundle }}

# Run in foreground for active development and console logs
run *args="":
    just build
    {{ app_bundle }}/Contents/MacOS/CelerixMacBar {{ args }}

# Build and launch silently in the background
bg: kill
    @just build > /dev/null 2>&1
    @nohup {{ app_bundle }}/Contents/MacOS/CelerixMacBar > /dev/null 2>&1 &
    @echo "CelerixMacBar launched in background."

# Restart running background instance with a fresh build
restart: bg

# Check status of running instances
status:
    @pgrep -l CelerixMacBar || echo "CelerixMacBar is not running."

# Terminate all running CelerixMacBar instances
kill:
    @-killall CelerixMacBar 2>/dev/null || true

# Clean build artifacts
clean:
    rm -rf .build Frontend/dist
