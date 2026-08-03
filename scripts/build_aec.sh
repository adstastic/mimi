#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_URL="https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz"
SOURCE_SHA256="ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe"
BUILD_ROOT="${TMPDIR:-/tmp}/mimi-aec-build"
SOURCE_ARCHIVE="$BUILD_ROOT/webrtc-audio-processing-2.1.tar.xz"
SOURCE_DIR="$BUILD_ROOT/source"
MESON_BUILD_DIR="$BUILD_ROOT/meson"
OUTPUT_DIR="$ROOT_DIR/Vendor/MimiAEC.xcframework"

mkdir -p "$BUILD_ROOT"
if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
  curl -L --fail --retry 2 "$SOURCE_URL" -o "$SOURCE_ARCHIVE"
fi

echo "$SOURCE_SHA256  $SOURCE_ARCHIVE" | shasum -a 256 -c -

rm -rf "$SOURCE_DIR" "$MESON_BUILD_DIR" "$OUTPUT_DIR"
mkdir -p "$SOURCE_DIR"
tar -xJf "$SOURCE_ARCHIVE" -C "$SOURCE_DIR" --strip-components=1

MACOSX_DEPLOYMENT_TARGET=26.0 \
  CFLAGS="-mmacosx-version-min=26.0" CXXFLAGS="-mmacosx-version-min=26.0" \
  UV_CACHE_DIR="$BUILD_ROOT/uv-cache" \
  UV_TOOL_DIR="$BUILD_ROOT/uv-tools" CCACHE_DIR="$BUILD_ROOT/ccache" \
  uvx --from meson meson setup \
  "$MESON_BUILD_DIR" "$SOURCE_DIR" \
  -Ddefault_library=static \
  -Dbuildtype=release \
  --force-fallback-for=absl_base,absl_flags,absl_strings,absl_numeric,absl_synchronization,absl_bad_optional_access
CCACHE_DIR="$BUILD_ROOT/ccache" ninja -C "$MESON_BUILD_DIR"

MACOSX_DEPLOYMENT_TARGET=26.0 c++ -std=c++17 -O3 -mmacosx-version-min=26.0 \
  -DWEBRTC_MAC -DWEBRTC_POSIX -DWEBRTC_ARCH_ARM64 -DWEBRTC_HAS_NEON \
  -I"$ROOT_DIR/Vendor/MimiAEC/include" \
  -I"$SOURCE_DIR" \
  -I"$SOURCE_DIR/webrtc" \
  -I"$SOURCE_DIR/subprojects/abseil-cpp-20240722.0" \
  -c "$ROOT_DIR/Vendor/MimiAEC/src/MimiAEC.cpp" \
  -o "$BUILD_ROOT/MimiAEC.o"

libtool -static \
  -o "$BUILD_ROOT/libMimiAEC.a" \
  "$BUILD_ROOT/MimiAEC.o" \
  "$MESON_BUILD_DIR/webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a"

xcodebuild -create-xcframework \
  -library "$BUILD_ROOT/libMimiAEC.a" \
  -headers "$ROOT_DIR/Vendor/MimiAEC/include" \
  -output "$OUTPUT_DIR"

echo "Built $OUTPUT_DIR"
