#!/bin/bash
# Bonk macOS release pipeline: build (arm64+x86_64) -> DMG -> sign -> verify
# -> appcast.xml -> GitHub Release (--latest) -> post-release verification.
#
# Any phase failing aborts the whole run with "FAIL: <reason>".
# Only a final "PASS" line means the release is complete.
# Re-running is safe: preconditions abort before any side effect if the
# version is already in appcast.xml or the GitHub Release already exists.
#
# Usage:
#   ./scripts/release.sh <VERSION> [--notes-file PATH] [--allow-cjk]
# Example:
#   ./scripts/release.sh 2026.4.5
#
# Preconditions (done by caller, NOT by this script):
#   - feature code committed; MARKETING_VERSION + CURRENT_PROJECT_VERSION
#     already bumped in Bonk.xcodeproj/project.pbxproj
#   - release notes written (English-only, see .agents/skills/release-notes)
set -uo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
phase() { echo "==> $*"; }

VERSION=""
NOTES_FILE=""
ALLOW_CJK=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes-file=*) NOTES_FILE="${1#--notes-file=}"; shift;;
        --notes-file) [[ $# -ge 2 ]] || die "--notes-file needs a value"; NOTES_FILE="$2"; shift 2;;
        --allow-cjk) ALLOW_CJK=1; shift;;
        -*) die "unknown argument: $1";;
        *) [[ -z "$VERSION" ]] || die "too many positional arguments"; VERSION="$1"; shift;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || die "cannot cd to repo root"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bad VERSION '$VERSION' (want YEAR.MONTH.PATCH, e.g. 2026.4.5)"
TAG="v$VERSION"
[[ -z "$NOTES_FILE" ]] && NOTES_FILE="/tmp/release_notes_${VERSION//./}.md"
ARM_DMG="/tmp/Bonk-${VERSION}-arm64.dmg"
X64_DMG="/tmp/Bonk-${VERSION}-x86_64.dmg"

# ---------- P0: preconditions (no side effects beyond checks) ----------
phase "P0 preconditions"
[[ -f Bonk.xcodeproj/project.pbxproj && -f appcast.xml && -f Bonk/Info.plist ]] \
    || die "must run from repo root (Bonk.xcodeproj/appcast.xml/Bonk/Info.plist missing)"

# NOTE: scoped to the app target (JoyLiam.Bonk); a bare grep -m1 would hit
# the BonkTests target first (MARKETING_VERSION=1.0 there).
VERINFO="$(python3 - <<'EOF'
import re, sys
text = open("Bonk.xcodeproj/project.pbxproj", encoding="utf-8").read()
found = {}
for chunk in text.split("isa = XCBuildConfiguration;")[1:]:
    if "PRODUCT_BUNDLE_IDENTIFIER = JoyLiam.Bonk;" not in chunk:
        continue
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION", "MACOSX_DEPLOYMENT_TARGET"):
        m = re.search(r"%s = ([^;]+);" % key, chunk)
        if m:
            found.setdefault(key, set()).add(m.group(1).strip())
for key, vals in found.items():
    if len(vals) != 1:
        sys.exit("<%s> disagrees across Debug/Release: %s" % (key, vals))
try:
    print(found["MARKETING_VERSION"].pop(), found["CURRENT_PROJECT_VERSION"].pop(),
          found["MACOSX_DEPLOYMENT_TARGET"].pop())
except KeyError as e:
    sys.exit("missing %s in app target" % e)
EOF
)" || die "cannot parse project.pbxproj"
read -r MKT CODE MIN_OS <<< "$VERINFO"
[[ -n "${MKT:-}" && -n "${CODE:-}" && -n "${MIN_OS:-}" ]] || die "cannot parse project.pbxproj"
[[ "$MKT" == "$VERSION" ]] || die "MARKETING_VERSION=$MKT != $VERSION (bump both versions first)"
[[ "$CODE" =~ ^[0-9]+$ ]] || die "CURRENT_PROJECT_VERSION=$CODE is not numeric"

