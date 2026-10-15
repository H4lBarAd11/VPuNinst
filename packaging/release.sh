#!/bin/sh
# Publishes build/VPuNinst-<version>.pkg as GitHub release v<version>.
# Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
#
#   sh packaging/release.sh
#
# Run after raising VERSION, committing and pushing. The package is built here,
# not on GitHub, so that it is signed with the local certificate: every release
# then carries the same signature, and the keychain's Always Allow for the
# saved password survives an update. The release notes are the message of the
# commit that raised VERSION, so a later fix to the README doesn't replace them,
# followed by the sources openconnect was built from and its checksum.
set -eu
cd "$(dirname "$0")/.."
V=$(tr -d '[:space:]' < VERSION)
SIGN="VPuNinst Local Signing"

[ -z "$(git status --porcelain)" ] || { echo "uncommitted changes: a release is built from a commit" >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "HEAD isn't origin/main: push first" >&2; exit 1; }
if gh release view "v$V" >/dev/null 2>&1; then
  echo "v$V is already released: raise VERSION" >&2; exit 1
fi

# Users get openconnect's and OpenSSL's security fixes only through a release,
# so a release carries the latest of both.
UPSTREAM=0
sh tools/check-upstream.sh || UPSTREAM=$?
case $UPSTREAM in
  0) ;;
  1) echo "a newer openconnect or OpenSSL is out: update tools/build-openconnect.sh first" >&2; exit 1 ;;
  *) if [ "${VPUNINST_UPSTREAM_CHECKED:-}" != yes ]; then
       echo "couldn't check for newer openconnect or OpenSSL releases. Check by hand, then run again with VPUNINST_UPSTREAM_CHECKED=yes" >&2
       exit 1
     fi ;;
esac

# openconnect is built afresh, never taken from an earlier build: that sits in
# folders the user can write to, and what ships is installed as root.
sh tools/build-openconnect.sh --fresh
./build.sh pkg
# Ad hoc would build too, and every update would then ask for the keychain again.
codesign -dvv "build/VPuNinst.app" 2>&1 | grep -qx "Authority=$SIGN" \
  || { echo "not signed with \"$SIGN\": run tools/make-signing-cert.sh" >&2; exit 1; }

gh release create "v$V" "build/VPuNinst-$V.pkg" --target "$(git rev-parse HEAD)" \
  --title "VPuNinst $V" --notes "$(git log -1 --format=%B -- VERSION)

$(cat build/openconnect/licenses/SOURCES.txt)"
