#!/bin/sh
# Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
# Builds the openconnect VPuNinst ships, into build/openconnect/: one binary
# with OpenSSL built in, for Apple silicon and Intel alike, openconnect's HIP
# script, and both licences, from pinned sources checked against their SHA-256.
#
#   sh tools/build-openconnect.sh           reuses an earlier build of these versions
#   sh tools/build-openconnect.sh --fresh   builds everything again, in a new folder
#
# A release always builds fresh (packaging/release.sh): what was built before
# sits in folders the user can write to, and a release must not ship anything
# that could have been swapped there since.
#
# Apple's command-line tools are all it needs. It runs in an emptied
# environment, with a PATH that leaves out Homebrew, so no compiler or setting
# from elsewhere slips in; the binary links only libraries that come with
# macOS, and the script checks that it does.
#
# OpenSSL reads a configuration file from a directory fixed when it is built,
# and that file can load code. That directory, and every other one OpenSSL is
# built to know, is in the root-owned folder the helper runs openconnect from;
# and OpenSSL is built unable to load code from disk at all. The script
# refuses a binary that names any folder the user could own.
#
# To move to a new version, change it and its checksum below and run this
# again; tools/check-upstream.sh says when there is one. Each release then
# carries the fix, and its notes should say so.
set -eu
# An emptied environment: CC, AR, DEVELOPER_DIR, SDKROOT and the like would
# otherwise reach OpenSSL's Configure and the compiler.
if [ -z "${VPUNINST_CLEAN_ENV:-}" ]; then
  exec /usr/bin/env -i VPUNINST_CLEAN_ENV=1 HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    /bin/sh "$0" "$@"
fi
cd "$(dirname "$0")/.."

OPENCONNECT=9.21
OPENCONNECT_SHA256=5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58
# The 3.5 line has long-term support: security fixes for years, without
# the changes a new minor version brings.
OPENSSL=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
# Built once for each, and joined into one binary that runs on both.
ARCHS="arm64 x86_64"
# Where the installed copy lives (helper/vpuninst-helper's SNAP).
HOMEDIR=/Library/PrivilegedHelperTools/vpuninst

TOP=$(pwd)
SCRIPT="$TOP/tools/build-openconnect.sh"
OUT="$TOP/build/openconnect"
SDK=$(xcrun --show-sdk-path)
export MACOSX_DEPLOYMENT_TARGET=14.0
JOBS=$(sysctl -n hw.ncpu)
# The downloads are kept in the user's cache folder, and checked against their
# checksums at every use. The build itself happens there too, in a folder
# named for the versions, or, with --fresh, in a new one that is removed
# afterwards. Space-free: openconnect's configure can't take a path with a
# space in it, and a checkout's path may have one.
CACHE="$(getconf DARWIN_USER_CACHE_DIR)vpuninst-openconnect"
KEY="$OPENCONNECT-$(echo "$OPENCONNECT_SHA256" | cut -c1-12)-$OPENSSL-$(echo "$OPENSSL_SHA256" | cut -c1-12)"
PATCH="$TOP/tools/openconnect-gp-reconnect.patch"
STAMP="$KEY $ARCHS $(shasum -a 256 < "$SCRIPT" | cut -c1-64) $(shasum -a 256 < "$PATCH" | cut -c1-64)"
FRESH=no
[ "${1:-}" = --fresh ] && FRESH=yes
if [ $FRESH = yes ]; then
  WORK=$(mktemp -d "$(getconf DARWIN_USER_TEMP_DIR)vpuninst-openconnect.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT
else
  WORK="$CACHE/$KEY"
  # Built already, from these versions and this script: nothing to do.
  if [ -x "$OUT/openconnect" ] && [ "$(cat "$OUT/.built" 2>/dev/null)" = "$STAMP" ]; then
    echo "openconnect $OPENCONNECT with OpenSSL $OPENSSL is built already"
    exit 0
  fi
fi
case "$WORK" in *" "*) echo "no space-free folder to build in: $WORK" >&2; exit 1 ;; esac
mkdir -p "$CACHE" "$WORK"

fetch() {   # <url> <sha256> <file>
  if [ ! -f "$CACHE/$3" ] || ! echo "$2  $CACHE/$3" | shasum -a 256 -c --status; then
    curl -fsSL --proto '=https' -o "$CACHE/$3.part" "$1"
    mv "$CACHE/$3.part" "$CACHE/$3"
  fi
  # Copied first and checked as copied, so what is unpacked is what was checked.
  cp "$CACHE/$3" "$WORK/$3"
  echo "$2  $WORK/$3" | shasum -a 256 -c --status || { echo "$3 doesn't match its checksum" >&2; exit 1; }
}
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL/openssl-$OPENSSL.tar.gz" \
  "$OPENSSL_SHA256" "openssl-$OPENSSL.tar.gz"
