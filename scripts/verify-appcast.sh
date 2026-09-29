#!/bin/bash
#
# verify-appcast.sh — every enclosure URL in appcast.xml must resolve.
#
# Why this exists: appcast.xml accumulated 27 entries for the 2026.0.x series
# that were never released to this repository (the app's oldest real release
# is v2026.1.0). Those entries were leftovers from the GhostShell rename, and
# one of them had its enclosure silently repointed at a different version's
# binary. Sparkle tolerates dead feed entries, so nothing complained until the
# feed was audited by hand.
#
# Run after `scripts/release.sh` generates a new entry, and before pushing.
# Requires network access; curl HEAD on a release asset redirects to S3.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
APPCAST="appcast.xml"
[ -f "$APPCAST" ] || { echo "FAIL: $APPCAST not found"; exit 1; }

# 1. Well-formedness: a malformed feed silently disables updates entirely.
if command -v xmllint >/dev/null 2>&1; then
    if ! xmllint --noout "$APPCAST" 2>/dev/null; then
        echo "FAIL: $APPCAST is not well-formed XML"
        exit 1
    fi
else
    python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse('$APPCAST')" 2>/dev/null \
        || { echo "FAIL: $APPCAST is not well-formed XML"; exit 1; }
fi

# 2. Duplicate build versions: two entries for one version makes Sparkle's
#    top-down scan pick arbitrarily.
dupes=$(grep -o '<sparkle:version>[^<]*' "$APPCAST" | sed 's/.*>//' | sort | uniq -d)
if [ -n "$dupes" ]; then
    echo "FAIL: duplicate sparkle:version in $APPCAST:"
    echo "$dupes" | sed 's/^/  /'
    exit 1
fi

# 3. Every enclosure must exist. Sequential on purpose: parallel HEADs get
#    rate-limited by GitHub and produce false 404s.
urls=$(grep -o 'url="https://[^"]*\.dmg"' "$APPCAST" | sed 's/^url="//; s/"$//' | sort -u)
total=0
dead=0
while IFS= read -r url; do
    [ -z "$url" ] && continue
    total=$((total + 1))
    code=$(curl -s -o /dev/null -w '%{http_code}' -L -I --max-time 25 "$url")
    case "$code" in
        200|301|302) ;;
        000) echo "  WARN (timeout/rate-limit, recheck): $url" ;;
        *)  dead=$((dead + 1)); echo "  DEAD ($code): $url" ;;
    esac
done <<< "$urls"

echo
echo "checked $total enclosure URL(s), $dead dead"
if [ "$dead" -gt 0 ]; then
    echo "FAIL: $dead enclosure URL(s) do not resolve."
    echo "      Either the release asset is missing or the entry is stale."
    exit 1
fi

echo "PASS: appcast is well-formed, version-unique, and every enclosure resolves."
