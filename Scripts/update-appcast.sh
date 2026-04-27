#!/usr/bin/env bash
#
# Adds a new <item> entry to the top of appcast.xml for the current release.
# Inputs come from the release workflow as env vars:
#   VERSION  — semver string (e.g. 0.2.0)
#   BUILD    — integer build number (Sparkle compares this for upgrades)
#   SIG      — Ed25519 signature (may be empty for unsigned dev builds)
#   LEN      — file size in bytes
#   REPO     — owner/repo, e.g. fabio/Agentic-IDE
#   TAG      — git tag, e.g. v0.2.0
#
# The script preserves any existing <item> entries — Sparkle uses them to
# show users a changelog of recent versions.

set -euo pipefail

: "${VERSION:?}"
: "${BUILD:?}"
: "${LEN:?}"
: "${REPO:?}"
: "${TAG:?}"

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/AgenticIDE-${VERSION}.zip"
RELEASE_NOTES_URL="https://github.com/${REPO}/releases/tag/${TAG}"
PUBDATE=$(LC_ALL=en_US.UTF-8 date -u "+%a, %d %b %Y %H:%M:%S +0000")

NEW_ITEM=$(cat <<EOF
        <item>
            <title>Version ${VERSION}</title>
            <link>${RELEASE_NOTES_URL}</link>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:releaseNotesLink>${RELEASE_NOTES_URL}</sparkle:releaseNotesLink>
            <pubDate>${PUBDATE}</pubDate>
            <enclosure
                url="${DOWNLOAD_URL}"
                sparkle:edSignature="${SIG:-}"
                length="${LEN}"
                type="application/octet-stream" />
        </item>
EOF
)

# Bootstrap appcast.xml if missing.
if [ ! -f appcast.xml ]; then
    cat > appcast.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>AgenticIDE</title>
        <description>Updates for AgenticIDE</description>
        <language>en</language>
    </channel>
</rss>
EOF
fi

# Insert the new <item> right after <channel>'s <language> line, ahead of any
# existing <item> blocks. Use python for safer XML editing than sed wizardry.
python3 - <<PY
import re, sys, pathlib

path = pathlib.Path("appcast.xml")
text = path.read_text()
new_item = """${NEW_ITEM}
"""

# Insert immediately after the first </language> line (channel metadata) so
# items always live above any prior items.
pattern = re.compile(r"(</language>\s*\n)", flags=re.MULTILINE)
if pattern.search(text):
    text = pattern.sub(lambda m: m.group(1) + new_item, text, count=1)
else:
    # Fallback: drop it just before </channel>.
    text = text.replace("</channel>", new_item + "    </channel>", 1)

path.write_text(text)
PY

echo "Appended version ${VERSION} to appcast.xml"
