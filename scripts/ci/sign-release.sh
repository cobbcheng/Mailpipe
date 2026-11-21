#!/usr/bin/env bash
# Ephemeral GitHub-hosted runner only. Never touch a developer's login keychain.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted &&
   ${GITHUB_REPOSITORY:-} == cobbcheng/Mailpipe && ${GITHUB_EVENT_NAME:-} == push &&
   ${GITHUB_REF:-} == refs/heads/main ]] || { echo 'Protected main push required' >&2; exit 1; }
: "${APPLE_TEAM_ID:?}" "${APPLE_DEVELOPER_ID_P12_BASE64:?}" "${APPLE_DEVELOPER_ID_P12_PASSWORD:?}"
: "${APPLE_NOTARY_KEY_P8_BASE64:?}" "${APPLE_NOTARY_KEY_ID:?}" "${APPLE_NOTARY_ISSUER_ID:?}" "${SPARKLE_PRIVATE_KEY:?}"
version=$1 build=$2 out=$3
umask 077
tmp=$(mktemp -d "$RUNNER_TEMP/mailpipe-sign.XXXXXXXX")
kc="$tmp/ci.keychain-db"
trap 'security delete-keychain "$kc" >/dev/null 2>&1 || :; rm -rf "$tmp"' EXIT
# Keep long-lived keys/passwords out of argv, build logs, subprocess environments and artifacts.
sparkle_key=$SPARKLE_PRIVATE_KEY
unset SPARKLE_PRIVATE_KEY
notary_key=$APPLE_NOTARY_KEY_P8_BASE64
unset APPLE_NOTARY_KEY_P8_BASE64
printf '%s' "$APPLE_DEVELOPER_ID_P12_BASE64" | base64 -D > "$tmp/input.p12"
unset APPLE_DEVELOPER_ID_P12_BASE64
# Rewrap using a blank import password inside a mode-0700 runner-only directory.
# The first stage decrypts to a pipe, not a plaintext private-key file.
ossl="$(brew --prefix openssl@3)/bin/openssl"
"$ossl" pkcs12 -legacy -in "$tmp/input.p12" -passin env:APPLE_DEVELOPER_ID_P12_PASSWORD -noenc |
  "$ossl" pkcs12 -legacy -export -macalg sha1 -out "$tmp/import.p12" -passout pass:
unset APPLE_DEVELOPER_ID_P12_PASSWORD
pw=$("$ossl" rand -hex 32)
security create-keychain -p "$pw" "$kc"
security set-keychain-settings -lut 3600 "$kc"
security unlock-keychain -p "$pw" "$kc"
security list-keychains -d user -s "$kc"
security import "$tmp/import.p12" -P '' -k "$kc" -T /usr/bin/codesign >&2
security set-key-partition-list -S apple-tool:,apple: -s -k "$pw" "$kc" >/dev/null
unset pw
rm "$tmp/input.p12" "$tmp/import.p12"

derived="$RUNNER_TEMP/mailpipe-release-xcode"
xcodebuild -project Mailpipe.xcodeproj -scheme Mailpipe -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived" -archivePath "$tmp/release.xcarchive" -onlyUsePackageVersionsFromResolvedFile \
  ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' "MARKETING_VERSION=$version" "CURRENT_PROJECT_VERSION=$build" \
  CODE_SIGN_STYLE=Manual 'CODE_SIGN_IDENTITY=Developer ID Application' "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" archive
python3 - "$tmp/export.plist" <<'PY'
import os, plistlib, sys
with open(sys.argv[1], "wb") as p:
    plistlib.dump(dict(method="developer-id", destination="export", signingStyle="manual",
                       manageAppVersionAndBuildNumber=False, signingCertificate="Developer ID Application",
                       teamID=os.environ["APPLE_TEAM_ID"]), p)
PY
xcodebuild -exportArchive -archivePath "$tmp/release.xcarchive" -exportOptionsPlist "$tmp/export.plist" -exportPath "$tmp/export"
app="$tmp/export/Mailpipe.app"
codesign --verify --deep --strict --all-architectures "$app"
python3 scripts/ci/check-bundle.py "$app" "$version" "$build" "$APPLE_TEAM_ID"
ditto -c -k --keepParent --sequesterRsrc "$app" "$tmp/notary.zip"
printf '%s' "$notary_key" | base64 -D > "$tmp/notary.p8"
unset notary_key
xcrun notarytool submit "$tmp/notary.zip" --key "$tmp/notary.p8" --key-id "$APPLE_NOTARY_KEY_ID" \
  --issuer "$APPLE_NOTARY_ISSUER_ID" --wait --timeout 35m --output-format json > "$tmp/notary.json"
rm "$tmp/notary.p8"
python3 - "$tmp/notary.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print("Notarization:", result["status"], "submission:", result["id"])
if result["status"] != "Accepted":
    sys.exit("Apple did not accept this build")
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
codesign --verify --deep --strict --all-architectures "$app"
mkdir "$out"
zip="$out/Mailpipe-$version-build$build-${GITHUB_SHA:0:7}.zip"
ditto -c -k --keepParent --sequesterRsrc "$app" "$zip"
printf '%s' "$sparkle_key" | "$derived/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
  --ed-key-file - -p "$zip" > "$out/signature.txt"
unset sparkle_key
