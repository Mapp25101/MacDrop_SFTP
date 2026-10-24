#!/bin/bash
# Úplně odinstaluje SFTP Drive z tohoto Macu (stačí dvakrát kliknout).
# Soubory na serverech zůstanou beze změny.
#   --yes  = na všechno odpovědět ano (smazat i offline kopie a nástroje rclone/fswatch)

YES=0; [ "${1:-}" = "--yes" ] && YES=1
ask() { # otázka → 0 = ano
  [ $YES = 1 ] && return 0
  [ -t 0 ] || return 1
  local a; read -r -p "$1 [a/N]: " a
  case "$a" in a|A|ano|y|Y) return 0 ;; *) return 1 ;; esac
}
done_() { printf '  ✔ %s\n' "$1"; }

echo "=== SFTP Drive – odinstalace ==="
UIDN=$(id -u)

# 1) ukončit všechny spuštěné kopie aplikace
pkill -f "SFTP Drive.app/Contents/MacOS/SFTPDrive" 2>/dev/null && done_ "aplikace ukončena"

# 1b) vypnout rozšíření Finderu (ikonky u souborů)
/usr/bin/pluginkit -e ignore -i cz.sftpdrive.app.finder 2>/dev/null
for a in "/Applications/SFTP Drive.app" "$HOME/Applications/SFTP Drive.app"; do
  [ -d "$a/Contents/PlugIns/SFTPDriveFinder.appex" ] && /usr/bin/pluginkit -r "$a/Contents/PlugIns/SFTPDriveFinder.appex" 2>/dev/null
done
pkill -f SFTPDriveFinder 2>/dev/null

# 2) zastavit služby na pozadí (synchronizace, online složky)
for f in "$HOME"/Library/LaunchAgents/cz.sftpdrive.*.plist; do
  [ -e "$f" ] || continue
  launchctl bootout "gui/$UIDN/$(basename "$f" .plist)" 2>/dev/null
  rm -f "$f"
done
pkill -f "sftpdrive _daemon" 2>/dev/null
pkill -f "sftpdrive _mount" 2>/dev/null
done_ "služby na pozadí zastaveny"

# 3) odpojit online složky
mount | grep " on $HOME/SFTP/" | sed -E 's/^.* on (.*) \([^)]*\)$/\1/' | while IFS= read -r m; do
  umount "$m" 2>/dev/null || umount -f "$m" 2>/dev/null || diskutil unmount force "$m" >/dev/null 2>&1
done
pkill -f "rclone nfsmount .*$HOME/SFTP/" 2>/dev/null
pkill -f "rclone bisync .*/SFTP/" 2>/dev/null
done_ "online složky odpojeny"

# 4) hesla z Klíčenky
security dump-keychain 2>/dev/null | grep -o '"svce"<blob>="sftpdrive:[^"]*"' | sed 's/.*="//; s/"$//' | sort -u |
while IFS= read -r svc; do
  while security delete-generic-password -s "$svc" >/dev/null 2>&1; do :; done
done
done_ "hesla odstraněna z Klíčenky"

# 5) nastavení, logy, mezipaměť, Rychlé akce, příkaz sftpdrive
rm -rf "$HOME/.config/sftpdrive" "$HOME/Library/Logs/sftpdrive" "$HOME/Library/Caches/sftpdrive" \
       "$HOME/.local/bin/sftpdrive" "$HOME/.local/bin/sftpdrive-tag" "$HOME/Library/Services/SFTP – "*.workflow
/System/Library/CoreServices/pbs -update >/dev/null 2>&1
defaults delete cz.sftpdrive.app >/dev/null 2>&1
rm -f "$HOME"/Library/Preferences/cz.sftpdrive.*.plist
[ -f "$HOME/.zprofile" ] && perl -0pi -e 's/\n# sftpdrive\nexport PATH="\$HOME\/.local\/bin:\$PATH"\n//' "$HOME/.zprofile"
done_ "nastavení, logy a Rychlé akce smazány"

# 6) složka se soubory (~/SFTP Drive, u starších verzí ~/SFTP)
for D in "$HOME/SFTP Drive" "$HOME/SFTP"; do
  [ -d "$D" ] || continue
  only_junk=1   # je ve složce něco kromě .DS_Store a ikony složky?
  for e in "$D"/* "$D"/.[!.]* "$D"/..?*; do
    [ -e "$e" ] || continue
    case "${e##*/}" in .DS_Store|Icon$'\r') ;; *) only_junk=0; break ;; esac
  done
  if [ $only_junk = 1 ]; then
    rm -rf "$D"; done_ "složka $(basename "$D") smazána (byla prázdná)"
  elif ask "Ve složce $(basename "$D") jsou stažené soubory (na serveru zůstávají). Přesunout ji do Koše?"; then
    mv "$D" "$HOME/.Trash/$(basename "$D") $(date +%H%M%S)" && done_ "složka $(basename "$D") je v Koši"
  else
    echo "  – složka $(basename "$D") zůstává (už se nesynchronizuje)"
  fi
done

# 7) aplikace z Aplikací do Koše
for a in "/Applications/SFTP Drive.app" "$HOME/Applications/SFTP Drive.app"; do
  [ -d "$a" ] && mv "$a" "$HOME/.Trash/SFTP Drive $(date +%H%M%S).app" && done_ "aplikace přesunuta do Koše"
done

# 8) pomocné nástroje
if ask "Odebrat i pomocné nástroje rclone a fswatch (nainstalované kvůli SFTP Drive)?"; then
  command -v brew >/dev/null 2>&1 && brew uninstall rclone fswatch >/dev/null 2>&1
  rm -f "$HOME/.local/bin/rclone"
  rm -rf "$HOME/Library/Caches/rclone" "$HOME/.config/rclone"
  done_ "rclone a fswatch odebrány"
fi

echo
echo "Hotovo – SFTP Drive je odinstalovaný. Data na serverech zůstala beze změny."
[ -t 0 ] && [ $YES = 0 ] && read -r -p "Okno můžeš zavřít (Enter)." _
exit 0
