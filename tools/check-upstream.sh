#!/bin/sh
# Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
# Says whether openconnect, or OpenSSL in the line VPuNinst follows, has a
# newer release than the ones tools/build-openconnect.sh pins. Users get a
# security fix in either only through a new VPuNinst release, so run this now
# and then; packaging/release.sh runs it too.
#
#   sh tools/check-upstream.sh
#
# Exits 0 when both are current, 1 when either has a newer release, 2 when it
# couldn't find out.
set -u
cd "$(dirname "$0")/.."
PATH=/usr/bin:/bin:/usr/sbin:/sbin

pinned() { sed -n "s/^$1=//p" tools/build-openconnect.sh; }
OC=$(pinned OPENCONNECT)
SSL=$(pinned OPENSSL)
LINE=${SSL%.*}

newest() { sort -t. -k1,1n -k2,2n -k3,3n | tail -1; }
LATEST_OC=$(curl -fsSL --proto '=https' https://www.infradead.org/openconnect/download.html 2>/dev/null |
  grep -oE 'openconnect-[0-9]+(\.[0-9]+)+\.tar\.gz' | sed -e 's/^openconnect-//' -e 's/\.tar\.gz$//' | newest)
LATEST_SSL=$(curl -fsSL --proto '=https' "https://api.github.com/repos/openssl/openssl/releases?per_page=100" 2>/dev/null |
  grep -oE "\"tag_name\": *\"openssl-$LINE\.[0-9]+\"" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | newest)

[ -n "$LATEST_OC" ] && [ -n "$LATEST_SSL" ] || { echo "couldn't reach openconnect's or OpenSSL's release lists" >&2; exit 2; }

RC=0
report() {   # <name> <pinned> <latest>
  if [ "$2" != "$3" ] && [ "$(printf '%s\n%s\n' "$2" "$3" | newest)" = "$3" ]; then
    echo "$1 $3 is out (VPuNinst builds $2): update tools/build-openconnect.sh and release"
    RC=1
  else
    echo "$1 $2 is the latest"
  fi
}
report openconnect "$OC" "$LATEST_OC"
report "OpenSSL $LINE" "$SSL" "$LATEST_SSL"
exit $RC
