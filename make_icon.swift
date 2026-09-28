import AppKit

// Renders a 1024px app icon: Claude-orange squircle with a cream starburst.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824px squircle centered in 1024 canvas
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1).setFill()
bg.fill()
ctx.restoreGState()

// Starburst: tapered rays of varying length, slightly irregular like the Claude mark
let c = CGPoint(x: size / 2, y: size / 2)
let lengths: [CGFloat] = [1.0, 0.82, 0.95, 0.78, 1.0, 0.86, 0.93, 0.8, 0.98, 0.84, 0.9, 0.79]
let R: CGFloat = 300
NSColor(red: 0.98, green: 0.95, blue: 0.91, alpha: 1).setFill()
for (i, l) in lengths.enumerated() {
    let a = CGFloat(i) * .pi / 6 + .pi / 14
    let outer = R * l
    let wBase: CGFloat = 34, wTip: CGFloat = 16
    let dir = CGPoint(x: cos(a), y: sin(a)), n = CGPoint(x: -sin(a), y: cos(a))
    let p = NSBezierPath()
    let b = CGPoint(x: c.x + dir.x * 40, y: c.y + dir.y * 40)
    let t = CGPoint(x: c.x + dir.x * outer, y: c.y + dir.y * outer)
    p.move(to: CGPoint(x: b.x + n.x * wBase / 2, y: b.y + n.y * wBase / 2))
    p.line(to: CGPoint(x: t.x + n.x * wTip / 2, y: t.y + n.y * wTip / 2))
    p.appendArc(withCenter: t, radius: wTip / 2, startAngle: (a * 180 / .pi) + 90, endAngle: (a * 180 / .pi) - 90, clockwise: true)
    p.line(to: CGPoint(x: b.x - n.x * wBase / 2, y: b.y - n.y * wBase / 2))
    p.close()
    p.fill()
}
NSBezierPath(ovalIn: CGRect(x: c.x - 62, y: c.y - 62, width: 124, height: 124)).fill()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
