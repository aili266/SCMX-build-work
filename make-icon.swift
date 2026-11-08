import AppKit

guard CommandLine.arguments.count > 1 else { exit(1) }
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor(calibratedRed: 0.04, green: 0.10, blue: 0.18, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect.insetBy(dx: 18, dy: 18), xRadius: 190, yRadius: 190).fill()
    NSColor(calibratedRed: 0.08, green: 0.75, blue: 0.95, alpha: 1).setStroke()
    let chip = NSBezierPath(roundedRect: NSRect(x: 280, y: 300, width: 464, height: 424), xRadius: 70, yRadius: 70)
    chip.lineWidth = 38; chip.stroke()
    NSColor.white.setStroke()
    let inner = NSBezierPath(roundedRect: NSRect(x: 365, y: 385, width: 294, height: 254), xRadius: 35, yRadius: 35)
    inner.lineWidth = 22; inner.stroke()
    NSColor(calibratedRed: 1, green: 0.78, blue: 0.18, alpha: 1).setFill()
    let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: 545, y: 590)); arrow.line(to: NSPoint(x: 470, y: 465)); arrow.line(to: NSPoint(x: 530, y: 480)); arrow.line(to: NSPoint(x: 560, y: 405)); arrow.line(to: NSPoint(x: 635, y: 530)); arrow.line(to: NSPoint(x: 575, y: 515)); arrow.close(); arrow.fill()
    for x in stride(from: 220, through: 804, by: 117) {
        let pin = NSBezierPath(); pin.move(to: NSPoint(x: x, y: 745)); pin.line(to: NSPoint(x: x, y: 805)); pin.move(to: NSPoint(x: x, y: 279)); pin.line(to: NSPoint(x: x, y: 219)); pin.lineWidth = 24; pin.stroke()
    }
image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { exit(1) }
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
