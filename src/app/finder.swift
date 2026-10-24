// SFTP Drive – rozšíření Finderu: položky SFTP Drive v menu pravého tlačítka (výběr složek, uvolnit místo).
// (Ikonky u souborů Finder bez vývojářského certifikátu Apple nezobrazí – stav ukazují štítky a ikonka v liště.)
// Běží v sandboxu, jen čte nastavení z ~/.config/sftpdrive; akce posílá hlavní aplikaci přes odkaz sftpdrive://…

import Cocoa
import FinderSync

let realHome = String(cString: getpwuid(getuid())!.pointee.pw_dir!)
let confRoot = realHome + "/.config/sftpdrive"
let fm = FileManager.default

func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

/// Hodnota z config souboru (zapsaná přes bash printf %q).
func unquote(_ v: String) -> String {
    if v == "''" { return "" }
    var out = "", single = false, esc = false
    for c in v {
        if single { if c == "'" { single = false } else { out.append(c) }; continue }
        if esc { out.append(c); esc = false; continue }
        switch c {
        case "'": single = true
        case "\\": esc = true
        default: out.append(c)
        }
    }
    return out
}

struct Conn {
    let name: String
    let mountDir: String      // prázdné = online složka vypnutá
    let offlineDir: String
    let rules: [(pinned: Bool, path: String)]

    static func loadAll() -> [Conn] {
        guard let names = try? fm.contentsOfDirectory(atPath: confRoot) else { return [] }
        return names.compactMap { name in
            let dir = confRoot + "/" + name
            guard let cfg = try? String(contentsOfFile: dir + "/config", encoding: .utf8) else { return nil }
            var kv: [String: String] = [:]
            for line in cfg.split(separator: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                kv[String(line[..<eq])] = unquote(String(line[line.index(after: eq)...]))
            }
            let txt = (try? String(contentsOfFile: dir + "/offline.list", encoding: .utf8)) ?? ""
            let rules = txt.split(separator: "\n").compactMap { l -> (Bool, String)? in
                l.count > 2 ? (l.hasPrefix("+"), nfc(String(l.dropFirst(2)))) : nil
            }
            return Conn(name: name, mountDir: nfc(kv["MOUNT_ENABLED"] == "1" ? kv["MOUNT_DIR"] ?? "" : ""),
                        offlineDir: nfc(kv["OFFLINE_DIR"] ?? ""), rules: rules)
        }
    }

    /// Stejná logika jako ve skriptu: rozhoduje nejkonkrétnější pravidlo.
    func isPinned(_ rel: String) -> Bool {
        var best: Bool? = nil, bestLen = -1
        for r in rules where r.path == "/" || rel == r.path || rel.hasPrefix(r.path + "/") {
            let len = r.path == "/" ? 0 : r.path.count
            if len > bestLen { best = r.pinned; bestLen = len }
        }
        return best ?? false
    }
}

func rel(_ path: String, in base: String) -> String? {
    guard !base.isEmpty else { return nil }
    if path == base { return "/" }
    return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count)) : nil
}

@objc(SFTPDriveFinderSync)
final class SFTPDriveFinderSync: FIFinderSync {
    var chosenConn = ""

    override init() {
        super.init()
        // celá ~/SFTP Drive – menu pak funguje i u serverů přidaných později
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: realHome + "/SFTP Drive"),
                                                          URL(fileURLWithPath: realHome + "/SFTP")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else { return nil }
        let conns = Conn.loadAll()
        var canPin = false, canUnpin = false, online = false
        var owner: Conn? = nil
        for u in urls {
            let p = nfc(u.path)
            for c in conns {
                if let r = rel(p, in: c.mountDir) {
                    owner = c; online = true
                    if c.isPinned(r) { canUnpin = true } else { canPin = true }
                } else if let r = rel(p, in: c.offlineDir) {
                    owner = c
                    if r != "/" && c.isPinned(r) { canUnpin = true }
                }
            }
        }
        guard let conn = owner else { return nil }
        chosenConn = conn.name
        let m = NSMenu(title: "")
        if canPin {
            let i = m.addItem(withTitle: "Ponechat offline (SFTP)", action: #selector(pin(_:)), keyEquivalent: "")
            i.image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: nil)
        }
        if canUnpin {
            let i = m.addItem(withTitle: "Přestat synchronizovat – uvolnit místo (SFTP)", action: #selector(unpin(_:)), keyEquivalent: "")
            i.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: nil)
        }
        let ch = m.addItem(withTitle: "Vybrat synchronizované složky… (SFTP)", action: #selector(choose(_:)), keyEquivalent: "")
        ch.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)
        if online && urls.count == 1 {
            let i = m.addItem(withTitle: "Zobrazit v druhé složce (SFTP)", action: #selector(reveal(_:)), keyEquivalent: "")
            i.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
        }
        return m
    }

    @objc func pin(_ sender: AnyObject?) { send("pin") }
    @objc func unpin(_ sender: AnyObject?) { send("unpin") }
    @objc func reveal(_ sender: AnyObject?) { send("reveal") }
    @objc func choose(_ sender: AnyObject?) {
        var comps = URLComponents()
        comps.scheme = "sftpdrive"
        comps.host = "choose"
        comps.queryItems = [URLQueryItem(name: "c", value: chosenConn)]
        if let u = comps.url { NSWorkspace.shared.open(u) }
    }

    func send(_ cmd: String) {
        guard let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else { return }
        var comps = URLComponents()
        comps.scheme = "sftpdrive"
        comps.host = cmd
        comps.queryItems = urls.map { URLQueryItem(name: "p", value: $0.path) }
        if let u = comps.url { NSWorkspace.shared.open(u) }
    }
}
