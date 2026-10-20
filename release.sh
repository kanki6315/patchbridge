#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Adapted from Harbor, Cuekeeper and Telemetee release workflows.
# Build, archive and upload Patchbridge to TestFlight in one command.
# Setup: copy .release.env.example to .release.env and fill in your team ID.
# Create the Patchbridge app in App Store Connect with the bundle ID in ios/project.yml.
#
#   ./release.sh                 tests → archive → upload → git tag
#   ./release.sh --skip-tests    (when the test run already passed)
#   ./release.sh --no-upload     archive + export an .ipa, upload nothing
#   ./release.sh --build 42      pick the build number yourself
#   ./release.sh --allow-dirty   release with uncommitted changes (no tag)
#
# Version = MARKETING_VERSION in ios/project.yml. Build = days since 2026-01-01
# plus UTC hour and minute (e.g. 293.18.30), within the 4/2/2 digit limits.
# For another release in the same minute, use --build.
#
# Signing + upload authentication, in order of preference:
#   1. An App Store Connect API key (App Manager role), from .release.env
#      (git-ignored):
#        ASC_KEY_ID=ABC123DEF4
#        ASC_ISSUER_ID=12345678-aaaa-bbbb-cccc-1234567890ab
#        ASC_KEY_PATH=$HOME/.appstoreconnect/private_keys/AuthKey_ABC123DEF4.p8
#      The export is then signed manually with the keychain's Apple Distribution
#      certificate and an App Store profile that asc_profile.py keeps current
#      through the API (with a key, xcodebuild's automatic signing insists on
#      cloud-managed certificates, which need an Admin key).
#   2. Otherwise the Apple ID signed into Xcode (Settings → Accounts) does
#      automatic signing and the upload through -allowProvisioningUpdates.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

run_tests=1
upload=1
allow_dirty=0
build=""
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-tests) run_tests=0 ;;
        --no-upload) upload=0 ;;
        --allow-dirty) allow_dirty=1 ;;
        --build)
            [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || {
                echo "--build requires a numeric build number (e.g. 42)" >&2; exit 2;
            }
            shift; build="$1" ;;
        -h|--help) sed -n '2,/^set -euo pipefail/{ /^set -euo pipefail/d; s/^# \{0,1\}//; p; }' "$here/release.sh"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------

release_env="${RELEASE_ENV_FILE:-$here/.release.env}"
if [ -f "$release_env" ]; then
    # shellcheck disable=SC1091
    set -a; . "$release_env"; set +a
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[ -d "$DEVELOPER_DIR" ] || die "Xcode not found at $DEVELOPER_DIR (set DEVELOPER_DIR)"
command -v xcodegen >/dev/null || die "xcodegen missing: brew install xcodegen"

team="$(sed -n "s/^ *DEVELOPMENT_TEAM: *[\"']\{0,1\}\([A-Z0-9]*\)[\"']\{0,1\} *$/\1/p" ios/project.yml | head -1)"
team="${DEVELOPMENT_TEAM:-$team}"
[ -n "$team" ] || die "DEVELOPMENT_TEAM is empty in ios/project.yml — set it there or in .release.env"

version="$(sed -n "s/^ *MARKETING_VERSION: *[\"']\{0,1\}\([0-9.]*\)[\"']\{0,1\} *$/\1/p" ios/project.yml | head -1)"
[ -n "$version" ] || die "MARKETING_VERSION not found in ios/project.yml"
[ -n "$build" ] || build="$(python3 - <<'BUILD'
import datetime as dt
now = dt.datetime.now(dt.timezone.utc)
print(f"{(now.date() - dt.date(2026, 1, 1)).days + 1}.{now.hour}.{now.minute}")
BUILD
)"
python3 - "$build" <<'BUILD'
import re, sys
if not re.fullmatch(r"[1-9][0-9]{0,3}(\.[0-9]{1,2}){0,2}", sys.argv[1]):
    sys.exit("Build must use up to 4/2/2 digits with a positive first component (e.g. 293.18.30).")
BUILD

dirty=0
if [ -n "$(git status --porcelain -- .)" ]; then
    dirty=1
    [ "$allow_dirty" = 1 ] || die "uncommitted changes in the repository — commit them, or pass --allow-dirty (no tag will be made)"
fi
commit="$(git rev-parse --short HEAD)"

if [ -z "${ASC_KEY_ID:-}" ] && { [ -n "${ASC_ISSUER_ID:-}" ] || [ -n "${ASC_KEY_PATH:-}" ]; }; then
    die "ASC_ISSUER_ID / ASC_KEY_PATH require ASC_KEY_ID"
