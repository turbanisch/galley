#!/bin/bash
# Builds Galley.app and installs it into /Applications.
# Usage: ./build.sh            build and install
#        ./build.sh --no-install   build only (result in build/)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Galley"
APP="build/${APP_NAME}.app"
INSTALL_DIR="/Applications"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install the Command Line Tools with: xcode-select --install"
  exit 1
fi

echo "-> Compiling..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
xcrun swiftc -O -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-name "${APP_NAME}" \
  Sources/*.swift -o "${APP}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${APP}/Contents/Info.plist"
cp Icon/macOS/Galley.icns "${APP}/Contents/Resources/AppIcon.icns"
codesign --force --sign - "${APP}" >/dev/null 2>&1

if [[ "${1:-}" == "--no-install" ]]; then
  echo "OK: Built ${APP}"
  exit 0
fi

if pgrep -x "${APP_NAME}" >/dev/null; then
  echo "-> Quitting the running copy..."
  osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
  sleep 1
fi

echo "-> Installing to ${INSTALL_DIR}..."
rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
cp -R "${APP}" "${INSTALL_DIR}/"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "${INSTALL_DIR}/${APP_NAME}.app" >/dev/null 2>&1 || true
echo "OK: Galley installed. Open a PDF with: open -a Galley file.pdf"
