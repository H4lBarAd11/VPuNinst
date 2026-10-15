#!/bin/sh
# Makes the local certificate build.sh signs the app with. Run it once.
# Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
#
#   sh tools/make-signing-cert.sh
#
# Signed ad hoc, each build is a new app to the keychain, which asks again for
# the saved sign-in passwords after every rebuild. Signed with this certificate,
# every build meets the same requirement ("this bundle ID, signed by this
# certificate"), so Always Allow is answered once. The certificate is
# self-signed and only ever used on this Mac; nothing else needs to trust it.
set -eu
NAME="VPuNinst Local Signing"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "\"$NAME\" is already in $KEYCHAIN"; exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
# The system's LibreSSL, by path: a PKCS#12 file from Homebrew's OpenSSL 3
# fails to import ("MAC verification failed").
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$PASS"
# Only codesign may use the key without asking.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
security find-identity -p codesigning "$KEYCHAIN" | grep "\"$NAME\""
echo "made \"$NAME\"; ./build.sh now signs with it"
