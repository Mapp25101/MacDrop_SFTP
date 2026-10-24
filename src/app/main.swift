// SFTP Drive (MacDrop SFTP) – aplikace v horní liště macOS.
//
// Veškerou práci (synchronizace přes rclone, hesla v Klíčence, služby na pozadí) dělá
// skript `sftpdrive`, který je přibalený v aplikaci a při prvním spuštění se nainstaluje
// do ~/.local/bin. Tahle aplikace je jen grafické rozhraní nad ním:
//
//   • AppDelegate        ikonka v liště, menu se stavem serverů, samooprava (služby,
//                        které nikdo nepozastavil, spustí znovu), první spuštění
//   • AddServerWindow    okno „Přidat server“ (SFTP / FTP / FTPS, ověření klíče serveru)
//   • FolderChooser      okno „Vybrat synchronizované složky“
//   • odkazy sftpdrive://  akce z menu pravého tlačítka ve Finderu (finder.swift)
//
// Stav čte příkazem `sftpdrive _info` (jeden řádek na server, pole oddělená tabulátorem).

import AppKit

// MARK: - Cesty

let home = NSHomeDirectory()
let installedBin = home + "/.local/bin/sftpdrive"
let confRoot = home + "/.config/sftpdrive"
let driveRoot = home + "/SFTP Drive"
let logRoot = home + "/Library/Logs/sftpdrive"
let loginLabel = "cz.sftpdrive.menubar"
let loginPlist = home + "/Library/LaunchAgents/\(loginLabel).plist"
let toolPath = home + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

var bundledScript: String? { Bundle.main.path(forResource: "sftpdrive", ofType: nil) }

// MARK: - Spouštění skriptu

struct RunResult {
    let code: Int32
    let out: String
    var ok: Bool { code == 0 }

    /// Srozumitelná chybová hláška (řádky "✖ …" ze skriptu, jinak konec výstupu).
    var errorText: String {
        let clean = out.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let lines = clean.split(separator: "\n").map { String($0) }
        let marked = lines.filter { $0.hasPrefix("✖") }.map { String($0.dropFirst(2)) }
        if !marked.isEmpty { return marked.joined(separator: "\n") }
        return lines.suffix(4).joined(separator: "\n")
    }
}

func runScript(_ args: [String], stdin: String? = nil, script: String = installedBin) -> RunResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script] + args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = toolPath
    env["SFTPDRIVE_FROM_APP"] = "1"
    p.environment = env
    let out = Pipe(), inp = Pipe()
    p.standardOutput = out
    p.standardError = out
    p.standardInput = inp
    do { try p.run() } catch { return RunResult(code: -1, out: "✖ " + error.localizedDescription) }
    if let s = stdin, let d = s.data(using: .utf8) { inp.fileHandleForWriting.write(d) }
    try? inp.fileHandleForWriting.close()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return RunResult(code: p.terminationStatus, out: String(decoding: data, as: UTF8.self))
}

func runAsync(_ args: [String], stdin: String? = nil, script: String = installedBin,
              done: @escaping (RunResult) -> Void = { _ in }) {
    DispatchQueue.global(qos: .userInitiated).async {
        let r = runScript(args, stdin: stdin, script: script)
        DispatchQueue.main.async { done(r) }
    }
}

let finderExtID = "cz.sftpdrive.app.finder"

/// Běží proces ze souborů, které se mezitím změnily (aplikace byla nahrazena novou verzí)?
func isStale(_ app: NSRunningApplication) -> Bool {
    guard let exe = app.executableURL?.path,
          let modified = (try? FileManager.default.attributesOfItem(atPath: exe))?[.modificationDate] as? Date,
          let started = processStart(app.processIdentifier) else { return false }
    return modified > started
}

/// Čas spuštění procesu (z jádra – funguje i u procesů spuštěných přes launchd).
func processStart(_ pid: pid_t) -> Date? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let t = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
}

/// Spustí nástroj a počká na výsledek (výstup).
func runTool(_ cmd: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do { try p.run() } catch { return "" }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}

/// Je rozšíření Finderu zapnuté? (pluginkit vypíše „+“ na začátku řádku)
func finderExtEnabled() -> Bool {
    runTool("/usr/bin/pluginkit", ["-m", "-i", finderExtID]).trimmingCharacters(in: .whitespaces).hasPrefix("+")
}

func shell(_ cmd: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd)
    p.arguments = args
    try? p.run()
}

// MARK: - Model

struct Rule { let pinned: Bool; let path: String }

struct Conn {
    let name, proto, host, port, user, remotePath: String
    let mountEnabled: Bool
    let mountDir, offlineDir: String
    let mounted, running, syncing: Bool
    let state, time, message: String
    let pending: Int          // souborů čekajících na nahrání
    let label: String         // název složky ve Finderu
    let paused: Bool          // ručně pozastaveno (jinak se po startu Macu spouští samo)

    init?(line: String) {
        let f = line.components(separatedBy: "\t")
        guard f.count >= 15 else { return nil }
        name = f[0]; proto = f[1]; host = f[2]; port = f[3]; user = f[4]; remotePath = f[5]
        mountEnabled = f[6] == "1"; mountDir = f[7]; offlineDir = f[8]
        mounted = f[9] == "1"; running = f[10] == "1"; syncing = f[11] == "1"
        state = f[12]; time = f[13]; message = f[14]
        pending = f.count > 15 ? Int(f[15]) ?? 0 : 0
        label = f.count > 16 && !f[16].isEmpty ? f[16] : (offlineDir as NSString).lastPathComponent
        paused = f.count > 17 && f[17] == "1"
    }

    var url: String { "\(proto)://\(user)@\(host):\(port)\(remotePath.isEmpty ? "" : remotePath)" }

