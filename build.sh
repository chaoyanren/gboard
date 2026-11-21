#!/usr/bin/env bash
set -euo pipefail

cd "$(cd "$(dirname "$0")" && pwd)"

# ── Directory layout ─────────────────────────────────────────────────────────
XCODE_DIR="GboardIME"
BUILD_DIR="$XCODE_DIR/build/release"
APP_NAME="GboardIME.app"
INSTALL_DIR="$HOME/Library/Input Methods"
ENTITLEMENTS="$XCODE_DIR/GboardIME.entitlements"

usage() {
    echo "Usage: $0 [build|install|uninstall|clean]"
    echo "  build     Build the app (default)"
    echo "  install   Build, install to ~/Library/Input Methods, and sign"
    echo "  uninstall Remove from ~/Library/Input Methods"
    echo "  clean     Remove build artifacts"
}

copy_engine_resources() {
    scripts/copy_engine_resources.sh "$1"
    echo "Copied native engine and pinyin data pack"
}

has_xcodebuild() {
    xcodebuild -version >/dev/null 2>&1
}

build_with_xcodebuild() {
    echo "Building GboardIME (Release) with xcodebuild..."
    (
        cd "$XCODE_DIR"
        xcodebuild -quiet \
            -scheme GboardIME \
            -configuration Release \
            build \
            CONFIGURATION_BUILD_DIR="build/release"
    )
}

# Fallback for machines with only the Command Line Tools installed. Mirrors the
# Xcode project's Release settings; update both when adding sources or flags.
build_with_swiftc() {
    echo "Building GboardIME (Release) with swiftc (Xcode not found)..."
    local target="arm64-apple-macos13.0"
    local app="$BUILD_DIR/$APP_NAME"
    local obj_dir="$BUILD_DIR/obj"
    local c_srcs=("$XCODE_DIR"/ime/*.c "$XCODE_DIR"/engine/*.c)
    local objs=()

    rm -rf "$app" "$obj_dir"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$obj_dir"

    for src in "${c_srcs[@]}"; do
        local obj="$obj_dir/$(basename "${src%.c}").o"
        clang -c -Os -target "$target" \
            -I"$XCODE_DIR/engine" -I"$XCODE_DIR/ime" \
            -o "$obj" "$src"
        objs+=("$obj")
    done

    local sdk
    sdk=$(xcrun --show-sdk-path)

    # Locate the SwiftUI macro plugin so swiftc can resolve @State etc.
    local plugin_flags=()
    local toolchain_lib
    toolchain_lib=$(xcrun --find swiftc 2>/dev/null | xargs -I{} dirname {} | xargs -I{} dirname {})
    local candidate
    for candidate in \
        "$toolchain_lib/lib/swift/host/plugins/libSwiftUIMacros.dylib" \
        "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" \
        "$(find /Library/Developer/CommandLineTools -name 'libSwiftUIMacros*' -type f 2>/dev/null | head -1)"; do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            plugin_flags=(-load-plugin-library "$candidate")
            echo "Using SwiftUI macro plugin: $candidate"
            break
        fi
    done
    if [[ ${#plugin_flags[@]} -eq 0 ]]; then
        echo "WARNING: SwiftUIMacros plugin not found; build may fail." >&2
        find /Library/Developer -name 'libSwiftUIMacros*' 2>/dev/null | head -5
    fi

    swiftc -O -swift-version 5 -target "$target" \
        -sdk "$sdk" \
        "${plugin_flags[@]+"${plugin_flags[@]}"}" \
        -I"$XCODE_DIR/engine" -I"$XCODE_DIR/ime" \
        -import-objc-header "$XCODE_DIR/ime/GboardBridge.h" \
        -framework Cocoa -framework InputMethodKit \
        -o "$app/Contents/MacOS/GboardIME" \
        "$XCODE_DIR"/ime/*.swift "${objs[@]}"

    cp "$XCODE_DIR/Info.plist" "$app/Contents/Info.plist"
    printf 'APPL????' > "$app/Contents/PkgInfo"
    rm -rf "$obj_dir"
}

do_build() {
    # The Xcode project copies engine resources in its own build phase.
    if has_xcodebuild; then
        build_with_xcodebuild
    else
        build_with_swiftc
        copy_engine_resources "$BUILD_DIR/$APP_NAME"
    fi
    echo "Built: $BUILD_DIR/$APP_NAME"
}

do_install() {
    do_build

    echo "Installing to $INSTALL_DIR..."
    killall GboardIME 2>/dev/null || true
    sleep 2

    rm -rf "$INSTALL_DIR/$APP_NAME"
    cp -R "$BUILD_DIR/$APP_NAME" "$INSTALL_DIR/$APP_NAME"

    codesign --force --deep --sign - \
        --entitlements "$ENTITLEMENTS" \
        "$INSTALL_DIR/$APP_NAME"

    echo "Installed and signed."
    echo ""
    echo "To activate:"
    echo "  1. Log out and log back in (or restart)"
    echo "  2. System Settings → Keyboard → Input Sources → Edit → + → Chinese, Simplified → GboardIME"
    echo "  3. Switch to GboardIME from the menu bar input source picker"
}

do_uninstall() {
    killall GboardIME 2>/dev/null || true
    rm -rf "$INSTALL_DIR/$APP_NAME"
    echo "Uninstalled."
}

do_clean() {
    rm -rf "$BUILD_DIR"
    rm -f tests/test_engine
    rm -rf tests/test_engine.dSYM
    echo "Cleaned."
}

case "${1:-build}" in
    build)     do_build ;;
    install)   do_install ;;
    uninstall) do_uninstall ;;
    clean)     do_clean ;;
    -h|--help) usage ;;
    *)         echo "Unknown command: $1"; usage; exit 1 ;;
esac
