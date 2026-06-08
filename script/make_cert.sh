#!/bin/bash
set -e

# Creates the STABLE self-signed code-signing certificate Duck Audio is signed
# with. Run this ONCE per machine. After this, script/build_app.sh produces a
# .app that works when double-clicked (the ad-hoc signature did not).
#
# Why this is needed: macOS TCC (the permission system) will not reliably grant
# microphone/audio access to an ad-hoc-signed app because its identity changes
# every build. A stable certificate gives it a consistent identity TCC trusts.
# The cert does NOT need to be trusted as a root — codesign can sign with it,
# and that's all we need for permissions to stick on this Mac.

CN="Duck Audio Self Signed"

if security find-identity -p codesigning 2>/dev/null | grep -q "$CN"; then
  echo "Identity '$CN' already exists. Nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/codesign.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $CN
[ ext ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

echo "Generating key + self-signed code-signing certificate..."
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/da.key" -out "$WORK/da.crt" \
  -days 3650 -nodes -config "$WORK/codesign.conf" >/dev/null 2>&1

# -legacy + -macalg sha1 = format macOS `security import` can read.
openssl pkcs12 -export -legacy -inkey "$WORK/da.key" -in "$WORK/da.crt" \
  -out "$WORK/da.p12" -passout pass:duckaudio -name "$CN" -macalg sha1 >/dev/null 2>&1

echo "Importing into login keychain (allows codesign to use it)..."
security import "$WORK/da.p12" -k ~/Library/Keychains/login.keychain-db \
  -P duckaudio -T /usr/bin/codesign -A >/dev/null 2>&1

if security find-identity -p codesigning 2>/dev/null | grep -q "$CN"; then
  echo "Done. '$CN' is ready. Now run: script/build_app.sh"
else
  echo "Import finished but identity not listed — try: security find-identity -p codesigning"
fi
