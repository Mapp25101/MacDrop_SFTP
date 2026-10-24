// sftpdrive-tag add|remove <soubor>… (nebo "-" = seznam souborů ze vstupu, jeden na řádek)
// Přidá / odebere oranžový štítek „Čeká na nahrání“. Ostatní štítky souboru zachová.

import Foundation

let tagName = "Čeká na nahrání"
let entry = tagName + "\n7"                       // 7 = oranžová barva štítku ve Finderu
let key = "com.apple.metadata:_kMDItemUserTags"

func readTags(_ p: String) -> [String] {
    let n = getxattr(p, key, nil, 0, 0, 0)
    guard n > 0 else { return [] }
    var d = Data(count: n)
    let r = d.withUnsafeMutableBytes { getxattr(p, key, $0.baseAddress, n, 0, 0) }
    guard r > 0 else { return [] }
    return (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String] ?? []
}

func writeTags(_ p: String, _ tags: [String]) {
    if tags.isEmpty { removexattr(p, key, 0); return }
    guard let d = try? PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0) else { return }
    _ = d.withUnsafeBytes { setxattr(p, key, $0.baseAddress, d.count, 0, 0) }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first, mode == "add" || mode == "remove" else {
    FileHandle.standardError.write("použití: sftpdrive-tag add|remove <soubor>… | -\n".data(using: .utf8)!)
    exit(2)
}
var paths = Array(args.dropFirst())
if paths == ["-"] {
    paths = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
}
for p in paths where FileManager.default.fileExists(atPath: p) {
    var tags = readTags(p)
    let has = tags.contains { $0 == tagName || $0.hasPrefix(tagName + "\n") }
    if mode == "add" && !has { tags.append(entry); writeTags(p, tags) }
    if mode == "remove" && has { tags.removeAll { $0 == tagName || $0.hasPrefix(tagName + "\n") }; writeTags(p, tags) }
}