    var rules: [Rule] {
        guard let txt = try? String(contentsOfFile: "\(confRoot)/\(name)/offline.list", encoding: .utf8) else { return [] }
        return txt.split(separator: "\n").compactMap { l in
            guard l.count > 2 else { return nil }
            return Rule(pinned: l.hasPrefix("+"), path: String(l.dropFirst(2)))
        }
    }

    var statusText: String {
        if !running { return paused ? "Pozastaveno" : "Spouštím synchronizaci…" }
        if syncing { return "Synchronizuji…" }
        let t = time.split(separator: " ").last.map { String($0.prefix(5)) } ?? ""
        switch state {
        case "ok": return "Synchronizováno \(t)"
        case "offline": return pending > 0 ? "Bez připojení – \(pending) čeká na nahrání" : "Server nedostupný – offline"
        case "error": return pending > 0 ? "Chyba – \(pending) čeká na nahrání" : "Chyba synchronizace"
        default: return "Spouštím…"
        }
    }

    var symbol: String {
        if !running { return paused ? "pause.circle" : "arrow.triangle.2.circlepath" }
        if syncing { return "arrow.triangle.2.circlepath" }
        switch state {
        case "error": return "exclamationmark.triangle"
        case "offline": return "wifi.slash"
        default: return "checkmark.circle"
        }
    }
}

func sfSymbol(_ name: String, _ desc: String = "") -> NSImage? {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: desc)
    img?.isTemplate = true
    return img
}

// MARK: - Pomůcky pro dialogy

@discardableResult
func alert(_ title: String, _ text: String, buttons: [String] = ["OK"],
           style: NSAlert.Style = .informational, accessory: NSView? = nil) -> Int {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.alertStyle = style
    for b in buttons { a.addButton(withTitle: b) }
    if let v = accessory { a.accessoryView = v }
    a.window.initialFirstResponder = accessory
    return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
}

func label(_ s: String) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.alignment = .right
    return l
}

func hint(_ s: String) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: s)
    l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    l.textColor = .secondaryLabelColor
    return l
}

// MARK: - Okno "Přidat server"

final class AddServerWindow: NSWindowController, NSWindowDelegate {
    var onDone: ((_ label: String, _ choose: Bool) -> Void)?

