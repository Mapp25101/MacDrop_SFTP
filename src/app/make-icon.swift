// Renders the app icon (1024×1024 PNG) – a blue rounded square with a white cloud.
import AppKit
let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.62, blue: 1.0, alpha: 1),
           ending: NSColor(calibratedRed: 0.05, green: 0.33, blue: 0.80, alpha: 1))!.draw(in: path, angle: -90)
func sym(_ n: String, _ pt: CGFloat, _ color: NSColor, _ center: NSPoint) {
    guard let s = NSImage(systemSymbolName: n, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: pt, weight: .semibold)) else { return }
    let t = NSImage(size: s.size, flipped: false) { r in s.draw(in: r); color.set(); r.fill(using: .sourceAtop); return true }
    t.draw(in: NSRect(x: center.x - s.size.width/2, y: center.y - s.size.height/2, width: s.size.width, height: s.size.height))
}
sym("cloud.fill", 430, .white, NSPoint(x: 512, y: 540))
sym("arrow.triangle.2.circlepath", 170, NSColor(calibratedRed: 0.08, green: 0.40, blue: 0.88, alpha: 1), NSPoint(x: 512, y: 505))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