TOP_CODE="$(grep -m1 '<sparkle:version>' appcast.xml | sed 's/.*<sparkle:version>//;s/<.*//')"
[[ "$TOP_CODE" =~ ^[0-9]+$ ]] || die "cannot read top sparkle:version from appcast.xml"
[[ "$CODE" -gt "$TOP_CODE" ]] || die "CURRENT_PROJECT_VERSION=$CODE not newer than appcast top=$TOP_CODE"

grep -q "<title>$VERSION</title>" appcast.xml \
    && die "$VERSION already in appcast.xml (remove that <item> or bump version)"
grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" appcast.xml \
    && die "$VERSION already in appcast.xml (remove that <item> or bump version)"

[[ -f "$NOTES_FILE" && -s "$NOTES_FILE" ]] || die "notes file missing/empty: $NOTES_FILE"
if [[ "$ALLOW_CJK" -eq 0 ]]; then
    python3 - "$NOTES_FILE" <<'EOF' || die "notes contain CJK text (English-only; or pass --allow-cjk)"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
if re.search(r"[\u4e00-\u9fff\uf900-\ufaff]", text):
    sys.exit(1)
EOF
fi
BULLETS="$(grep -c '^- ' "$NOTES_FILE" || true)"
[[ "$BULLETS" -gt 6 ]] && echo "WARN: $BULLETS bullets in notes (convention is 3-6)"

for tool in xcodebuild hdiutil gh swift python3 curl; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done
gh auth status >/dev/null 2>&1 || die "gh not authenticated"

SIGN_UPDATE=""
for cand in "${SIGN_UPDATE_BIN:-}" \
    "$(dirname "$(xcode-select -p)")/usr/local/bin/sign_update" \
    $HOME/Library/Developer/Xcode/DerivedData/Bonk-*/SourcePackages/checkouts/Sparkle/sign_update \
    /tmp/BonkBuild-*/SourcePackages/checkouts/Sparkle/sign_update; do
    [[ -x "$cand" ]] && { SIGN_UPDATE="$cand"; break; }
done
[[ -n "$SIGN_UPDATE" ]] || die "sign_update binary not found (build it: make -C <Sparkle checkout>)"
echo "    sign_update: $SIGN_UPDATE"

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
    || die "cannot determine repo (gh repo view failed)"
gh release view "$TAG" >/dev/null 2>&1 \
    && die "GitHub Release $TAG already exists (delete it first or bump version)"

PUBKEY="$(python3 -c "import plistlib;print(plistlib.load(open('Bonk/Info.plist','rb'))['SUPublicEDKey'])")" \
    || die "cannot read SUPublicEDKey from Bonk/Info.plist"
[[ -n "$PUBKEY" ]] || die "SUPublicEDKey empty"

echo "    VERSION=$VERSION CODE=$CODE MIN_OS=$MIN_OS REPO=$REPO"

# ---------- helpers ----------
build_arch() { # $1 = arm64|x86_64, $2 = extra xcodebuild args ("clean" or "")
    local arch="$1" extra="$2"
    phase "build $arch"
    # shellcheck disable=SC2086
    xcodebuild -scheme Bonk -configuration Release -derivedDataPath build \
        $extra build ARCHS="$arch" ONLY_ACTIVE_ARCH=NO 2>&1 | tail -5
    [[ "${PIPESTATUS[0]}" -eq 0 ]] || die "xcodebuild $arch failed"
    [[ -d build/Build/Products/Release/Bonk.app ]] || die "Bonk.app missing after $arch build"
    local short buildv
    short="$(python3 -c "import plistlib;print(plistlib.load(open('build/Build/Products/Release/Bonk.app/Contents/Info.plist','rb'))['CFBundleShortVersionString'])")"
    buildv="$(python3 -c "import plistlib;print(plistlib.load(open('build/Build/Products/Release/Bonk.app/Contents/Info.plist','rb'))['CFBundleVersion'])")"
    [[ "$short" == "$VERSION" && "$buildv" == "$CODE" ]] \
        || die "built app is $short ($buildv), want $VERSION ($CODE): stale build?"
}

