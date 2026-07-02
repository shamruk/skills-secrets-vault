#!/usr/bin/env bash
# Background iCloud-mirror agent. Keeps the vault's durability copy fresh even when every
# vault-writing process is blocked from iCloud Drive (macOS grants that access per app, and
# headless/sandboxed processes are silently denied).
#
# Why an .app: macOS only shows permission prompts for real app bundles — a bash LaunchAgent
# is denied silently. `install` compiles a tiny local applet (SecretsVaultSync.app) that runs
# vault-sync.sh; on its first iCloud access macOS shows a normal on-screen prompt with the
# app's name (click Allow once). If syncing still fails, the applet shows an on-screen dialog
# (at most once per 6h) with an Open Settings button — problems land on the screen, not in logs.
#
# Two agent flavors, best available wins at install time:
#   1. helper mode — SecretsVaultHelper.app (Developer-ID-signed, syncs into its own iCloud
#      container, zero TCC). Used when the app exists or build-helper.sh can produce it.
#   2. applet mode — the osacompile applet + iCloud Drive folder (needs one Files & Folders
#      grant). Fallback for Macs without the signing cert/profile.
#
# Usage: vault-agent.sh install | status | uninstall

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/kc-lib.sh"

LABEL="dev.secrets-vault.sync"
STATE_DIR="$HOME/Library/Application Support/secrets-vault"
APP="$STATE_DIR/SecretsVaultSync.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/secrets-vault-sync.log"
SYNC="$KC_HERE/vault-sync.sh"

CMD="${1:-}"
case "$CMD" in install|status|uninstall) ;; *) echo "usage: $0 install|status|uninstall" >&2; exit 2 ;; esac

agent_bootout() { launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true; }

if [[ "$CMD" == "uninstall" ]]; then
  agent_bootout
  rm -f "$PLIST"
  rm -rf "$APP"
  echo "agent uninstalled (log kept at $LOG; SecretsVaultHelper.app kept if present)"
  exit 0
fi

if [[ "$CMD" == "status" ]]; then
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    if [[ -f "$PLIST" ]] && grep -q "SecretsVaultHelper" "$PLIST"; then
      echo "agent: loaded ($LABEL, helper mode — own iCloud container, no permissions)"
    else
      echo "agent: loaded ($LABEL, applet mode — iCloud Drive folder)"
    fi
  else echo "agent: NOT LOADED — run vault-agent.sh install"; fi
  if [[ -f "$STATE_DIR/last-sync" ]]; then
    last="$(cat "$STATE_DIR/last-sync")"; now="$(date +%s)"
    echo "last successful sync: $(( (now - last) / 60 )) min ago ($(date -r "$last" '+%Y-%m-%d %H:%M:%S'))"
  else
    echo "last successful sync: never"
  fi
  if [[ -f "$VAULT_DIR/.mirror-pending" ]]; then echo "mirror: PENDING (unsynced local changes)"
  else echo "mirror: up to date"; fi
  [[ -f "$LOG" ]] && { echo "recent log ($LOG):"; tail -n 5 "$LOG" | sed 's/^/  /'; }
  exit 0
fi

# ---- install -------------------------------------------------------------------

[[ -d "$VAULT_DIR" ]] || { echo "no vault at $VAULT_DIR — run vault-init.sh first" >&2; exit 1; }
mkdir -p "$STATE_DIR" "$(dirname "$PLIST")" "$(dirname "$LOG")"

# Prefer the signed helper (own iCloud container, zero TCC); build it if possible.
agent_bin=""; agent_args=""
if hb="$(_helper_bin)"; then
  agent_bin="$hb"; agent_args="<string>sync</string>"
elif [[ -f "$STATE_DIR/secrets-vault-sync.provisionprofile" ]] \
     && security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  echo "building signed helper (profile + identity found)..."
  if "$KC_HERE/build-helper.sh" && hb="$(_helper_bin)"; then
    agent_bin="$hb"; agent_args="<string>sync</string>"
  else
    echo "helper build failed — falling back to the applet" >&2
  fi
fi

