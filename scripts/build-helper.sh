#!/usr/bin/env bash
# Build + sign SecretsVaultHelper.app — the Developer-ID-signed helper whose iCloud access is
# scoped to its own ubiquity container (no TCC permission of any kind). Requires:
#   * Xcode command line tools (swift)
#   * the "Developer ID Application" signing identity in the login Keychain
#   * a Developer ID provisioning profile carrying the iCloud container entitlements, at
#     ~/Library/Application Support/secrets-vault/secrets-vault-sync.provisionprofile
#     (or pass its path as $1)
#
# Output: ~/Library/Application Support/secrets-vault/SecretsVaultHelper.app
#
# Usage: build-helper.sh [profile.provisionprofile]

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

BUNDLE_ID="com.shamruk.secrets-vault-sync"
CONTAINER_ID="iCloud.com.shamruk.secrets-vault-sync"
TEAM_ID="UA5Q77U2KN"
IDENTITY="Developer ID Application: Siarhei Shamruk ($TEAM_ID)"
STATE_DIR="$HOME/Library/Application Support/secrets-vault"
APP="$STATE_DIR/SecretsVaultHelper.app"
PROFILE="${1:-$STATE_DIR/secrets-vault-sync.provisionprofile}"
SRC="$HERE/helper-src"

[[ -f "$PROFILE" ]] || { echo "provisioning profile not found: $PROFILE" >&2; exit 1; }
security find-identity -v -p codesigning | grep -q "$TEAM_ID" \
  || { echo "signing identity for team $TEAM_ID not found in Keychain" >&2; exit 1; }

echo "building helper..."
swift build -c release --package-path "$SRC" >/dev/null
BIN="$SRC/.build/release/secrets-vault-helper"
[[ -x "$BIN" ]] || { echo "build failed: $BIN missing" >&2; exit 1; }

# bundle version counter (bump every build so NSUbiquitousContainers changes take effect)
verfile="$STATE_DIR/helper-build-number"
mkdir -p "$STATE_DIR"
build=$(( $(cat "$verfile" 2>/dev/null || echo 0) + 1 ))
echo "$build" >"$verfile"

echo "assembling $APP (build $build)..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/secrets-vault-helper"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>SecretsVaultHelper</string>
	<key>CFBundleExecutable</key><string>secrets-vault-helper</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>$build</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSUbiquitousContainers</key>
	<dict>
		<key>$CONTAINER_ID</key>
		<dict>
			<key>NSUbiquitousContainerIsDocumentScopePublic</key><true/>
			<key>NSUbiquitousContainerName</key><string>Secrets Vault</string>
			<key>NSUbiquitousContainerSupportedFolderLevels</key><string>Any</string>
		</dict>
	</dict>
</dict>
</plist>
PLIST

ent="$(mktemp "${TMPDIR:-/tmp}/svh-ent.XXXXXX.plist")"
trap 'rm -f "$ent"' EXIT
cat >"$ent" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.application-identifier</key><string>$TEAM_ID.$BUNDLE_ID</string>
	<key>com.apple.developer.team-identifier</key><string>$TEAM_ID</string>
	<key>com.apple.developer.icloud-container-identifiers</key>
	<array><string>$CONTAINER_ID</string></array>
	<key>com.apple.developer.ubiquity-container-identifiers</key>
	<array><string>$CONTAINER_ID</string></array>
	<key>com.apple.developer.icloud-services</key>
	<array><string>CloudDocuments</string></array>
</dict>
</plist>
ENT

echo "signing with: $IDENTITY"
codesign --force --options runtime --entitlements "$ent" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "built and signed: $APP"
echo "smoke test: $APP/Contents/MacOS/secrets-vault-helper path"
