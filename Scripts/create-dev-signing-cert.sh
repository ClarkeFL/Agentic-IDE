#!/usr/bin/env bash
# Creates a self-signed code-signing identity in the login keychain so local
# Debug builds get a stable signing identity. With a stable identity TCC
# permissions (Full Disk Access, Documents, Desktop, Downloads) persist
# across rebuilds and relaunches — ad-hoc (`-`) signing produces a per-binary
# cdhash that macOS can't reliably anchor permissions against.
#
# Idempotent: if "AgenticIDE Dev" already exists in the login keychain,
# this exits without doing anything. Safe to re-run.
#
# Usage:
#   ./Scripts/create-dev-signing-cert.sh
#   xcodegen
#   xcodebuild -project AgenticIDE.xcodeproj -scheme AgenticIDE -configuration Debug build
#
# Release builds (the GitHub Actions tag-push workflow) keep using ad-hoc
# (`-`) — see project.yml's per-config CODE_SIGN_IDENTITY override.
#
# Note on first-run keychain prompts: the first time codesign uses the new
# identity macOS may show "codesign wants to use your confidential
# information" — click "Always Allow" so subsequent builds don't re-prompt.

set -euo pipefail

CN="AgenticIDE Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$CN\""; then
    echo "✓ Code-signing identity '$CN' already in login.keychain — nothing to do."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" << EOF
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_codesign

[ dn ]
CN = $CN
O = Local Dev
C = US

[ v3_codesign ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "→ Generating private key + self-signed cert..."
openssl genrsa -out "$TMP/key.pem" 2048 2>/dev/null
openssl req -new -x509 -key "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.conf" -extensions v3_codesign 2>/dev/null

echo "→ Bundling into PKCS#12..."
# -legacy forces the older PBE encryption that macOS's `security` tool can
# read. Without it, OpenSSL 3+ defaults to a newer PBE that produces a
# valid .p12 but `security import` rejects with "MAC verification failed".
openssl pkcs12 -export -legacy \
    -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" \
    -name "$CN" \
    -password pass:dev 2>/dev/null

echo "→ Importing into login keychain..."
# -T whitelists which binaries can use the key without per-call prompt;
# codesign + security covers normal xcodebuild flow. (The alternative -A
# allows ANY tool to use the key, which is broader than we need.)
security import "$TMP/identity.p12" \
    -k "$KEYCHAIN" \
    -P dev \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

echo "→ Marking cert as trusted for code signing (user-level trust)..."
# Without this the identity exists but `security find-identity -p codesigning`
# rejects it (CSSMERR_TP_NOT_TRUSTED) and Xcode refuses to use it. User-level
# trust doesn't require admin auth — only system-level (-d) does.
security add-trusted-cert -k "$KEYCHAIN" -p codeSign "$TMP/cert.pem"

echo
echo "✓ Imported '$CN' into login.keychain and trusted for code signing"
echo
echo "Next steps:"
echo "  xcodegen"
echo "  xcodebuild -project AgenticIDE.xcodeproj -scheme AgenticIDE -configuration Debug build"
echo
echo "After the first build, codesign may show a 'wants to use confidential"
echo "information' prompt — click 'Always Allow' so it doesn't re-ask."