fetch "https://www.infradead.org/openconnect/download/openconnect-$OPENCONNECT.tar.gz" \
  "$OPENCONNECT_SHA256" "openconnect-$OPENCONNECT.tar.gz"

# One architecture's openconnect, in $WORK/<arch>/openconnect.
build() {   # <arch>
  A=$1
  case "$A" in
    arm64) TARGET=darwin64-arm64-cc HOST="" ;;
    x86_64) TARGET=darwin64-x86_64-cc HOST=x86_64-apple-darwin ;;
  esac
  D="$WORK/$A"
  rm -rf "$D"
  mkdir -p "$D"
  FLAGS="-arch $A -isysroot $SDK -mmacosx-version-min=14.0"

  # OpenSSL: static, providers built in, no engines and no loading of code
  # from disk, no command-line tool. Its prefix, and so every directory it is
  # built to know, is root's folder; it is installed into a staging folder
  # for openconnect to link against. It compiles its sources by relative
  # paths, and records its compiler flags in the library, so it is given no
  # path of the build's.
  SSL="$D/openssl-$OPENSSL"
  STAGE="$D/stage$HOMEDIR"
  tar -xzf "$WORK/openssl-$OPENSSL.tar.gz" -C "$D"
  (cd "$SSL" &&
    ./Configure "$TARGET" no-shared no-module no-dso no-engine no-apps no-tests no-docs \
      --prefix="$HOMEDIR" --libdir=lib --openssldir="$HOMEDIR/ssl" \
      -isysroot "$SDK" -mmacosx-version-min=14.0 &&
    make -j"$JOBS" build_libs &&
    make install_dev DESTDIR="$D/stage") >"$D/openssl.log" 2>&1 || { tail -30 "$D/openssl.log" >&2; exit 1; }

  # configure asks pkg-config, which macOS doesn't have, about each library it
  # might use. This stand-in knows the three the build provides and says no
  # to everything else, so nothing optional is switched on by accident.
  mkdir -p "$D/bin"
  cat > "$D/bin/pkg-config" <<EOF
#!/bin/sh
case " \$* " in *" --version "*) echo 0.29.2; exit 0 ;; *" --atleast-pkgconfig-version"*) exit 0 ;; esac
for A in "\$@"; do case "\$A" in -*) ;; *) M=\${A%% *}; break ;; esac; done
case "\${M:-}" in
  openssl|libssl|libcrypto) V=$OPENSSL C="-I$STAGE/include" L="-L$STAGE/lib -lssl -lcrypto" ;;
  libxml-2.0) V=2.9.13 C="-I$SDK/usr/include/libxml2" L=-lxml2 ;;
  zlib) V=1.2.12 C= L=-lz ;;
  *) exit 1 ;;
esac
case " \$* " in *" --cflags "*) echo "\$C" ;; *" --libs "*) echo "\$L" ;; *" --modversion "*) echo "\$V" ;; esac
exit 0
EOF
  chmod +x "$D/bin/pkg-config"

  # openconnect: the command-line tool alone, linked statically with its own
  # library and OpenSSL; libxml2 and zlib come from macOS, JSON parsing is
  # openconnect's own. Everything optional that would need another library
  # is left out, Kerberos too: the helper never signs in with it. OpenSSL goes
  # in by -L and -l, not by the archives' paths, which libtool would try to
  # nest inside openconnect's own, leaving it empty; the folder holds only the
  # static libraries, so those are what is linked.
  OC="$D/openconnect-$OPENCONNECT"
  tar -xzf "$WORK/openconnect-$OPENCONNECT.tar.gz" -C "$D"
  # Keeps a Palo Alto tunnel up across sleep (see the patch). A version it
  # no longer applies to stops the build, to be looked at again. Patched, the
  # version string is made again, by a script that takes the RPM_PACKAGE_*
  # variables below: it then reads v<version>-vpuninst, not -unknown.
  patch -s -p1 -d "$OC" < "$PATCH" || { echo "the patch doesn't apply to openconnect $OPENCONNECT" >&2; exit 1; }
  (cd "$OC" &&
    ./configure --quiet ${HOST:+--host=$HOST} --disable-shared --enable-static --disable-nls \
      --without-gnutls --with-builtin-json --without-gssapi \
      --without-libproxy --without-stoken --without-libpskc --without-libpcsclite \
      --without-lz4 --without-java \
      --with-vpnc-script=/Library/PrivilegedHelperTools/vpuninst-tunnel \
      PKG_CONFIG="$D/bin/pkg-config" \
      CC="xcrun clang" CFLAGS="-O2 $FLAGS -ffile-prefix-map=$OC=openconnect" LDFLAGS="$FLAGS" \
      OPENSSL_CFLAGS="-I$STAGE/include" OPENSSL_LIBS="-L$STAGE/lib -lssl -lcrypto" \
      LIBXML2_CFLAGS="-I$SDK/usr/include/libxml2" LIBXML2_LIBS="-lxml2" \
      ZLIB_CFLAGS="" ZLIB_LIBS="-lz" &&
    RPM_PACKAGE_VERSION=$OPENCONNECT RPM_PACKAGE_RELEASE=vpuninst make -j"$JOBS") >"$D/openconnect.log" 2>&1 || { tail -30 "$D/openconnect.log" >&2; exit 1; }
  cp "$OC/openconnect" "$D/openconnect"
  strip -x "$D/openconnect"
}

