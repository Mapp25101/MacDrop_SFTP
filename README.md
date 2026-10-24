# MacDrop SFTP — SFTP Drive pro macOS

**Tvůj SFTP, FTP nebo FTPS server jako obyčejná složka ve Finderu – s oboustrannou synchronizací, jako Google Disk.**

Přidáš server, vybereš název složky a hotovo: ve Finderu se objeví `SFTP Drive → <název>`, soubory ze serveru se stáhnou
a všechno, co do složky nakopíruješ nebo v ní upravíš, se samo nahraje zpátky. Funguje to i bez internetu – změny
se dorovnají, jakmile se spojení vrátí.

<p align="center">
  <img src="docs/add-server.png" width="49%" alt="Okno Přidat server">
  <img src="docs/choose-folders.png" width="40%" alt="Výběr synchronizovaných složek">
</p>

> 🇬🇧 English summary is [at the bottom](#english).

## Co umí

- **SFTP, FTP i FTPS** – přihlášení heslem nebo SSH klíčem, víc serverů najednou.
- **Obyčejná složka na disku** – žádný síťový disk, žádné „vysunout“ ani hlášky o přerušeném spojení.
- **Oboustranná synchronizace** – změny z Macu jdou na server, změny ze serveru se stáhnou samy.
- **Výběr složek** – synchronizuj celý server, nebo jen vybrané složky (ostatní zůstanou jen na serveru).
- **Práce bez internetu** – soubory čekající na nahrání mají ve Finderu oranžový štítek *Čeká na nahrání*.
- **Konflikty bez ztráty dat** – když se soubor změní na obou stranách, novější vyhraje a starší se uloží jako `soubor.konflikt1.txt`.
- **Ikonka v horní liště** se stavem (✓ / ↻ / ⚠ / bez připojení) a menu pro všechno podstatné.
- **Menu pravého tlačítka ve Finderu** – *Vybrat synchronizované složky*, *Přestat synchronizovat – uvolnit místo*.
- **Spolehlivý start** – po zapnutí Macu se vše spustí samo, bez internetu počká, když něco nenaběhne, samo se to opraví.
- **Bezpečně** – hesla jen v Klíčence macOS, otisk klíče SFTP serveru se ověřuje (ochrana proti podvrženému serveru).

## Instalace

1. Stáhni **`SFTPDrive.zip`** z [Releases](../../releases/latest) a rozbal ho.
2. Dvakrát klikni na **SFTP Drive**.
   - macOS napíše, že aplikaci nelze ověřit (není podepsaná placeným certifikátem Apple):
     **Nastavení systému → Soukromí a zabezpečení → dole „Přesto otevřít“**.
   - Nebo v Terminálu (cestu uprav podle toho, kam jsi ZIP rozbalil):
     `find ~/Downloads/SFTPDrive -exec xattr -d com.apple.quarantine {} + 2>/dev/null`
3. Aplikace nabídne přesun do **Aplikací** – potvrď.
4. Poprvé si sama doinstaluje [rclone](https://rclone.org) (přes Homebrew, nebo z rclone.org) a otevře okno **Přidat server**.
5. Hotovo. Tip: ve Finderu vyber složku **SFTP Drive** (je v domovské složce) a stiskni **⌃⌘T** – bude v postranním panelu.

**Požadavky:** Mac s čipem Apple (M1 a novější), macOS 13 Ventura nebo novější.

**Aktualizace:** stáhni novou verzi, rozbal a spusť – starou sama nahradí.

## Používání

| Chci… | Jak |
|---|---|
| přidat další server | ikonka v liště → **Přidat server…** |
| vybrat, co se stahuje | ikonka v liště → **Vybrat synchronizované složky…** (nebo pravým tlačítkem ve Finderu) |
| uvolnit místo na disku | pravým tlačítkem na složku → **Přestat synchronizovat – uvolnit místo (SFTP)** |
| přejmenovat složku | ikonka v liště → Další → **Přejmenovat složku…** |
| synchronizovat hned | ikonka v liště → **Synchronizovat teď** |
| dočasně vypnout | ikonka v liště → Další → **Pozastavit** |

Co ve složce smažeš, smaže se i na serveru (stejně jako u Google Disku / OneDrivu). Pojistka: když by synchronizace
měla smazat víc než polovinu souborů, zastaví se.

## Odinstalace

Ikonka v liště → **Odinstalovat SFTP Drive…**, nebo dvakrát klikni na `Odinstalovat.command` ze ZIPu (smaže úplně vše
včetně nastavení a hesel). Data na serveru zůstanou beze změny.

## Omezení

- Jen Apple Silicon a macOS 13+.
- Aplikace není podepsaná vývojářským certifikátem Apple → při prvním spuštění je potřeba „Přesto otevřít“.
  Ze stejného důvodu Finder nezobrazí ikonky stavu přímo u souborů (to macOS dovolí jen podepsaným aplikacím) –
  stav ukazuje ikonka v liště a štítek *Čeká na nahrání*.
- Výběr složek funguje pro položky v kořeni serveru (podsložky se synchronizují celé).
- Celý vybraný obsah se stahuje na disk (zrcadlení) – na obrovské servery je lepší vybrat jen některé složky.

---

## Pro vývojáře

### Jak to funguje

```
┌──────────────────────────┐   sftpdrive _info / setup / _select …   ┌────────────────────────────┐
│ SFTP Drive.app           │ ──────────────────────────────────────▶ │ sftpdrive  (bash)          │
│  • ikonka v liště (Swift)│                                         │  • nastavení, Klíčenka     │
│  • okna, samooprava      │ ◀── sftpdrive://… ── rozšíření Finderu  │  • launchd agent na server │
└──────────────────────────┘                                         └─────────────┬──────────────┘
                                                                                   │ rclone bisync
                                         ~/SFTP Drive/<název>  ◀───────────────────┴───▶  server (SFTP/FTP/FTPS)
```

- **`src/sftpdrive`** – jádro (bash, kompatibilní s macOS `/bin/bash` 3.2). Pro každý server vytvoří launchd agenta
  `cz.sftpdrive.<připojení>.sync`, který běží na pozadí, reaguje na změny na disku (`fswatch`), každou minutu kontroluje
  server a volá `rclone bisync`. Bez internetu zkouší spojení každých 10 s.
- **`src/app/main.swift`** – aplikace v liště (AppKit, bez Xcode projektu). Jen volá skript a zobrazuje stav.
- **`src/app/finder.swift`** – rozšíření Finderu (FinderSync) s položkami v menu pravého tlačítka.
- **`src/app/tag.swift`** – malý pomocník, který nastavuje/odebírá štítek *Čeká na nahrání* (zachová ostatní štítky).
- **`src/app/make-icon.swift`** – vykreslí ikonu aplikace při sestavení.

### Kde jsou data

| Co | Kde |
|---|---|
| synchronizované soubory | `~/SFTP Drive/<název>/` |
| nastavení serverů | `~/.config/sftpdrive/<připojení>/` (`config`, `rclone.conf`, `offline.list`, `known_hosts`) |
| hesla | Klíčenka macOS, služba `sftpdrive:<připojení>:pass` |
| logy | `~/Library/Logs/sftpdrive/` (otevřeš i z menu → Zobrazit log) |
| služby na pozadí | `~/Library/LaunchAgents/cz.sftpdrive.*.plist` |

### Sestavení

Stačí Xcode Command Line Tools (`xcode-select --install`), žádný Xcode projekt:

```bash
./build.command
```

Výsledek je `dist/SFTPDrive.zip` (aplikace + návod + odinstalace). Aplikace je podepsaná ad-hoc.

### Příkazová řádka

Skript jde používat i bez aplikace (po prvním spuštění aplikace je v `~/.local/bin/sftpdrive`):

```bash
sftpdrive setup            # průvodce novým serverem
sftpdrive status           # stav všech serverů
sftpdrive sync             # synchronizovat hned
sftpdrive help             # všechny příkazy
```

### Struktura repozitáře

```
build.command            sestavení dist/SFTPDrive.zip
src/sftpdrive            synchronizační jádro (bash)
src/app/                 aplikace v liště, rozšíření Finderu, pomocné nástroje (Swift) + Info.plist
src/package/             soubory, které jdou do ZIPu vedle aplikace (návod, odinstalace)
docs/                    obrázky do README
```

## Licence

[MIT](LICENSE). Synchronizaci zajišťuje [rclone](https://rclone.org) (MIT), který si aplikace stáhne při prvním spuštění.

---

## English

**MacDrop SFTP (SFTP Drive)** turns any SFTP, FTP or FTPS server into a regular folder in Finder with two-way sync –
like Google Drive in mirror mode. Files live on your disk (works offline), changes sync both ways in the background,
and a menu-bar icon shows the status. The UI is in Czech.

- **Install:** download `SFTPDrive.zip` from [Releases](../../releases/latest), unzip, open *SFTP Drive*
  (first time: *System Settings → Privacy & Security → Open Anyway*, the app is not notarized). Apple Silicon, macOS 13+.
- **How it works:** a small AppKit menu-bar app drives a bash engine (`src/sftpdrive`) that runs one launchd agent per
  server and syncs with `rclone bisync`. Passwords are stored in the macOS Keychain, SFTP host keys are pinned.
- **Build:** `./build.command` (needs only Xcode Command Line Tools) → `dist/SFTPDrive.zip`.
- **License:** MIT.