make_dmg() { # $1 = arm64|x86_64, $2 = output dmg
    local arch="$1" dmg="$2"
    phase "dmg $arch"
    rm -rf /tmp/dmg && mkdir -p /tmp/dmg || die "cannot stage /tmp/dmg"
    cp -R build/Build/Products/Release/Bonk.app /tmp/dmg/ || die "copy Bonk.app failed"
    ln -s /Applications /tmp/dmg/Applications || die "Applications symlink failed"
    [[ -L /tmp/dmg/Applications ]] || die "/tmp/dmg/Applications symlink missing"
    hdiutil create -volname "Bonk" -srcfolder /tmp/dmg -ov -format UDZO \
        -imagekey zlib-level=9 "$dmg" >/dev/null || die "hdiutil $arch failed"
    [[ -f "$dmg" ]] || die "$dmg not created"
    rm -rf /tmp/dmg
}

verify_sig() { # $1 = dmg, $2 = base64 edSignature
    local dmg="$1" sig="$2" vf
    vf="$(mktemp -d)/verify.swift"
    cat >"$vf" <<'EOF'
import CryptoKit
import Foundation
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let sigData = Data(base64Encoded: CommandLine.arguments[2])!
let pubData = Data(base64Encoded: CommandLine.arguments[3])!
let pub = try Curve25519.Signing.PublicKey(rawRepresentation: pubData)
print(pub.isValidSignature(sigData, for: data) ? "VALID" : "INVALID")
EOF
    [[ "$(swift "$vf" "$dmg" "$sig" "$PUBKEY")" == "VALID" ]] || die "edSignature INVALID for $dmg"
    rm -f "$vf"
}

# ---------- P1-P4: build + dmg ----------
build_arch arm64 clean
make_dmg arm64 "$ARM_DMG"
build_arch x86_64 ""
make_dmg x86_64 "$X64_DMG"

# ---------- P5: sign (once; output used verbatim downstream) ----------
phase "sign"
ARM_OUT="$("$SIGN_UPDATE" "$ARM_DMG" 2>&1)" || die "sign_update arm64 failed: $ARM_OUT"
X64_OUT="$("$SIGN_UPDATE" "$X64_DMG" 2>&1)" || die "sign_update x86_64 failed: $X64_OUT"
ARM_SIG="$(echo "$ARM_OUT" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
ARM_LEN="$(echo "$ARM_OUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
X64_SIG="$(echo "$X64_OUT" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
X64_LEN="$(echo "$X64_OUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
[[ -n "$ARM_SIG" && -n "$ARM_LEN" && -n "$X64_SIG" && -n "$X64_LEN" ]] \
    || die "cannot parse sign_update output: [$ARM_OUT] [$X64_OUT]"
[[ "$(stat -f %z "$ARM_DMG")" == "$ARM_LEN" ]] || die "arm64 length changed after signing (re-run)"
[[ "$(stat -f %z "$X64_DMG")" == "$X64_LEN" ]] || die "x86_64 length changed after signing (re-run)"

# ---------- P6: verify (same files, same signatures — never re-sign to compare) ----------
phase "verify signatures"
verify_sig "$ARM_DMG" "$ARM_SIG"
verify_sig "$X64_DMG" "$X64_SIG"