for A in $ARCHS; do build "$A"; done

rm -rf "$OUT"
mkdir -p "$OUT/licenses"
set --
for A in $ARCHS; do set -- "$@" "$WORK/$A/openconnect"; done
lipo -create -output "$OUT/openconnect" "$@"
FIRST=$(echo $ARCHS | cut -d' ' -f1)
cp "$WORK/$FIRST/openconnect-$OPENCONNECT/trojans/hipreport.sh" "$OUT/hipreport.sh"
chmod 0755 "$OUT/openconnect" "$OUT/hipreport.sh"
cp "$WORK/$FIRST/openconnect-$OPENCONNECT/COPYING.LGPL" "$OUT/licenses/openconnect-LGPL-2.1.txt"
cp "$PATCH" "$OUT/licenses/openconnect-gp-reconnect.patch"
cp "$WORK/$FIRST/openssl-$OPENSSL/LICENSE.txt" "$OUT/licenses/OpenSSL-Apache-2.0.txt"

# The binary must be for every architecture, report the versions it was
# built from, link only what comes with macOS, and name no folder the user
# could own: neither Homebrew's, nor a home or cache folder, nor the build's.
WANT=$(printf '%s\n' $ARCHS | sort | tr '\n' ' ')
HAVE=$(lipo -archs "$OUT/openconnect" | tr ' ' '\n' | sort | tr '\n' ' ')
[ "$HAVE" = "$WANT" ] || { echo "the binary is for $HAVE, not $WANT" >&2; exit 1; }
for A in $ARCHS; do
  BAD=$(otool -arch "$A" -L "$OUT/openconnect" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' || true)
  [ -z "$BAD" ] || { echo "$A links outside macOS: $BAD" >&2; exit 1; }
  BAD=$(LC_ALL=C grep -aoE '/(opt/homebrew|usr/local|Users|private|var/folders)/[[:graph:]]*' "$WORK/$A/openconnect" | sort -u | head -3)
  [ -z "$BAD" ] || { echo "the $A binary names folders the user could own: $BAD" >&2; exit 1; }
  LC_ALL=C grep -aqF "$WORK" "$WORK/$A/openconnect" && { echo "the $A binary names the build folder" >&2; exit 1; }
  LC_ALL=C grep -aqF "$HOMEDIR/ssl" "$WORK/$A/openconnect" || { echo "OpenSSL's config directory isn't $HOMEDIR/ssl ($A)" >&2; exit 1; }
  if [ "$A" = "$(uname -m)" ] || arch -"$A" /usr/bin/true 2>/dev/null; then
    V=$(arch -"$A" "$OUT/openconnect" --version 2>&1)
    case "$V" in *"version v$OPENCONNECT"*"Using OpenSSL $OPENSSL "*) ;;
      *) echo "the $A binary isn't openconnect $OPENCONNECT with OpenSSL $OPENSSL: $V" >&2; exit 1 ;;
    esac
  else
    echo "can't run the $A binary on this Mac; its versions are unchecked" >&2
  fi
done

SHA=$(shasum -a 256 < "$OUT/openconnect" | cut -c1-64)
cat > "$OUT/licenses/SOURCES.txt" <<EOF
VPuNinst ships openconnect $OPENCONNECT, built with OpenSSL $OPENSSL for
$(echo $ARCHS | sed 's/ / and /') by tools/build-openconnect.sh in VPuNinst's repository,
from these sources:

https://www.infradead.org/openconnect/download/openconnect-$OPENCONNECT.tar.gz
  SHA-256 $OPENCONNECT_SHA256
  changed by openconnect-gp-reconnect.patch, beside this file
https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL/openssl-$OPENSSL.tar.gz
  SHA-256 $OPENSSL_SHA256

The binary built from them:
  SHA-256 $SHA

openconnect is under the GNU Lesser General Public License 2.1, OpenSSL under
the Apache License 2.0; their texts are beside this file.
EOF
"$OUT/openconnect" --version 2>&1 | head -2
echo "$STAMP" > "$OUT/.built"
echo "built $OUT for $(lipo -archs "$OUT/openconnect"), SHA-256 $SHA"
