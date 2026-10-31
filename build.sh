#!/bin/sh
# Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
# Builds build/VPuNinst.app. `./build.sh install` also puts it in
# /Applications; `./build.sh pkg` also makes the installer,
# build/VPuNinst-<version>.pkg (see packaging/).
set -eu
cd "$(dirname "$0")"
APP="build/VPuNinst.app"
VERSION=$(tr -d '[:space:]' < VERSION)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# VPuNinst's own openconnect, rebuilt only when its pinned versions change.
sh tools/build-openconnect.sh

# For Apple silicon and Intel alike: built once for each, joined into one.
for A in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$A-apple-macos14.0" -o "build/VPuNinst-$A" Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/VPuNinst" build/VPuNinst-arm64 build/VPuNinst-x86_64
rm -f build/VPuNinst-arm64 build/VPuNinst-x86_64

# The licences travel with the app, as the GPL asks of every copy: VPuNinst's,
# and openconnect's and OpenSSL's with the sources they were built from.
cp -R Resources/fonts Resources/AppIcon.icns LICENSE "$APP/Contents/Resources/"
cp -R build/openconnect/licenses "$APP/Contents/Resources/Licenses"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>VPuNinst</string>
  <key>CFBundleDisplayName</key><string>VPuNinst</string>
  <key>CFBundleExecutable</key><string>VPuNinst</string>
  <key>CFBundleIdentifier</key><string>io.github.h4lbarad11.vpuninst</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Riccardo Nevoso. GPL-3.0-or-later.</string>
</dict></plist>
EOF

# Signed with the local certificate when there is one (tools/make-signing-cert.sh):
# every build then meets the same requirement, so the keychain's Always Allow
# for the saved password lasts across rebuilds. Ad hoc otherwise, and macOS
# asks again after each build. KEYCHAIN points both at another keychain.
SIGN="VPuNinst Local Signing"
if security find-identity -p codesigning ${KEYCHAIN:+"$KEYCHAIN"} | grep -q "\"$SIGN\""; then
  codesign --force --timestamp=none ${KEYCHAIN:+--keychain "$KEYCHAIN"} --sign "$SIGN" "$APP"
  echo "built $APP, signed with \"$SIGN\""
else
  codesign --force --sign - "$APP"
  echo "built $APP, signed ad hoc (no \"$SIGN\"; see tools/make-signing-cert.sh)"
fi

# One copy only, in /Applications where the package puts it too: two copies
# would each watch and repair the same tunnels. The package's copy belongs to
# root, so replacing it goes through sudo.
if [ "${1:-}" = install ]; then
  DEST=/Applications/VPuNinst.app
  AS=
  if [ ! -w /Applications ] || { [ -e "$DEST" ] && [ -n "$(find "$DEST" ! -user "$(id -u)" -print -quit)" ]; }; then
    AS=sudo
  fi
  $AS rm -rf "$DEST"
  $AS ditto "$APP" "$DEST"
  # Moved rather than copied: left in build/, Spotlight lists it as an app.
  rm -rf "$APP"
  echo "installed to $DEST"

  # Every other copy macOS knows of: the one in ~/Applications goes, copies
  # already gone or in the Trash leave the app list, and any other is named
  # for you to remove. LaunchServices forgets a copy while it is still there.
  LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  OLD="$HOME/Applications/VPuNinst.app"
  if [ -e "$OLD" ]; then
    "$LSR" -u "$OLD"
    rm -rf "$OLD"
  fi
  "$LSR" -dump 2>/dev/null |
    awk '/^path:/ { sub(/^path: */, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); p = $0 }
         /^identifier:/ && $2 == "io.github.h4lbarad11.vpuninst" { print p }' |
    sort -u | while IFS= read -r P; do
      [ "$P" = "$DEST" ] && continue
      if [ -e "$P" ] && case "$P" in */.Trash/*) false ;; esac; then
        echo "another copy is at $P: remove it" >&2
      else
        "$LSR" -u "$P" >/dev/null 2>&1 || true
      fi
    done
  if pgrep -qx VPuNinst; then
    echo "VPuNinst is running: quit it from the snowflake's menu and open it again"
  fi
fi

# The installer: the app for /Applications, and a postinstall that does the
# README's root steps for whoever is logged in.
if [ "${1:-}" = pkg ]; then
  PKG="build/VPuNinst-$VERSION.pkg"
  STAGE=$(mktemp -d)
  trap 'rm -rf "$STAGE"' EXIT
  mkdir -p "$STAGE/root" "$STAGE/scripts" "$STAGE/pkgs" "$STAGE/pages"
  ditto "$APP" "$STAGE/root/VPuNinst.app"
  cp packaging/postinstall helper/vpuninst-helper helper/vpuninst-tunnel helper/sudoers.in \
    build/openconnect/openconnect build/openconnect/hipreport.sh "$STAGE/scripts/"
  chmod 0755 "$STAGE/scripts/postinstall" "$STAGE/scripts/vpuninst-helper" "$STAGE/scripts/vpuninst-tunnel" \
    "$STAGE/scripts/openconnect" "$STAGE/scripts/hipreport.sh"
  cp packaging/welcome.html packaging/license.html packaging/conclusion.html packaging/background.png "$STAGE/pages/"
  # Not relocatable: otherwise Installer finds a copy built from source and
  # updates that one in place, wherever it is, instead of /Applications.
  pkgbuild --analyze --root "$STAGE/root" "$STAGE/app.plist" >/dev/null
  plutil -replace 0.BundleIsRelocatable -bool NO "$STAGE/app.plist"
  pkgbuild --root "$STAGE/root" --component-plist "$STAGE/app.plist" \
    --install-location /Applications --scripts "$STAGE/scripts" \
    --identifier io.github.h4lbarad11.vpuninst.pkg --version "$VERSION" \
    "$STAGE/pkgs/app.pkg" >/dev/null
  sed "s/@VERSION@/$VERSION/" packaging/distribution.xml > "$STAGE/distribution.xml"
  rm -f "$PKG"
  productbuild --distribution "$STAGE/distribution.xml" --resources "$STAGE/pages" \
    --package-path "$STAGE/pkgs" "$PKG" >/dev/null
  echo "built $PKG"
fi
