#!/bin/zsh
# One-time setup: creates a local code signing certificate named "Monty Local Signing"
# in your login keychain.
#
# Why: without a certificate every build is signed ad-hoc, macOS sees each build as a
# new app, and the Accessibility permission has to be given again after every rebuild.
# With a stable certificate, macOS remembers the permission across rebuilds.
#
# The certificate is only used on this Mac to sign Monty. It is not trusted for
# anything else. To remove it later: open Keychain Access, search "Monty Local
# Signing", and delete the certificate and its key.
set -e

NAME="Monty Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Already set up: \"$NAME\" is in your login keychain."
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=$(openssl rand -hex 16)

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -out "$tmp/id.p12" -passout "pass:$pass"

# -T lets codesign use the key without asking every time.
security import "$tmp/id.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign

echo
echo "Done. Now run: ./build.sh run"
