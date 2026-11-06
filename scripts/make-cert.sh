#!/bin/bash
# Creates a self-signed code-signing identity ("Swapless Self-Signed") in the login keychain
# so make-app.sh can sign with a STABLE identity. Copied from TypeFlow's make-cert.sh.
#
# Human-only (CLAUDE.md §5): it raises a keychain prompt. Run it once; on the first build
# afterwards macOS asks "codesign wants to access key…" — click "Always Allow" once.
# The cert is untrusted (CSSMERR_TP_NOT_TRUSTED); that's fine — trust only affects Gatekeeper
# verification, not local signing or TCC.
set -euo pipefail

NAME="Swapless Self-Signed"
if security find-identity -p codesigning | grep -q "$NAME"; then
    echo "Identity '$NAME' already present — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Swapless Self-Signed
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf"

# Legacy PBE/MAC so macOS `security import` can read the PKCS12 (OpenSSL 3 default MAC is
# incompatible with Apple's Security framework).
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
    -name "$NAME" -passout pass:swapless-local \
    -legacy -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P swapless-local -A -T /usr/bin/codesign

echo "Created code-signing identity '$NAME'. Next build will prompt once → Always Allow."
