#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

LAUNCH=true
for arg in "$@"; do
    case "${arg}" in
        --no-launch) LAUNCH=false ;;
    esac
done

APP="SnapClean.app"
BUNDLE_ID="com.snapclean.app"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -f Assets/AppIcon.icns ]]; then
    echo "Generating app icon..."
    swift Scripts/GenerateAppIcon.swift
fi

VERSION=$(plutil -extract CFBundleShortVersionString raw AppInfo.plist)
BUILD_NUMBER=$(plutil -extract CFBundleVersion raw AppInfo.plist)
echo "Building SnapClean ${VERSION} (${BUILD_NUMBER}, release)..."
swift build -c release

BIN=".build/release/SnapClean"
if [[ ! -x "${BIN}" ]]; then
    echo "error: expected binary not found at ${BIN}" >&2
    exit 1
fi

echo "Self-test..."
"${BIN}" --self-test

echo "Assembling ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/SnapClean"
chmod +x "${APP}/Contents/MacOS/SnapClean"
# SwiftPM records the deployment target in LC_BUILD_VERSION's sdk field.
# Stamp the SDK actually used so macOS 27 does not keep Ventura compatibility behavior.
SDK_VERSION=$(xcrun --show-sdk-version)
vtool -set-build-version macos 13.0 "${SDK_VERSION}" -replace -output "${APP}/Contents/MacOS/SnapClean" "${APP}/Contents/MacOS/SnapClean"
cp AppInfo.plist "${APP}/Contents/Info.plist"

if [[ -f Assets/AppIcon.icns ]]; then
    cp Assets/AppIcon.icns "${APP}/Contents/Resources/"
fi

echo "Signing ${APP}..."
xattr -cr "${APP}" 2>/dev/null || true
codesign --force --sign - --identifier "${BUNDLE_ID}" --timestamp=none "${APP}/Contents/MacOS/SnapClean"
codesign --force --sign - --identifier "${BUNDLE_ID}" --timestamp=none "${APP}"

plutil -lint "${APP}/Contents/Info.plist" >/dev/null
codesign --verify --verbose=2 "${APP}" 2>/dev/null || codesign --verify "${APP}"

echo "Done: ${APP} (v${VERSION})"
if [[ "${LAUNCH}" == "true" ]]; then
    pkill -x SnapClean 2>/dev/null || true
    sleep 0.2
    echo "Launching..."
    open "${APP}"
fi