fi
auth=()
if [ -n "${ASC_KEY_ID:-}" ]; then
    [ -n "${ASC_ISSUER_ID:-}" ] || die "ASC_KEY_ID is set but ASC_ISSUER_ID is not"
    key_path="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
    [ -f "$key_path" ] || die "App Store Connect key not found at $key_path"
    auth=(-authenticationKeyPath "$key_path" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
    auth_note="App Store Connect API key $ASC_KEY_ID, manual signing"
else
    auth_note="the Apple ID signed into Xcode, automatic signing"
fi
bundle_id="$(sed -n "s/^ *PRODUCT_BUNDLE_IDENTIFIER: *[\"']\{0,1\}\([A-Za-z0-9.-]*\)[\"']\{0,1\} *$/\1/p" ios/project.yml | head -1)"
[ -n "$bundle_id" ] || die "PRODUCT_BUNDLE_IDENTIFIER not found in ios/project.yml"
profile_name="Patchbridge App Store"

pretty() { if command -v xcbeautify >/dev/null; then xcbeautify; else cat; fi; }

tag="ios/v$version-$build"
if [ "$upload" = 1 ] && [ "$dirty" = 0 ]; then
    if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
        die "tag $tag already exists — choose a new build number"
    fi
fi

out="build/release/$version-$build"
archive="$out/Patchbridge.xcarchive"
[ ! -e "$out" ] || die "output $out already exists — choose a new build number"
mkdir -p "$out"

log "Patchbridge $version ($build) from $commit · team $team · auth: $auth_note"

# --- Generate + test -------------------------------------------------------

log "xcodegen generate"
xcodegen generate --spec ios/project.yml --quiet
if [ "$dirty" = 0 ] && [ -n "$(git status --porcelain -- .)" ]; then
    die "project generation changed files — review and commit them before releasing"
fi

if [ "$run_tests" = 1 ]; then
    log "Swift core tests"
    swift test --package-path swift 2>&1 | tee "$out/swift-test.log"
    log "Python bridge tests (offline)"
    PYTHONPATH="$here/src${PYTHONPATH:+:$PYTHONPATH}" python3 -m unittest discover -s tests 2>&1 | tee "$out/python-test.log"
    log "iPhone UI tests (simulator)"
    xcodebuild test \
        -project ios/Patchbridge.xcodeproj -scheme Patchbridge \
        -destination "${TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}" \
        -derivedDataPath build/tests \
        CODE_SIGNING_ALLOWED=NO \
        2>&1 | tee "$out/xcodebuild-test.log" | pretty
fi

# --- Archive ---------------------------------------------------------------

log "Archive (Release, generic iOS device)"
xcodebuild archive \
    -project ios/Patchbridge.xcodeproj -scheme Patchbridge -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -derivedDataPath "$out/DerivedData" \
    -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} \
    DEVELOPMENT_TEAM="$team" \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build" \
    2>&1 | tee "$out/archive.log" | pretty

# --- Export / upload -------------------------------------------------------

if [ "$upload" = 1 ]; then destination=upload; else destination=export; fi
if [ ${#auth[@]} -gt 0 ]; then
    log "App Store profile for the keychain's Apple Distribution certificate"
    profile="$(python3 asc_profile.py --key-id "$ASC_KEY_ID" --issuer-id "$ASC_ISSUER_ID" \
        --key-path "$key_path" --team "$team" --bundle-id "$bundle_id" --name "$profile_name")"
else
    profile=""
fi
python3 - "$out/ExportOptions.plist" "$destination" "$team" "$bundle_id" "$profile" <<'PLIST'
import plistlib, sys
path, destination, team, bundle, profile = sys.argv[1:]
options = dict(method="app-store-connect", destination=destination, teamID=team,
               signingStyle="manual" if profile else "automatic", uploadSymbols=True,
               manageAppVersionAndBuildNumber=False)
if profile:
    options.update(signingCertificate="Apple Distribution", provisioningProfiles={bundle: profile})
with open(path, "wb") as stream:
    plistlib.dump(options, stream)
PLIST

if [ "$upload" = 1 ]; then log "Upload to App Store Connect"; else log "Export .ipa"; fi
xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportOptionsPlist "$out/ExportOptions.plist" \
    -exportPath "$out/export" \
    -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} \
    2>&1 | tee "$out/export.log" | pretty

# --- Tag -------------------------------------------------------------------

if [ "$upload" = 1 ] && [ "$dirty" = 0 ]; then
    [ "$(git rev-parse --short HEAD)" = "$commit" ] && [ -z "$(git status --porcelain -- .)" ] \
        || die "upload completed, but checkout changed during release; no tag created"
    git tag -a "$tag" -m "Patchbridge $version ($build)"
    log "Tagged $tag — push it with: git push origin $tag"
fi

log "Done: Patchbridge $version ($build)"
if [ "$upload" = 1 ]; then
    cat <<EOF
App Store Connect is processing the build (usually 5–15 minutes). Then:
  · TestFlight → iOS builds: the build appears under $version; internal groups
    with "automatic distribution" get it without further clicks.
  · Add "What to Test" notes on the build if testers should look at something.
  · Archive kept at $archive (dSYMs inside; keep it until the next release).
EOF
else
    echo ".ipa exported to $out/export/"
fi