    let proto = NSPopUpButton()
    let host = NSTextField()
    let port = NSTextField()
    let user = NSTextField()
    let authPopup = NSPopUpButton()
    let pass = NSSecureTextField()
    let keyPath = NSTextField()
    let keyButton = NSButton(title: "Vybrat…", target: nil, action: nil)
    let path = NSTextField()
    let name = NSTextField()
    let syncPopup = NSPopUpButton()
    let certBox = NSButton(checkboxWithTitle: "Nekontrolovat certifikát (vlastní / self-signed)", target: nil, action: nil)
    let spinner = NSProgressIndicator()
    let status = NSTextField(labelWithString: "")
    let connectButton = NSButton(title: "Připojit", target: nil, action: nil)
    let cancelButton = NSButton(title: "Zrušit", target: nil, action: nil)
    var grid: NSGridView!
    var nameEdited = false
    var lastDefaultPort = "22"

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "SFTP Drive – přidat server"
        self.init(window: w)
        w.delegate = self
        build()
    }

    func build() {
        proto.addItems(withTitles: ["SFTP (přes SSH)", "FTP", "FTPS (FTP se šifrováním)"])
        proto.target = self; proto.action = #selector(protoChanged)
        authPopup.addItems(withTitles: ["Heslo", "SSH klíč"])
        authPopup.target = self; authPopup.action = #selector(authChanged)
        host.placeholderString = "např. muj-server.cz nebo 192.168.1.10"
        port.stringValue = "22"
        user.placeholderString = "uživatelské jméno"
        pass.placeholderString = "heslo (uloží se do Klíčenky)"
        keyPath.stringValue = ["id_ed25519", "id_rsa", "id_ecdsa"].map { home + "/.ssh/" + $0 }
            .first { FileManager.default.fileExists(atPath: $0) } ?? home + "/.ssh/id_ed25519"
        keyButton.target = self; keyButton.action = #selector(pickKey)
        path.placeholderString = "prázdné = domovská složka, např. /var/www"
        name.placeholderString = "např. Škola"
        syncPopup.addItems(withTitles: ["Celý server (doporučeno)", "Jen vybrané složky – vyberu po připojení"])
        host.target = self; host.action = nil
        NotificationCenter.default.addObserver(self, selector: #selector(hostChanged),
                                               name: NSControl.textDidChangeNotification, object: host)
        NotificationCenter.default.addObserver(self, selector: #selector(nameTyped),
                                               name: NSControl.textDidChangeNotification, object: name)
        port.widthAnchor.constraint(equalToConstant: 80).isActive = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let keyRow = NSStackView(views: [keyPath, keyButton])
        let portRow = NSStackView(views: [port, hint("SFTP obvykle 22, FTP/FTPS 21")])

        grid = NSGridView(views: [
            [label("Protokol:"), proto],
            [label("Server:"), host],
            [label("Port:"), portRow],
            [label("Uživatel:"), user],
            [label("Přihlášení:"), authPopup],
            [label("Heslo:"), pass],
            [label("SSH klíč:"), keyRow],
            [label("Složka na serveru:"), path],
            [label("Název složky:"), name],
            [NSGridCell.emptyContentView, hint("Ve Finderu bude složka „SFTP Drive → <název>“. Je to obyčejná složka na disku – funguje i bez internetu.")],
            [label("Synchronizovat:"), syncPopup],
            [NSGridCell.emptyContentView, certBox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 9
        grid.columnSpacing = 10
        for f in [host, user, pass, path, name, keyPath] { f.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true }

        cancelButton.target = self; cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        connectButton.target = self; connectButton.action = #selector(connect)
        connectButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [spinner, status, NSView(), cancelButton, connectButton])
        buttons.distribution = .fill
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let intro = hint("Zadej údaje k serveru. Po připojení bude server ve Finderu jako složka ve „SFTP Drive“ a ikonka v horní liště ukáže stav synchronizace.")
        let stack = NSStackView(views: [intro, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        intro.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        window!.contentView = stack
        protoChanged()
        window!.setContentSize(stack.fittingSize)
    }

    var protoKey: String { ["sftp", "ftp", "ftps"][proto.indexOfSelectedItem] }

    func setRow(_ i: Int, hidden: Bool) { grid.row(at: i).isHidden = hidden }

    @objc func protoChanged() {
        let def = protoKey == "sftp" ? "22" : "21"
        if port.stringValue.isEmpty || port.stringValue == lastDefaultPort { port.stringValue = def }
        lastDefaultPort = def
        if protoKey != "sftp" { authPopup.selectItem(at: 0) }
        setRow(4, hidden: protoKey != "sftp")
        setRow(11, hidden: protoKey != "ftps")
        authChanged()
    }

    @objc func authChanged() {
        let key = protoKey == "sftp" && authPopup.indexOfSelectedItem == 1
        setRow(6, hidden: !key)
        (grid.cell(atColumnIndex: 0, rowIndex: 5).contentView as? NSTextField)?.stringValue = key ? "Heslo ke klíči:" : "Heslo:"
        pass.placeholderString = key ? "passphrase klíče (když žádnou nemá, nech prázdné)" : "heslo (uloží se do Klíčenky)"
    }

    @objc func pickKey() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: home + "/.ssh")
        p.showsHiddenFiles = true
        if p.runModal() == .OK, let u = p.url { keyPath.stringValue = u.path }
    }

    @objc func hostChanged() {
        guard !nameEdited else { return }
        var h = host.stringValue
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        h = String(h.split(whereSeparator: { $0 == "/" || $0 == ":" }).first ?? "")
        // ftp.example.com → „Example“ (doména bez ftp./www. a koncovky); IP adresa → „Server“
        let parts = h.split(separator: ".").map(String.init)
        let isIP = !parts.isEmpty && parts.allSatisfy { Int($0) != nil }
        let guess = isIP || parts.isEmpty ? "" : (parts.count >= 2 ? parts[parts.count - 2] : parts[0])
        name.stringValue = guess.isEmpty ? "Server" : guess.prefix(1).uppercased() + guess.dropFirst()
    }

    @objc func nameTyped() { nameEdited = true }

    @objc func cancel() { close() }

    func busy(_ on: Bool, _ text: String = "") {
        on ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        status.stringValue = text
        connectButton.isEnabled = !on
        grid.subviews.forEach { ($0 as? NSControl)?.isEnabled = !on }
    }

    @objc func connect() {
        let h = host.stringValue.trimmingCharacters(in: .whitespaces)
        let u = user.stringValue.trimmingCharacters(in: .whitespaces)
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        let useKey = protoKey == "sftp" && authPopup.indexOfSelectedItem == 1
        if h.isEmpty { return fail("Vyplň adresu serveru.") }
        if u.isEmpty { return fail("Vyplň uživatelské jméno.") }
        if !useKey && pass.stringValue.isEmpty { return fail("Vyplň heslo.") }
        if Int(port.stringValue) == nil { return fail("Port musí být číslo.") }
        if n.isEmpty || n.contains("/") || n.hasPrefix(".") {
            return fail("Vyplň název složky (bez „/“ a nesmí začínat tečkou).")
        }
        if protoKey == "sftp" {
            busy(true, "Ověřuji server…")
            let hostOnly = hostPart(h)
            runAsync(["_keyscan", hostOnly, port.stringValue]) { r in
                guard r.ok else { self.busy(false); return self.fail(r.errorText) }
                let fps = r.out.split(separator: "\n").map(String.init).filter { $0.hasPrefix("SHA256:") }
                guard let first = fps.first else { self.busy(false); return self.fail("Server nevrátil klíč.") }
                let choice = alert("Je to opravdu tvůj server?",
                                   "Otisk klíče serveru \(hostOnly):\n\n\(fps.joined(separator: "\n"))\n\nPři prvním připojení obvykle stačí potvrdit. Příště se klíč kontroluje automaticky – když by se změnil, připojení se odmítne.",
                                   buttons: ["Důvěřovat a připojit", "Zrušit"])
                if choice != 0 { self.busy(false); return }
                self.runSetup(expectFp: String(first.split(separator: " ")[0]))
            }
        } else {
            runSetup(expectFp: nil)
        }
    }

    func hostPart(_ h: String) -> String {
        var s = h
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        s = String(s.split(separator: "/").first ?? "")
        if let c = s.lastIndex(of: ":") { s = String(s[..<c]) }
        return s
    }

    func runSetup(expectFp: String?) {
        busy(true, "Připojuji a nastavuji… (může chvíli trvat)")
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        let choose = syncPopup.indexOfSelectedItem == 1
        var args = ["setup", "--yes", "--proto", protoKey, "--label", n,
                    "--host", host.stringValue.trimmingCharacters(in: .whitespaces),
                    "--port", port.stringValue, "--user", user.stringValue.trimmingCharacters(in: .whitespaces)]
        let p = path.stringValue.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty { args += ["--path", p] }
        args.append("--no-mount")
        args.append(choose ? "--choose" : "--all-offline")
        if protoKey == "ftps" && certBox.state == .on { args.append("--no-check-cert") }
        if let fp = expectFp { args += ["--expect-fp", fp] }
        let useKey = protoKey == "sftp" && authPopup.indexOfSelectedItem == 1
        if useKey { args += ["--key", keyPath.stringValue] } else { args.append("--password-stdin") }
        runAsync(args, stdin: pass.stringValue + "\n") { r in
            self.busy(false)
            guard r.ok else { return self.fail(r.errorText) }
            self.close()
            decorateDriveRoot()
            self.onDone?(n, choose)
            if choose { return }   // rovnou se otevře výběr složek
            let text = "Server je ve Finderu jako složka „\(n)“ ve složce SFTP Drive. Stahuje se a dál se synchronizuje oběma směry – funguje i bez internetu.\n\nTip: vyber ve Finderu složku „SFTP Drive“ a stiskni ⌃⌘T (Soubor → Přidat do postranního panelu)."
            if alert("Připojeno ✓", text, buttons: ["Otevřít ve Finderu", "Hotovo"]) == 0 {
                NSWorkspace.shared.open(URL(fileURLWithPath: driveRoot + "/" + n))
            }
        }
    }

    func fail(_ msg: String) {
        alert("Nepodařilo se připojit", msg, style: .warning)
    }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(host)
    }
}

