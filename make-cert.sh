#!/bin/bash
# One-time: creates a local code signing certificate called "Ledge Local" in
# your login keychain. build.sh signs with it, so permissions you grant Ledge
# (Accessibility, Screen Recording, Calendars) survive rebuilds. Nothing
# leaves your Mac.
set -euo pipefail

NAME="Ledge Local"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists. Nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CFG

# macOS's own openssl, so the result imports cleanly into the keychain
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cfg" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/ledge.p12" -passout pass:ledge 2>/dev/null

security import "$WORK/ledge.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P ledge -T /usr/bin/codesign >/dev/null

echo "Created \"$NAME\". Rebuild with: bash restart.sh"
echo "If macOS asks whether codesign may use the key, choose Always Allow."
