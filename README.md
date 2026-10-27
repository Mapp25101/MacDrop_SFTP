# MacDrop SFTP — SFTP Drive for macOS

**Your SFTP, FTP or FTPS server as a folder in Finder – work on it directly like in WinSCP, or keep a synced copy like Google Drive.**

Add a server, pick a folder name, done: `SFTP Drive → <name>` appears in Finder and in the sidebar. Choose a mode per server:

| | **Online** (like WinSCP) | **Synced copy** (like Google Drive) |
|---|---|---|
| What you see | the whole server, live | the whole server or selected folders |
| Stored on your Mac | **nothing** – files stream when opened, edits are buffered in memory and uploaded right away | a full copy of the selected folders |
| Without internet | the folder is unavailable (comes back by itself) | keep working, changes upload later |
| Good for | big servers, websites, quick edits | working on the go, offline access |

<p align="center">
  <img src="docs/add-server.png" width="49%" alt="Add server window">
  <img src="docs/choose-folders.png" width="40%" alt="Choosing which folders to synchronise">
</p>

## Features

- **SFTP, FTP and FTPS** – log in with a password or an SSH key, as many servers as you like.
- **Two modes** – *Online* (nothing stored on the Mac, like WinSCP) or *Synced copy* (works offline, like Google Drive).
- **In the Finder sidebar** – the *SFTP Drive* folder is added to Favorites automatically.
- **Online mode** – open, edit, drag in and delete files straight on the server; edited files live only in a hidden RAM
  disk until they are uploaded. When the internet drops the folder disconnects cleanly (no frozen Finder, no
  "connection interrupted" dialogs) and reconnects by itself.
- **Synced copy** – two-way sync, choose the whole server or selected folders, works offline; files waiting to be
  uploaded carry an orange Finder tag *Waiting to upload*.
- **No lost data on conflicts** – if a file changes on both sides the newer one wins and the older one is kept as `file.conflict1.txt`.
- **Menu-bar icon** with the status (✓ synced / ↻ syncing / ⚠ error / crossed-out = no connection).
- **Finder context menu** – *Choose synchronised folders…*, *Stop syncing – free up space*.
- **Reliable start** – after boot everything launches by itself, waits for the network if there is none, and
  repairs itself if a service fails to start.
- **Secure** – passwords live only in the macOS Keychain, SFTP host keys are pinned (protection against a spoofed server).

## Install

1. Download **`SFTPDrive.zip`** from the [latest release](../../releases/latest) and unzip it.
2. Double-click **SFTP Drive**.
   - macOS says it cannot verify the app (it is not signed with a paid Apple certificate):
     **System Settings → Privacy & Security → scroll down → "Open Anyway"**.
   - Or in Terminal (adjust the path to where you unzipped it):
     `find ~/Downloads/SFTPDrive -exec xattr -d com.apple.quarantine {} + 2>/dev/null`
