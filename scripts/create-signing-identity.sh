#!/bin/bash
# Creates a self-signed code-signing identity, "Lustro Local Signing", in your login keychain.
#
# Why: ad-hoc signatures change on every build, so macOS forgets permissions such as Full Disk Access.
# A stable identity keeps the app's designated requirement the same, so permissions survive rebuilds.
# The private key stays in your keychain; nothing is written to the repository.
#
# This identity is for local builds only. Releases for other people still need a Developer ID.
set -euo pipefail

NAME="Lustro Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists in your login keychain."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASSWORD=$(uuidgen)

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# macOS's `security` reads the legacy PKCS#12 encryption that /usr/bin/openssl (LibreSSL) writes by default.
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/identity.p12" -passout "pass:$PASSWORD"
# -T lets codesign use the key without a keychain prompt on every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null

echo "Created \"$NAME\". scripts/build-app.sh will use it automatically."
echo "Grant Full Disk Access to build/Lustro.app once more; it will now be kept across rebuilds."