// MARK: - Okno "Vybrat synchronizované složky"

/// Stejná logika jako ve skriptu: rozhoduje nejkonkrétnější pravidlo.
func isPinned(_ rules: [Rule], _ rel: String) -> Bool {
    var best: Bool? = nil, bestLen = -1
    for r in rules where r.path == "/" || rel == r.path || rel.hasPrefix(r.path + "/") {
        let len = r.path == "/" ? 0 : r.path.count
        if len > bestLen { best = r.pinned; bestLen = len }
    }
    return best ?? false
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class FolderChooser: NSWindowController, NSWindowDelegate {
    let conn: Conn
    var onDone: (() -> Void)?
    var boxes: [(name: String, box: NSButton)] = []
    let allBox = NSButton(checkboxWithTitle: "Celý server (i to, co na něm později přibude)", target: nil, action: nil)
    let list = NSStackView()
    let spinner = NSProgressIndicator()
    let status = NSTextField(labelWithString: "Načítám obsah serveru…")
    let saveButton = NSButton(title: "Uložit", target: nil, action: nil)
    let cancelButton = NSButton(title: "Zrušit", target: nil, action: nil)

    init(conn: Conn) {
        self.conn = conn
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Synchronizované složky – \(conn.label)"
        super.init(window: w)
        w.delegate = self
        build()
        load()
    }
    required init?(coder: NSCoder) { fatalError() }

    func build() {
        let intro = hint("Zaškrtnuté složky a soubory se stáhnou do složky „\(conn.label)“ a budou se synchronizovat. Co odškrtneš, smaže se jen z tohoto Macu – na serveru zůstane.")
        allBox.target = self; allBox.action = #selector(allToggled)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 7
        list.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: doc.topAnchor, constant: 10),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 12),
            list.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -12),
            doc.bottomAnchor.constraint(greaterThanOrEqualTo: list.bottomAnchor, constant: 10),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 440),
        ])
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cancelButton.target = self; cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self; saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = false
        let buttons = NSStackView(views: [spinner, status, NSView(), cancelButton, saveButton])
        let stack = NSStackView(views: [intro, allBox, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for v in [intro, scroll, buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        window!.contentView = stack
        allBox.state = conn.rules.contains { $0.pinned && $0.path == "/" } ? .on : .off
    }

    func load() {
        runAsync(["_ls", conn.name]) { r in
            self.spinner.stopAnimation(nil)
            guard r.ok else {
                self.status.stringValue = "Server je nedostupný – zkus to, až budeš online."
                return
            }
            let rules = self.conn.rules
            let names = r.out.split(separator: "\n").map(String.init)
                .filter { !$0.isEmpty && $0 != ".DS_Store/" && $0 != ".DS_Store" }
                .sorted { ($0.hasSuffix("/") ? 0 : 1, $0.lowercased()) < ($1.hasSuffix("/") ? 0 : 1, $1.lowercased()) }
            for n in names {
                let isDir = n.hasSuffix("/")
                let clean = isDir ? String(n.dropLast()) : n
                // ikonka v textu – obrázek u zaškrtávacího políčka by nahradil samotné políčko
                let box = NSButton(checkboxWithTitle: (isDir ? "📁  " : "📄  ") + clean, target: nil, action: nil)
                box.state = isPinned(rules, "/" + clean.precomposedStringWithCanonicalMapping) ? .on : .off
                self.list.addArrangedSubview(box)
                self.boxes.append((clean, box))
            }
            self.status.stringValue = names.isEmpty ? "Na serveru zatím nic není." : "Položek na serveru: \(names.count)"
            self.saveButton.isEnabled = true
            self.allToggled()
        }
    }

    @objc func allToggled() {
        let all = allBox.state == .on
        for b in boxes { if all { b.box.state = .on }; b.box.isEnabled = !all }
    }

    @objc func cancel() { close() }

    @objc func save() {
        let all = allBox.state == .on
        let chosen = boxes.filter { $0.box.state == .on }.map { $0.name }
        if !all && chosen.isEmpty {
            alert("Nic není vybráno", "Zaškrtni aspoň jednu složku, nebo „Celý server“.")
            return
        }
        saveButton.isEnabled = false
        spinner.startAnimation(nil)
        status.stringValue = "Ukládám a synchronizuji…"
        runAsync(["_select", conn.name] + (all ? ["--all"] : chosen)) { r in
            self.spinner.stopAnimation(nil)
            self.saveButton.isEnabled = true
            guard r.ok else {
                self.status.stringValue = ""
                alert("Výběr se nepodařilo uložit", r.errorText, style: .warning)
                return
            }
            self.close()
            self.onDone?()
        }
    }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Složka ~/SFTP Drive dostane ikonu obláčku, ať je ve Finderu hned vidět.
func decorateDriveRoot() {
    guard FileManager.default.fileExists(atPath: driveRoot),
          !FileManager.default.fileExists(atPath: driveRoot + "/Icon\r") else { return }   // už ikonu má
    let size = NSSize(width: 512, height: 512)
    let folder = NSWorkspace.shared.icon(for: .folder)
    folder.size = size
    // skutečná bitmapa 512×512 – z obrázku kresleného „za běhu“ macOS ikonu neumí uložit
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    folder.draw(in: NSRect(origin: .zero, size: size))
    if let cloud = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 170, weight: .regular)) {
        let tinted = NSImage(size: cloud.size, flipped: false) { r in
            cloud.draw(in: r)
            NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.80, alpha: 0.85).set()
            r.fill(using: .sourceAtop)
            return true
        }
        let s = tinted.size
        tinted.draw(in: NSRect(x: (size.width - s.width) / 2, y: 150 - s.height / 2 + 40, width: s.width, height: s.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    let img = NSImage(size: size)
    img.addRepresentation(rep)
    NSWorkspace.shared.setIcon(img, forFile: driveRoot, options: [])
}

// MARK: - Aplikace (ikonka v liště)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var conns: [Conn] = []
    var addWindow: AddServerWindow?
    var timer: Timer?
    var refreshing = false
    var ready = false

    func applicationDidFinishLaunching(_ n: Notification) {
        // Jen jedna kopie: když už SFTP Drive běží (třeba z jiné složky), ukáže se ta a tahle skončí.
        // Jen jedna kopie aplikace. Starší verzi (aktualizace) nebo kopii, která běží ze starých
        // souborů (aplikace byla mezitím nahrazena), ukončí a pokračuje tahle.
        let me = ProcessInfo.processInfo.processIdentifier
        let fromLogin = ProcessInfo.processInfo.environment["SFTPDRIVE_LOGIN"] == "1"
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "cz.sftpdrive.app")
            .first(where: { $0.processIdentifier != me }), let url = other.bundleURL {
            let mine = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
            let theirs = Bundle(url: url)?.infoDictionary?["CFBundleVersion"] as? String ?? "0"
            if !fromLogin && (mine.compare(theirs, options: .numeric) == .orderedDescending || isStale(other)) {
                // ať ji launchd po ukončení hned znovu nespustí (KeepAlive) – při příštím přihlášení se načte zase
                _ = runTool("/bin/launchctl", ["bootout", "gui/\(getuid())/\(loginLabel)"])
                other.forceTerminate()
                for _ in 0..<30 where !other.isTerminated { usleep(100_000) }
            } else {
                if !fromLogin { shell("/usr/bin/open", [url.path]) }   // ukázat menu té, která už běží
                exit(0)
            }
        }
        if offerMoveToApplications() { return }
        installEditMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = sfSymbol("cloud", "SFTP Drive")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        rebuildMenu()
        ensureBackend { ok in
            guard ok else { return }
            self.ready = true
            self.ensureLoginItem()
            self.ensureFinderExtension()
            decorateDriveRoot()
            self.refresh {
                if self.conns.isEmpty { self.showAdd() }
            }
            self.timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                self.restartIfUpdated()
                self.refresh()
            }
        }
    }

    /// Rozšíření Finderu a spouštění po přihlášení potřebují aplikaci ve složce Aplikace.
    /// Vrací true, když se aplikace přesouvá (a tahle kopie končí).
    func offerMoveToApplications() -> Bool {
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return false }
        let dest = "/Applications/SFTP Drive.app"
        guard alert("Přesunout SFTP Drive do Aplikací?",
                    "Aby fungovaly položky v menu Finderu a automatické spuštění po zapnutí Macu, musí být aplikace ve složce Aplikace.",
                    buttons: ["Přesunout do Aplikací", "Teď ne"]) == 0 else { return false }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest) { try fm.trashItem(at: URL(fileURLWithPath: dest), resultingItemURL: nil) }
            do { try fm.moveItem(atPath: path, toPath: dest) } catch { try fm.copyItem(atPath: path, toPath: dest) }
        } catch {
            alert("Přesun se nepovedl", error.localizedDescription + "\n\nPřetáhni aplikaci do Aplikací ručně.", style: .warning)
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "find \"$0\" -exec xattr -d com.apple.quarantine {} + 2>/dev/null; sleep 1; /usr/bin/open \"$0\"", dest]
        try? p.run()
        exit(0)
    }

    // --- rozšíření Finderu (menu pravého tlačítka) ---
    var finderExtOn = false
    var appexPath: String? {
        guard let p = Bundle.main.builtInPlugInsURL?.appendingPathComponent("SFTPDriveFinder.appex").path,
              FileManager.default.fileExists(atPath: p) else { return nil }
        return p
    }

    func ensureFinderExtension() {
        guard let appex = appexPath else { return }
        let first = !UserDefaults.standard.bool(forKey: "finderExtConfigured")
        DispatchQueue.global().async {
            _ = runTool("/usr/bin/pluginkit", ["-a", appex])
            if first { _ = runTool("/usr/bin/pluginkit", ["-e", "use", "-i", finderExtID]) }
            let on = finderExtEnabled()
            DispatchQueue.main.async {
                UserDefaults.standard.set(true, forKey: "finderExtConfigured")
                self.finderExtOn = on
                self.rebuildMenu()
            }
        }
    }

    @objc func toggleFinderExt() {
        let turnOn = !finderExtOn
        DispatchQueue.global().async {
            _ = runTool("/usr/bin/pluginkit", ["-e", turnOn ? "use" : "ignore", "-i", finderExtID])
            let on = finderExtEnabled()
            DispatchQueue.main.async {
                self.finderExtOn = on
                self.rebuildMenu()
                if turnOn && !on {
                    alert("Položky ve Finderu se nepodařilo zapnout",
                          "Zapni je ručně: Nastavení systému → Obecné → Položky a rozšíření → Rozšíření Finderu → SFTP Drive.")
                }
            }
        }
    }

    // --- akce z menu Finderu (sftpdrive://pin?p=…) ---
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.scheme == "sftpdrive" {
            if u.host == "choose", let c = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "c" })?.value {
                refresh { self.openChooser(c) }
                continue
            }
            guard let cmd = u.host, ["pin", "unpin", "reveal"].contains(cmd) else { continue }
            let paths = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?
                .filter { $0.name == "p" }.compactMap { $0.value } ?? []
            if paths.isEmpty { continue }
            runAsync([cmd, "--gui"] + paths) { _ in self.refresh() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
        }
    }

    /// Aplikace v liště nemá viditelné menu, ale bez menu Úpravy nefungují ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z v polích.
    func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Zavřít okno", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Úpravy")
        edit.addItem(withTitle: "Zpět", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Znovu", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Vyjmout", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopírovat", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Vložit", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Vybrat vše", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // --- instalace / aktualizace skriptu a rclone ---
    func ensureBackend(done: @escaping (Bool) -> Void) {
        guard let bundled = bundledScript else { done(FileManager.default.fileExists(atPath: installedBin)); return }
        let fm = FileManager.default
        let same = fm.contentsEqual(atPath: bundled, andPath: installedBin)
        let hasRclone = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", home + "/.local/bin/rclone"]
            .contains { fm.isExecutableFile(atPath: $0) }
        if same && hasRclone { done(true); return }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 90),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "SFTP Drive"
        let sp = NSProgressIndicator(); sp.style = .spinning; sp.startAnimation(nil)
        let txt = NSTextField(wrappingLabelWithString: hasRclone
            ? "Připravuji SFTP Drive…"
            : "Připravuji SFTP Drive – stahuji rclone (jen poprvé, chvilku to trvá)…")
        let st = NSStackView(views: [sp, txt])
        st.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        st.spacing = 14
        panel.contentView = st
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        runAsync(["install"], script: bundled) { r in
            panel.close()
            if !r.ok {
                alert("Instalace se nepovedla", r.errorText + "\n\nZkontroluj připojení k internetu a spusť aplikaci znovu.", style: .critical)
                NSApp.terminate(nil)
            }
            done(r.ok)
        }
    }

    // --- spouštění po přihlášení ---
    var loginEnabled: Bool { FileManager.default.fileExists(atPath: loginPlist) }

    func ensureLoginItem() {
        let d = UserDefaults.standard
        if !d.bool(forKey: "loginConfigured") {
            d.set(true, forKey: "loginConfigured")
            setLogin(true)
        } else if loginEnabled {
            setLogin(true) // přepsat cestu, kdyby se aplikace přesunula
        }
    }

    func setLogin(_ on: Bool) {
        if on {
            let plist: [String: Any] = [
                "Label": loginLabel,
                // přímo program aplikace: po pádu ho macOS spustí znovu (po ručním „Ukončit“ ne)
                "ProgramArguments": [Bundle.main.executablePath ?? Bundle.main.bundlePath + "/Contents/MacOS/SFTPDrive"],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "ThrottleInterval": 20,
                "EnvironmentVariables": ["SFTPDRIVE_LOGIN": "1"],
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua",
            ]
            try? FileManager.default.createDirectory(atPath: home + "/Library/LaunchAgents", withIntermediateDirectories: true)
            (plist as NSDictionary).write(toFile: loginPlist, atomically: true)
        } else {
            try? FileManager.default.removeItem(atPath: loginPlist)
        }
    }

    // --- stav ---
    func refresh(_ then: (() -> Void)? = nil) {
        guard ready, !refreshing else { then?(); return }
        refreshing = true
        runAsync(["_info"]) { r in
            self.refreshing = false
            if r.ok {
                self.conns = r.out.split(separator: "\n").compactMap { Conn(line: String($0)) }
            }
            self.updateIcon()
            self.rebuildMenu()
            self.healStopped()
            then?()
        }
    }

    /// Aplikaci mezitím nahradila nová verze (přetažením do Aplikací) → spustit novou a tuhle ukončit.
    func restartIfUpdated() {
        guard isStale(NSRunningApplication.current) else { return }
        if ProcessInfo.processInfo.environment["SFTPDRIVE_LOGIN"] == "1" {
            exit(1)   // spuštěno při přihlášení → launchd ji hned spustí znovu, už novou
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        exit(0)
    }

    // --- samooprava: synchronizace, kterou nikdo nepozastavil, musí běžet (i po startu Macu) ---
    var healTried: [String: Date] = [:]
    var healFailures: [String: Int] = [:]
    var healWarned = false

    func healStopped() {
        for c in conns where !c.running && !c.paused {
            if let t = healTried[c.name], Date().timeIntervalSince(t) < 60 { continue }
            healTried[c.name] = Date()
            runAsync(["start", c.name]) { r in
                if r.ok { self.healFailures[c.name] = 0; self.refresh(); return }
                self.healFailures[c.name, default: 0] += 1
                if self.healFailures[c.name]! >= 2 && !self.healWarned {
                    self.healWarned = true
                    alert("Synchronizace „\(c.label)“ se nespouští",
                          "macOS nejspíš nepovolil běh na pozadí. Otevři Nastavení systému → Obecné → Položky při přihlášení a rozšíření a povol „sftpdrive“ a „SFTP Drive“.",
                          style: .warning)
                }
            }
        }
    }

    func updateIcon() {
        var sym = "cloud"
        if conns.contains(where: { $0.running && $0.syncing }) { sym = "arrow.triangle.2.circlepath.icloud" }
        else if conns.contains(where: { $0.running && $0.state == "error" }) { sym = "exclamationmark.icloud" }
        else if conns.contains(where: { $0.running && $0.state == "offline" }) { sym = "icloud.slash" }
        else if !conns.isEmpty && conns.allSatisfy({ !$0.running }) { sym = "pause.circle" }
        else if !conns.isEmpty { sym = "checkmark.icloud" }
        item.button?.image = sfSymbol(sym, "SFTP Drive") ?? sfSymbol("cloud")
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    // --- menu ---
    func mi(_ title: String, _ action: Selector?, _ obj: Any? = nil, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: key)
        m.target = self
        m.representedObject = obj
        if let s = symbol { m.image = sfSymbol(s) }
        return m
    }

    func rebuildMenu() {
        guard let menu = item.menu else { return }
        menu.removeAllItems()
        let head = NSMenuItem(title: "SFTP Drive", action: nil, keyEquivalent: "")
        head.attributedTitle = NSAttributedString(string: "SFTP Drive", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        menu.addItem(head)

        if !ready {
            menu.addItem(NSMenuItem(title: "Připravuji…", action: nil, keyEquivalent: ""))
        } else if conns.isEmpty {
            menu.addItem(NSMenuItem(title: "Zatím žádný server", action: nil, keyEquivalent: ""))
        }

        for c in conns {
            menu.addItem(.separator())
            let t = NSMenuItem(title: "\(c.label) – \(c.statusText)", action: nil, keyEquivalent: "")
            t.image = sfSymbol(c.symbol)
            t.toolTip = c.url + (c.message.isEmpty ? "" : "\n" + c.message)
            menu.addItem(t)
            if c.state == "error" && !c.message.isEmpty && c.running {
                let e = NSMenuItem(title: "   " + String(c.message.prefix(70)), action: nil, keyEquivalent: "")
                menu.addItem(e)
            }
            if c.mountEnabled {
                if c.mounted {
                    menu.addItem(mi("Otevřít celý server (online)", #selector(openPath(_:)), c.mountDir, symbol: "globe"))
                } else {
                    menu.addItem(mi("Online složka odpojena – připojit", #selector(start(_:)), c.name, symbol: "globe"))
                }
            }
            menu.addItem(mi("Otevřít složku „\(c.label)“", #selector(openPath(_:)), c.offlineDir, symbol: "folder"))
            menu.addItem(mi("Synchronizovat teď", #selector(syncNow(_:)), c.name, symbol: "arrow.triangle.2.circlepath"))

            menu.addItem(mi("Vybrat synchronizované složky…", #selector(chooseFolders(_:)), c.name, symbol: "checklist"))

            // další volby
            let more = NSMenu()
            more.addItem(c.running
                ? mi("Pozastavit", #selector(stop(_:)), c.name, symbol: "pause")
                : mi("Spustit", #selector(start(_:)), c.name, symbol: "play"))
            more.addItem(mi("Přejmenovat složku…", #selector(renameConn(_:)), c.name, symbol: "pencil"))
            more.addItem(mi("Změnit heslo…", #selector(changePassword(_:)), c.name, symbol: "key"))
            more.addItem(mi("Zobrazit log", #selector(showLog(_:)), c.name, symbol: "doc.text"))
            more.addItem(.separator())
            let info = NSMenuItem(title: c.url, action: nil, keyEquivalent: "")
            more.addItem(info)
            more.addItem(.separator())
            more.addItem(mi("Odebrat tento server…", #selector(removeConn(_:)), c.name, symbol: "trash"))
            let moreItem = NSMenuItem(title: "Další", action: nil, keyEquivalent: "")
            moreItem.image = sfSymbol("ellipsis.circle")
            moreItem.submenu = more
            menu.addItem(moreItem)
        }

        menu.addItem(.separator())
        let add = mi("Přidat server…", #selector(showAddAction), key: "n", symbol: "plus")
        add.isEnabled = ready
        menu.addItem(add)
        menu.addItem(mi("Jak to funguje?", #selector(help), symbol: "questionmark.circle"))
        let login = mi("Spouštět po přihlášení", #selector(toggleLogin))
        login.state = loginEnabled ? .on : .off
        menu.addItem(login)
        if appexPath != nil {
            let fx = mi("Položky SFTP v menu Finderu", #selector(toggleFinderExt))
            fx.state = finderExtOn ? .on : .off
            menu.addItem(fx)
        }
        menu.addItem(mi("Odinstalovat SFTP Drive…", #selector(uninstall)))
        menu.addItem(.separator())
        menu.addItem(mi("Ukončit ikonku", #selector(quit), key: "q"))
    }

    // --- akce ---
    @objc func showAddAction() { showAdd() }

    func showAdd() {
        if addWindow == nil {
            addWindow = AddServerWindow()
            addWindow?.onDone = { [weak self] label, choose in
                self?.addWindow = nil
                self?.refresh {
                    if choose, let c = self?.conns.first(where: { $0.label == label }) { self?.openChooser(c.name) }
                }
            }
        }
        addWindow?.show()
    }

    var chooser: FolderChooser?

    func openChooser(_ name: String) {
        guard let c = conns.first(where: { $0.name == name }) else { return }
        chooser?.close()
        chooser = FolderChooser(conn: c)
        chooser?.onDone = { [weak self] in self?.refresh(); self?.chooser = nil }
        chooser?.show()
    }

    @objc func chooseFolders(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String else { return }
        refresh { self.openChooser(n) }
    }

    @objc func renameConn(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String, let c = conns.first(where: { $0.name == n }) else { return }
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.stringValue = c.label
        guard alert("Přejmenovat složku „\(c.label)“", "Nový název složky ve Finderu (smí mít mezery i diakritiku):",
                    buttons: ["Přejmenovat", "Zrušit"], accessory: f) == 0 else { return }
        let new = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != c.label else { return }
        runAsync(["rename", n, new]) { r in
            if !r.ok { alert("Přejmenování se nepovedlo", r.errorText, style: .warning) }
            self.refresh()
        }
    }

    @objc func openPath(_ s: NSMenuItem) {
        guard let p = s.representedObject as? String else { return }
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }

    @objc func syncNow(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String else { return }
        refresh()
        runAsync(["sync", n]) { r in
            self.refresh()
            if !r.ok { alert("Synchronizace se nepovedla", r.errorText, style: .warning) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    @objc func start(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String else { return }
        runAsync(["start", n]) { _ in self.refresh() }
    }

    @objc func stop(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String else { return }
        runAsync(["stop", n]) { _ in self.refresh() }
    }

    @objc func changePassword(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String else { return }
        let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.placeholderString = "nové heslo"
        guard alert("Změnit heslo pro „\(n)“", "Použij, když se heslo na serveru změnilo. Uloží se do Klíčenky.",
                    buttons: ["Uložit", "Zrušit"], accessory: f) == 0, !f.stringValue.isEmpty else { return }
        runAsync(["password", n], stdin: f.stringValue + "\n") { r in
            if !r.ok { alert("Heslo se nepodařilo uložit", r.errorText, style: .warning) }
            self.refresh()
        }
    }

    @objc func showLog(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String else { return }
        let f = "\(logRoot)/\(n)-sync.log"
        if !FileManager.default.fileExists(atPath: f) { FileManager.default.createFile(atPath: f, contents: nil) }
        shell("/usr/bin/open", ["-a", "Console", f])
    }

    @objc func removeConn(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String else { return }
        let box = NSButton(checkboxWithTitle: "Smazat i místní offline kopii", target: nil, action: nil)
        guard alert("Odebrat server „\(n)“?", "Soubory na serveru zůstanou beze změny.",
                    buttons: ["Odebrat", "Zrušit"], style: .warning, accessory: box) == 0 else { return }
        var args = ["remove"]
        if box.state == .on { args.append("--delete-local") }
        runAsync(args + [n]) { r in
            if !r.ok { alert("Odebrání se nepovedlo", r.errorText, style: .warning) }
            self.refresh()
        }
    }

    @objc func help() {
        alert("Jak SFTP Drive funguje",
              """
              Ve Finderu je složka „SFTP Drive“ a v ní pro každý server obyčejná složka (jako u Google Disku). Soubory jsou na disku, takže fungují i bez internetu, a synchronizují se oběma směry.

              • Co do složky nakopíruješ, nahraje se na server.
              • Co v ní smažeš, smaže se i na serveru.
              • Když se soubor změní na obou stranách, nic se neztratí – starší verze se uloží jako „soubor.konflikt1“.

              Které složky ze serveru se stahují, vybereš v menu → „Vybrat synchronizované složky…“ (nebo pravým tlačítkem ve Finderu). Co odškrtneš, smaže se jen z Macu – na serveru zůstane.

              Když vypadne internet, pracuj dál normálně. Soubory, které ještě nejsou na serveru, mají ve Finderu oranžový štítek „Čeká na nahrání“ – po obnovení spojení se samy nahrají a štítek zmizí.

              Tip: vyber ve Finderu složku „SFTP Drive“ a stiskni ⌃⌘T – bude v postranním panelu.

              Ikonka v liště: ✓ synchronizováno · ↻ probíhá · ⚠ chyba · přeškrtnutý obláček = server nedostupný.
              """)
    }

    @objc func toggleLogin() {
        setLogin(!loginEnabled)
        rebuildMenu()
    }

    @objc func uninstall() {
        let box = NSButton(checkboxWithTitle: "Smazat i místní offline kopie", target: nil, action: nil)
        guard alert("Odinstalovat SFTP Drive?",
                    "Odpojí všechny servery a odstraní nastavení i hesla z Klíčenky. Soubory na serveru zůstanou beze změny.",
                    buttons: ["Odinstalovat", "Zrušit"], style: .warning, accessory: box) == 0 else { return }
        timer?.invalidate()
        let del = box.state == .on
        let names = conns.map { $0.name }
        DispatchQueue.global().async {
            for n in names { _ = runScript(["remove"] + (del ? ["--delete-local"] : []) + [n]) }
            let r = runScript(["uninstall"])
            _ = runTool("/usr/bin/pluginkit", ["-e", "ignore", "-i", finderExtID])
            if let a = self.appexPath { _ = runTool("/usr/bin/pluginkit", ["-r", a]) }
            DispatchQueue.main.async {
                self.setLogin(false)
                UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "cz.sftpdrive.app")
                self.item.isVisible = false
                // aplikaci samu přesunout do Koše
                NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, err in
                    alert(r.ok ? "SFTP Drive je odinstalovaný" : "Odinstalace skončila s chybou",
                          (r.ok ? "Synchronizace je vypnutá a aplikace je v Koši." : r.errorText) +
                          (err == nil ? "" : "\n\nAplikaci přetáhni do Koše ručně."))
                    exit(0)
                }
            }
        }
    }

    @objc func quit() {
        if alert("Ukončit ikonku?", "Synchronizace poběží dál na pozadí. Ikonku znovu spustíš otevřením aplikace SFTP Drive.",
              buttons: ["Ukončit", "Zrušit"]) == 0 { NSApp.terminate(nil) }
    }

    // opětovné otevření aplikace (dvojklik, když už běží)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !ready { return false }
        if conns.isEmpty { showAdd() } else { item.button?.performClick(nil) }
        return false
    }
}

// MARK: - Start

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