# ---------- P7: appcast.xml ----------
phase "appcast.xml"
cp appcast.xml "/tmp/appcast.xml.bak-${VERSION}" || die "cannot back up appcast.xml"
PUBDATE="$(TZ=Asia/Shanghai date '+%a, %d %b %Y %T %z')"
export VERSION CODE MIN_OS REPO PUBDATE NOTES_FILE ARM_SIG ARM_LEN X64_SIG X64_LEN
python3 - <<'EOF' || die "appcast.xml update failed"
import os, xml.etree.ElementTree as ET
v, code = os.environ["VERSION"], os.environ["CODE"]
notes = open(os.environ["NOTES_FILE"], encoding="utf-8").read().strip()
base = "https://github.com/%s/releases/download/v%s/Bonk-%s-%s.dmg" % (
    os.environ["REPO"], v, v, "%s")
item = """<item>
        <title>%(v)s</title>
        <pubDate>%(date)s</pubDate>
        <sparkle:version>%(code)s</sparkle:version>
        <sparkle:shortVersionString>%(v)s</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>%(minos)s</sparkle:minimumSystemVersion>
        <description><![CDATA[
%(notes)s
        ]]></description>
        <enclosure
            url="%(arm_url)s"
            length="%(arm_len)s"
            type="application/octet-stream"
            sparkle:edSignature="%(arm_sig)s"
            sparkle:os="macos"
            sparkle:cpuAffinity="arm64"
        />
        <enclosure
            url="%(x64_url)s"
            length="%(x64_len)s"
            type="application/octet-stream"
            sparkle:edSignature="%(x64_sig)s"
            sparkle:os="macos"
            sparkle:cpuAffinity="x86_64"
        />
    </item>
    """ % {"v": v, "date": os.environ["PUBDATE"], "code": code,
           "minos": os.environ["MIN_OS"], "notes": notes,
           "arm_url": base % "arm64", "arm_len": os.environ["ARM_LEN"],
           "arm_sig": os.environ["ARM_SIG"],
           "x64_url": base % "x86_64", "x64_len": os.environ["X64_LEN"],
           "x64_sig": os.environ["X64_SIG"]}
text = open("appcast.xml", encoding="utf-8").read()
assert "<title>%s</title>" % v not in text, "version already present"
idx = text.find("<item>")
assert idx > 0, "no <item> found"
open("appcast.xml", "w", encoding="utf-8").write(text[:idx] + item + text[idx:])
ET.parse("appcast.xml")  # well-formedness gate
again = open("appcast.xml", encoding="utf-8").read()
assert again.count("<title>%s</title>" % v) == 1, "duplicate insert"
EOF

# ---------- P8: GitHub Release ----------
phase "github release"
gh release create "$TAG" "$ARM_DMG" "$X64_DMG" \
    --title "Bonk $TAG" --latest --notes-file "$NOTES_FILE" \
    || die "gh release create failed"

# ---------- P9: post-release verification (release is NOT done without this) ----------
phase "post-release verification"
[[ "$(gh release view "$TAG" --json isDraft --jq .isDraft)" == "false" ]] \
    || die "$TAG is a Draft (run: gh release edit $TAG --draft=false --latest)"
[[ "$(gh api "repos/$REPO/releases/latest" --jq .tag_name)" == "$TAG" ]] \
    || die "$TAG is not the latest release"
for arch in arm64 x86_64; do
    url="https://github.com/$REPO/releases/download/$TAG/Bonk-${VERSION}-${arch}.dmg"
    case "$arch" in
        arm64) want="$ARM_LEN" ;;
        x86_64) want="$X64_LEN" ;;
    esac
    got="$(curl -fSL -o /dev/null -w "%{size_download}" "$url")" \
        || die "download failed: $url"
    [[ "$got" == "$want" ]] || die "$arch size $got != $want"
    echo "    $arch: http=200 size=$got"
done

# Whole-feed audit: every historical entry must still resolve. A stale entry
# once shipped 27 versions that were never released, and a renamed binary
# went unnoticed because Sparkle tolerates dead items.
phase "appcast feed audit"
./scripts/verify-appcast.sh || die "appcast feed audit failed (see dead entries above)"

echo "PASS: $TAG released and verified: https://github.com/$REPO/releases/tag/$TAG"
