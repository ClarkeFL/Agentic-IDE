#!/usr/bin/env bash
set -euo pipefail

# Fetches a prebuilt GhosttyKit.xcframework from manaflow-ai/ghostty's
# release tarballs, verifies its SHA256 against Scripts/ghosttykit-checksums.txt,
# and unpacks it into Vendor/GhosttyKit.xcframework.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKSUMS_FILE="$REPO_ROOT/Scripts/ghosttykit-checksums.txt"
VENDOR_DIR="$REPO_ROOT/Vendor"
FRAMEWORK_DIR="$VENDOR_DIR/GhosttyKit.xcframework"

if [[ ! -f "$CHECKSUMS_FILE" ]]; then
    echo "error: $CHECKSUMS_FILE not found" >&2
    exit 1
fi

# Last entry in the checksums file is the active pin
read -r GHOSTTY_SHA EXPECTED_SHA256 <<<"$(tail -n 1 "$CHECKSUMS_FILE")"

if [[ -z "${GHOSTTY_SHA:-}" || -z "${EXPECTED_SHA256:-}" ]]; then
    echo "error: could not parse pin from $CHECKSUMS_FILE" >&2
    exit 1
fi

touch_stamp() {
    if [[ -n "${DERIVED_FILE_DIR:-}" ]]; then
        mkdir -p "$DERIVED_FILE_DIR"
        : > "$DERIVED_FILE_DIR/ghosttykit-fetched.stamp"
    fi
}

if [[ -d "$FRAMEWORK_DIR" ]]; then
    PIN_MARKER="$FRAMEWORK_DIR/.ghostty-sha"
    if [[ -f "$PIN_MARKER" ]] && [[ "$(cat "$PIN_MARKER")" == "$GHOSTTY_SHA" ]]; then
        echo "GhosttyKit.xcframework already at $GHOSTTY_SHA — skipping."
        touch_stamp
        exit 0
    fi
fi

mkdir -p "$VENDOR_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE_NAME="GhosttyKit.xcframework.tar.gz"
DOWNLOAD_URL="https://github.com/manaflow-ai/ghostty/releases/download/xcframework-${GHOSTTY_SHA}/${ARCHIVE_NAME}"
ARCHIVE_PATH="$TMP_DIR/$ARCHIVE_NAME"

echo "Downloading $DOWNLOAD_URL ..."
curl --fail --location --retry 10 --retry-delay 5 -o "$ARCHIVE_PATH" "$DOWNLOAD_URL"

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "error: SHA256 mismatch" >&2
    echo "  expected: $EXPECTED_SHA256" >&2
    echo "  actual:   $ACTUAL_SHA256"   >&2
    exit 1
fi

rm -rf "$FRAMEWORK_DIR"
tar --no-same-owner -xzf "$ARCHIVE_PATH" -C "$TMP_DIR"
mv "$TMP_DIR/GhosttyKit.xcframework" "$VENDOR_DIR/"
echo "$GHOSTTY_SHA" > "$FRAMEWORK_DIR/.ghostty-sha"

echo "GhosttyKit.xcframework installed at $FRAMEWORK_DIR (pinned to $GHOSTTY_SHA)."
touch_stamp
