#!/usr/bin/env bash
# Generate a self-signed code-signing identity for Release builds in CI.
#
# Why: ad-hoc (`-`) signing produces a different cdhash for every build, and
# macOS TCC anchors privacy grants (Full Disk Access, Documents, Downloads,
# Desktop, Apple Events) to the binary's designated requirement — which for
# ad-hoc includes the cdhash. Result: every Sparkle update looks like a
# fresh app and re-prompts for permissions. Signing with a stable cert
# anchors TCC to the cert instead, so grants persist across updates.
#
# Output: the script writes the .p12 base64 to your clipboard. Paste it
# into a GitHub repo secret named RELEASE_CERT_P12_BASE64. The .p12
# password is hardcoded as "release" — that's fine because the .p12 itself
# is encrypted-at-rest in GitHub Secrets, and the password is not a
# meaningful security boundary on top of that.
#
# Run once. After: every release.yml run signs with this identity.
#
# IMPORTANT migration step: the first release signed with the new cert
# can't be auto-applied by Sparkle (Sparkle refuses updates whose
# Designated Requirement differs from the installed copy). Download the
# .zip from the GitHub release page once and replace /Applications/
# AgenticIDE.app manually. Subsequent updates auto-install fine.

set -euo pipefail

CN="AgenticIDE Release"
P12_PASSWORD="release"

if ! command -v openssl >/dev/null 2>&1; then
    echo "error: openssl not found on PATH" >&2
    exit 1
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
O = Self-Hosted
C = US

[ v3_codesign ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "→ Generating private key + self-signed cert (10-year validity)..."
openssl genrsa -out "$TMP/key.pem" 2048 2>/dev/null
openssl req -new -x509 -key "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.conf" -extensions v3_codesign 2>/dev/null

echo "→ Bundling into PKCS#12..."
# -legacy: macOS's `security import` (and openssl 3+'s default) disagree on
# PBE algorithms. -legacy uses the older PBE everyone reads.
openssl pkcs12 -export -legacy \
    -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" \
    -name "$CN" \
    -password "pass:$P12_PASSWORD" 2>/dev/null

echo "→ Base64-encoding for GitHub secret..."
B64=$(base64 < "$TMP/identity.p12")

if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$B64" | pbcopy
    echo "✓ Base64 .p12 copied to clipboard."
    CLIPBOARD_NOTE="(already on your clipboard)"
else
    OUT="$HOME/agenticide-release-cert.p12.b64"
    printf '%s' "$B64" > "$OUT"
    echo "✓ Base64 .p12 written to $OUT"
    CLIPBOARD_NOTE="(read it from $OUT)"
fi

cat <<NEXT

Next steps:
  1. Open https://github.com/ClarkeFL/Agentic-IDE/settings/secrets/actions
  2. Click "New repository secret":
       Name:  RELEASE_CERT_P12_BASE64
       Value: paste the base64 $CLIPBOARD_NOTE
  3. Save.

That's it — the next tag push will build with the new identity.

After the first release signed with this cert:
  - Sparkle will refuse to auto-apply it (Designated Requirement mismatch
    with the installed ad-hoc-signed copy).
  - Download the new .zip from the GitHub release page once, drag the
    .app into /Applications replacing the existing one, and re-grant TCC
    permissions one final time.
  - From then on, Sparkle updates apply silently and TCC grants persist.

To rotate the cert later: run this script again. The new cert invalidates
every installed copy (same one-time clean install required), so only do it
if the cert is compromised or you're moving to a real Developer ID.
NEXT