3. The app offers to move itself to **Applications** – confirm.
4. On first launch it installs [rclone](https://rclone.org) (via Homebrew, or downloaded from rclone.org) and opens the **Add server** window.
5. Done – the **SFTP Drive** folder appears in the Finder sidebar with a folder for each server.

**Requirements:** Apple-silicon Mac (M1 or newer), macOS 13 Ventura or newer.

**Updating:** menu-bar icon → **Check for updates…** (the app also checks by itself and shows *Update to version …*).
It downloads the latest release, replaces the app in place and restarts – your servers, folders, settings, passwords
and the sync state are kept (a backup of the settings goes to `~/.config/sftpdrive/.backup`).
From Terminal: `sftpdrive update` (or `sftpdrive update --from ~/Downloads/SFTPDrive.zip` for a downloaded ZIP).
Updating by hand also works: unzip the new version and open it – it replaces the old one.

## Usage

| I want to… | How |
|---|---|
| add another server | menu-bar icon → **Add server…** (choose *Online* or *Synced copy*) |
| choose what is downloaded (synced copy) | menu-bar icon → **Choose synchronised folders…** (or right-click in Finder) |
| free up disk space (synced copy) | right-click a folder → **Stop syncing – free up space (SFTP)** |
| rename the folder | menu-bar icon → More → **Rename folder…** |
| sync right now (synced copy) | menu-bar icon → **Sync now** |
| pause temporarily | menu-bar icon → More → **Pause** |
| update to the latest version | menu-bar icon → **Check for updates…** (settings are kept) |

In both modes, whatever you delete in the folder is deleted on the server too.
Safety net for synced copies: if a sync would delete more than half of the files it stops instead.

## Uninstall

Menu-bar icon → **Uninstall SFTP Drive…**, or double-click `Uninstall.command` from the ZIP (removes everything,
including settings and passwords). Data on the servers is never touched.

## Limitations

- Apple silicon and macOS 13+ only.
- The app is not signed with an Apple developer certificate → "Open Anyway" is needed on first launch.
  For the same reason Finder cannot show per-file status badges (macOS only allows that for signed apps) –
  the status is shown by the menu-bar icon and the *Waiting to upload* tag instead.
- Online mode needs a working connection; edited files must fit into the RAM buffer (1 GB by default).
- Some servers briefly report a just-created folder as missing. In online mode, moving files into a new folder
  may then fail with an I/O error – simply repeat the move. Synced copies create new folders on the server
  before syncing and retry on their own; if a sync is interrupted anyway, nothing is undone – it just retries.
  Only when it cannot continue safely does it stop with *Sync stopped to protect your changes* – then click
  **Sync now** to merge both sides (files deleted or moved since the last good sync may reappear).
- An interrupted upload can leave a `name.XXXXXXXX.partial` file on the server (and, in a synced copy, on the Mac
  too). It is safe to delete. It is not filtered out on purpose – changing the filters would force a full
  re-merge for every existing installation.
- Finder may store its own `.DS_Store` / `._*` files on the server, as with any network share
  (to stop it: `defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true`).
- The folder chooser (synced copy) works on the top-level items of the server.
- The app's user interface is currently in English only.

---

## For developers

### How it works

```
┌──────────────────────────┐   sftpdrive _info / setup / _select …   ┌────────────────────────────┐
│ SFTP Drive.app           │ ──────────────────────────────────────▶ │ sftpdrive  (bash)          │
│  • menu-bar icon (Swift) │                                         │  • settings, Keychain      │
│  • windows, self-healing │ ◀── sftpdrive://… ── Finder extension   │  • one launchd agent/server│
└──────────────────────────┘                                         └─────────────┬──────────────┘
                                                                                   │ rclone bisync
                                         ~/SFTP Drive/<name>  ◀────────────────────┴───▶  server (SFTP/FTP/FTPS)
```

- **`src/sftpdrive`** – the engine (bash, compatible with macOS `/bin/bash` 3.2). For every server it creates a launchd
  agent `cz.sftpdrive.<connection>.sync`:
  - *online mode*: a watchdog that keeps an `rclone nfsmount` (a second agent, `….mount`) mounted while the server is
    reachable – a soft NFS mount hidden from Finder's Locations, write buffer on a hidden RAM disk
    (`hdiutil attach ram://`), unmounted cleanly when the server goes away;
  - *synced copy*: reacts to file changes (`fswatch`), checks the server every minute and calls `rclone bisync`;
    without internet it retries every 10 s.
- **`src/app/main.swift`** – the menu-bar app (AppKit, no Xcode project). It only calls the script and shows the state.
- **`src/app/finder.swift`** – the Finder extension (FinderSync) with the context-menu items.
- **`src/app/tag.swift`** – a tiny helper that sets/removes the *Waiting to upload* tag (keeps other tags intact).
- **`src/app/sidebar.m`** – adds/removes the *SFTP Drive* folder in the Finder sidebar (Objective-C).
- **`src/app/make-icon.swift`** – renders the app icon during the build.

### Where the data lives

| What | Where |
|---|---|
| server folders | `~/SFTP Drive/<name>/` (online: a mount point; synced copy: the files) |
| online write buffer | hidden RAM disk mounted on `~/Library/Caches/sftpdrive/ram` |
| server settings | `~/.config/sftpdrive/<connection>/` (`config`, `rclone.conf`, `offline.list`, `known_hosts`) |
| passwords | macOS Keychain, service `sftpdrive:<connection>:pass` |
| logs | `~/Library/Logs/sftpdrive/` (also: menu → More → Show log) |
| background services | `~/Library/LaunchAgents/cz.sftpdrive.*.plist` |

### Build

Only the Xcode Command Line Tools are needed (`xcode-select --install`), there is no Xcode project:

```bash
./build.command
```

The result is `dist/SFTPDrive.zip` (app + guide + uninstaller). The app is ad-hoc signed.

### Command line

The script can be used without the app (after the first launch it lives in `~/.local/bin/sftpdrive`):

```bash
sftpdrive setup            # wizard for a new server
sftpdrive status           # state of all servers
sftpdrive sync             # sync right now
sftpdrive update           # install the latest release from GitHub, keep all settings
sftpdrive help             # all commands
```

### Repository layout

```
build.command            builds dist/SFTPDrive.zip
src/sftpdrive            the sync engine (bash)
src/app/                 menu-bar app, Finder extension, helper tools (Swift) + Info.plists
src/package/             files shipped in the ZIP next to the app (guide, uninstaller)
docs/                    screenshots for this README
```

## License

[MIT](LICENSE). Synchronisation is done by [rclone](https://rclone.org) (MIT), which the app downloads on first launch.
