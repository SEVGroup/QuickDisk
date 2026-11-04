import AppKit
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.15, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 208, yRadius: 208).fill()
let colors = [NSColor.systemIndigo, .systemCyan, .systemMint, .systemOrange, .systemPink, .systemPurple]
for (index, color) in colors.enumerated() {
    let arc = NSBezierPath(); arc.lineWidth = 62
    arc.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 316, startAngle: CGFloat(index * 60 + 3), endAngle: CGFloat(index * 60 + 57))
    color.setStroke(); arc.stroke()
}
let bolt = NSBezierPath()
bolt.move(to: NSPoint(x: 557, y: 769)); bolt.line(to: NSPoint(x: 346, y: 478)); bolt.line(to: NSPoint(x: 484, y: 478)); bolt.line(to: NSPoint(x: 442, y: 258)); bolt.line(to: NSPoint(x: 676, y: 568)); bolt.line(to: NSPoint(x: 534, y: 568)); bolt.close()
NSColor.systemOrange.setFill(); bolt.fill()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
