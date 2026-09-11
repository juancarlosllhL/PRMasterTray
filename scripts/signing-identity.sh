#!/bin/bash

# An ad-hoc signature has no identity, so a Keychain item binds to the raw code
# hash and every rebuild reads as a different program. A stable certificate
# binds it to the identity instead. Run once; may ask for your login password.

set -euo pipefail

NAME="PRMaster Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Already present: $NAME"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Generating a self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# OpenSSL 3 defaults to an AES/SHA-256 PKCS#12 MAC that Apple's importer
# rejects outright, and an empty password trips it as well.
openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout pass:prmaster

echo "Importing it into your login keychain…"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P prmaster \
    -T /usr/bin/codesign -T /usr/bin/security

echo "Trusting it for code signing (this step may ask for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Done. '$NAME' is now a valid code-signing identity."
    echo "make bundle picks it up automatically from here on."
    echo
    echo "The next run still asks once, because the saved item was written by the"
    echo "old ad-hoc build. Choose Always Allow and it will not ask again."
else
    echo "Created, but not yet valid for code signing. Open Keychain Access, find"
    echo "'$NAME' under login, and set Code Signing to Always Trust."
    exit 1
fi