if [[ -n "$agent_bin" ]]; then
  agent_bootout
  cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$agent_bin</string>$agent_args</array>
	<key>WatchPaths</key>
	<array><string>$VAULT_DIR</string></array>
	<key>RunAtLoad</key><true/>
	<key>StartInterval</key><integer>3600</integer>
	<key>ThrottleInterval</key><integer>60</integer>
	<key>StandardOutPath</key><string>$LOG</string>
	<key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  launchctl kickstart "gui/$(id -u)/$LABEL" || true
  echo "agent installed in HELPER mode:"
  echo "  app     ${agent_bin%/Contents/MacOS/*}"
  echo "  mirror  its own iCloud container ('Secrets Vault' folder in iCloud Drive)"
  echo "  watches $VAULT_DIR (any vault write triggers a sync; hourly otherwise)"
  echo "  log     $LOG"
  echo "No permission prompts — the helper is scoped to its own container."
  exit 0
fi

# ---- fallback: AppleScript applet + iCloud Drive folder --------------------------

command -v osacompile >/dev/null || { echo "osacompile not found (macOS required)" >&2; exit 1; }

# The applet: run the sync; on failure nag with an on-screen dialog at most once per 6h.
src="$(mktemp "${TMPDIR:-/tmp}/svs.XXXXXX.applescript")"
trap 'rm -f "$src"' EXIT
cat >"$src" <<APPLESCRIPT
on run
	set syncScript to "$SYNC"
	set stateDir to "$STATE_DIR"
	try
		do shell script "/bin/bash " & quoted form of syncScript & " --agent"
	on error errMsg
		set nagFile to stateDir & "/last-nag"
		set nowSecs to (do shell script "date +%s") as integer
		set lastNag to 0
		try
			set lastNag to (do shell script "cat " & quoted form of nagFile) as integer
		end try
		if (nowSecs - lastNag) > 21600 then
			do shell script "mkdir -p " & quoted form of stateDir & " && date +%s > " & quoted form of nagFile
			set msg to "iCloud backup of your secrets vault is not updating." & return & return & "Your secrets are safe on this Mac (~/.secrets-vault); only the backup copy is stale." & return & return & "If macOS asked for permission, click Allow. Otherwise check: System Settings > Privacy & Security > Files & Folders > SecretsVaultSync > iCloud Drive."
			set btn to button returned of (display dialog msg with title "secrets-vault" buttons {"Later", "Open Settings"} default button "Open Settings" with icon caution giving up after 600)
			if btn is "Open Settings" then
				do shell script "open 'x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders'"
			end if
		end if
	end try
end run
APPLESCRIPT

agent_bootout
rm -rf "$APP"
osacompile -o "$APP" "$src"
# background app: no Dock icon, stable identity for the permission grant
plutil -replace LSUIElement -bool true "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$LABEL" "$APP/Contents/Info.plist"
codesign --force -s - "$APP" 2>/dev/null || true

applet_bin="$APP/Contents/MacOS/applet"
[[ -x "$applet_bin" ]] || applet_bin="$(find "$APP/Contents/MacOS" -type f -perm +111 | head -n1)"
[[ -n "$applet_bin" ]] || { echo "applet build failed (no executable in $APP)" >&2; exit 1; }

cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$applet_bin</string></array>
	<key>WatchPaths</key>
	<array><string>$VAULT_DIR</string></array>
	<key>RunAtLoad</key><true/>
	<key>StartInterval</key><integer>3600</integer>
	<key>ThrottleInterval</key><integer>60</integer>
	<key>StandardOutPath</key><string>$LOG</string>
	<key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart "gui/$(id -u)/$LABEL" || true

echo "agent installed and started:"
echo "  app     $APP"
echo "  watches $VAULT_DIR (any vault write triggers a sync; hourly otherwise)"
echo "  log     $LOG"
echo ""
echo "If macOS shows a permission prompt for SecretsVaultSync, click Allow — that's the"
echo "one-time grant. If backups stay blocked, the app shows an on-screen dialog with an"
echo "'Open Settings' button instead of failing silently. Check anytime: vault-agent.sh status"
