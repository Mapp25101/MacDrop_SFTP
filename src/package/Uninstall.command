#!/bin/bash
# Completely uninstalls SFTP Drive from this Mac (just double-click).
# Files on the servers stay untouched.
#   --yes  = answer yes to everything (also delete local copies and the rclone/fswatch tools)

YES=0; [ "${1:-}" = "--yes" ] && YES=1
ask() { # question → 0 = yes
  [ $YES = 1 ] && return 0
  [ -t 0 ] || return 1
  local a; read -r -p "$1 [y/N]: " a
  case "$a" in y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}
done_() { printf '  ✔ %s\n' "$1"; }

echo "=== SFTP Drive – uninstall ==="
UIDN=$(id -u)

# 1) quit all running copies of the app
pkill -f "SFTP Drive.app/Contents/MacOS/SFTPDrive" 2>/dev/null && done_ "app quit"

# 1b) switch off the Finder extension
/usr/bin/pluginkit -e ignore -i cz.sftpdrive.app.finder 2>/dev/null
for a in "/Applications/SFTP Drive.app" "$HOME/Applications/SFTP Drive.app"; do
  [ -d "$a/Contents/PlugIns/SFTPDriveFinder.appex" ] && /usr/bin/pluginkit -r "$a/Contents/PlugIns/SFTPDriveFinder.appex" 2>/dev/null
done
pkill -f SFTPDriveFinder 2>/dev/null

# 2) stop the background services (sync, online folders)
for f in "$HOME"/Library/LaunchAgents/cz.sftpdrive.*.plist; do
  [ -e "$f" ] || continue
  launchctl bootout "gui/$UIDN/$(basename "$f" .plist)" 2>/dev/null
  rm -f "$f"
done
pkill -f "sftpdrive _daemon" 2>/dev/null
pkill -f "sftpdrive _mount" 2>/dev/null
done_ "background services stopped"

# 3) unmount online folders
mount | grep " on $HOME/SFTP/" | sed -E 's/^.* on (.*) \([^)]*\)$/\1/' | while IFS= read -r m; do
  umount "$m" 2>/dev/null || umount -f "$m" 2>/dev/null || diskutil unmount force "$m" >/dev/null 2>&1
done
pkill -f "rclone nfsmount .*$HOME/SFTP/" 2>/dev/null
pkill -f "rclone bisync .*/SFTP/" 2>/dev/null
done_ "online folders unmounted"

# 4) passwords from the Keychain
security dump-keychain 2>/dev/null | grep -o '"svce"<blob>="sftpdrive:[^"]*"' | sed 's/.*="//; s/"$//' | sort -u |
while IFS= read -r svc; do
  while security delete-generic-password -s "$svc" >/dev/null 2>&1; do :; done
done
done_ "passwords removed from the Keychain"

# 5) settings, logs, cache, old Quick Actions, the sftpdrive command
rm -rf "$HOME/.config/sftpdrive" "$HOME/Library/Logs/sftpdrive" "$HOME/Library/Caches/sftpdrive" \
       "$HOME/.local/bin/sftpdrive" "$HOME/.local/bin/sftpdrive-tag" "$HOME/Library/Services/SFTP – "*.workflow
/System/Library/CoreServices/pbs -update >/dev/null 2>&1
defaults delete cz.sftpdrive.app >/dev/null 2>&1
rm -f "$HOME"/Library/Preferences/cz.sftpdrive.*.plist
[ -f "$HOME/.zprofile" ] && perl -0pi -e 's/\n# sftpdrive\nexport PATH="\$HOME\/.local\/bin:\$PATH"\n//' "$HOME/.zprofile"
done_ "settings, logs and Quick Actions deleted"

# 6) the folder with the synced files (~/SFTP Drive, ~/SFTP in older versions)
for D in "$HOME/SFTP Drive" "$HOME/SFTP"; do
  [ -d "$D" ] || continue
  only_junk=1   # is there anything in the folder besides .DS_Store and the folder icon?
  for e in "$D"/* "$D"/.[!.]* "$D"/..?*; do
    [ -e "$e" ] || continue
    case "${e##*/}" in .DS_Store|Icon$'\r') ;; *) only_junk=0; break ;; esac
  done
  if [ $only_junk = 1 ]; then
    rm -rf "$D"; done_ "folder $(basename "$D") deleted (it was empty)"
  elif ask "The folder $(basename "$D") contains downloaded files (they stay on the server). Move it to the Trash?"; then
    mv "$D" "$HOME/.Trash/$(basename "$D") $(date +%H%M%S)" && done_ "folder $(basename "$D") is in the Trash"
  else
    echo "  – folder $(basename "$D") stays (no longer synced)"
  fi
done

# 7) the app from Applications to the Trash
for a in "/Applications/SFTP Drive.app" "$HOME/Applications/SFTP Drive.app"; do
  [ -d "$a" ] && mv "$a" "$HOME/.Trash/SFTP Drive $(date +%H%M%S).app" && done_ "app moved to the Trash"
done

# 8) helper tools
if ask "Also remove the helper tools rclone and fswatch (installed for SFTP Drive)?"; then
  command -v brew >/dev/null 2>&1 && brew uninstall rclone fswatch >/dev/null 2>&1
  rm -f "$HOME/.local/bin/rclone"
  rm -rf "$HOME/Library/Caches/rclone" "$HOME/.config/rclone"
  done_ "rclone and fswatch removed"
fi

echo
echo "Done – SFTP Drive is uninstalled. Data on the servers is untouched."
[ -t 0 ] && [ $YES = 0 ] && read -r -p "You can close this window (Enter)." _
exit 0
