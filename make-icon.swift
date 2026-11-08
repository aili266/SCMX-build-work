import AppKit

guard CommandLine.arguments.count == 2 else { exit(1) }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(deviceRed:CGFloat((hex >> 16) & 255)/255,green:CGFloat((hex >> 8) & 255)/255,blue:CGFloat(hex & 255)/255,alpha:alpha)
}
func box(_ rect: NSRect, _ radius: CGFloat, _ fill: NSColor) {
    fill.setFill(); NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius).fill()
}
func gradient(_ rect: NSRect, _ radius: CGFloat, _ top: NSColor, _ bottom: NSColor) {
    NSGradient(starting:bottom,ending:top)!.draw(in:NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius),angle:90)
}
func outline(_ rect: NSRect, _ radius: CGFloat, _ ink: NSColor, _ width: CGFloat) {
    let p = NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius); p.lineWidth = width; ink.setStroke(); p.stroke()
}
func line(_ points: [NSPoint], _ ink: NSColor, _ width: CGFloat) {
    let p = NSBezierPath(); p.move(to:points[0]); points.dropFirst().forEach { p.line(to:$0) }
    p.lineWidth = width; p.lineCapStyle = .round; p.lineJoinStyle = .round; ink.setStroke(); p.stroke()
}
func polygon(_ points: [NSPoint], _ ink: NSColor) {
    let p = NSBezierPath(); p.move(to:points[0]); points.dropFirst().forEach { p.line(to:$0) }; p.close(); ink.setFill(); p.fill()
}
func shadow(_ blur: CGFloat, _ offset: NSSize, _ alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow(); s.shadowBlurRadius = blur; s.shadowOffset = offset; s.shadowColor = .black.withAlphaComponent(alpha); s.set()
    draw(); NSGraphicsContext.restoreGraphicsState()
}
func plate() {
    shadow(20,NSSize(width:0,height:-9),0.16) { box(NSRect(x:58,y:58,width:908,height:908),198,color(0xE4E9EF)) }
    gradient(NSRect(x:58,y:66,width:908,height:900),198,color(0xFEFEFF),color(0xE4E9EF))
    outline(NSRect(x:61,y:69,width:902,height:894),195,NSColor.white.withAlphaComponent(0.18),3)
}
func chip(_ rect: NSRect, _ body: NSColor, _ pins: NSColor, _ rim: NSColor) {
    let size = rect.width, spacing = size/6, pinWidth = size*0.078, length = size*0.13
    for n in 1...5 {
        let d = CGFloat(n)*spacing
        box(NSRect(x:rect.minX-length,y:rect.minY+d-pinWidth/2,width:length+5,height:pinWidth),6,pins)
        box(NSRect(x:rect.maxX-5,y:rect.minY+d-pinWidth/2,width:length+5,height:pinWidth),6,pins)
        box(NSRect(x:rect.minX+d-pinWidth/2,y:rect.minY-length,width:pinWidth,height:length+5),6,pins)
        box(NSRect(x:rect.minX+d-pinWidth/2,y:rect.maxY-5,width:pinWidth,height:length+5),6,pins)
    }
    shadow(24,NSSize(width:0,height:-16),0.2) { box(rect,48,rim) }
    box(rect.insetBy(dx:12,dy:12),39,body)
}
func download(_ center: NSPoint, _ scale: CGFloat, _ ink: NSColor) {
    func p(_ x:CGFloat,_ y:CGFloat) -> NSPoint { NSPoint(x:center.x+x*scale,y:center.y+y*scale) }
    polygon([p(-25,120),p(25,120),p(25,12),p(76,12),p(0,-66),p(-76,12),p(-25,12)],ink)
    line([p(-98,-74),p(-98,-109),p(98,-109),p(98,-74)],ink,21*scale)
}
func bolt(_ rect: NSRect, _ ink: NSColor) {
    let x=rect.minX,y=rect.minY,w=rect.width,h=rect.height
    polygon([NSPoint(x:x+w*0.57,y:y+h),NSPoint(x:x+w*0.04,y:y+h*0.40),NSPoint(x:x+w*0.41,y:y+h*0.40),NSPoint(x:x+w*0.24,y:y),NSPoint(x:x+w*0.98,y:y+h*0.64),NSPoint(x:x+w*0.59,y:y+h*0.64)],ink)
}
func probe() {
    shadow(35,NSSize(width:0,height:-22),0.26) {
        gradient(NSRect(x:389,y:697,width:246,height:184),26,color(0xF4F7F9),color(0xBBC6D1))
        box(NSRect(x:328,y:174,width:368,height:567),75,color(0xAE4818))
    }
    for x in [434,548] {
        box(NSRect(x:x,y:780,width:46,height:64),22,color(0x26333D))
        box(NSRect(x:x+10,y:821,width:11,height:12),5,color(0xF8FCFF,0.88))
    }
    gradient(NSRect(x:345,y:198,width:334,height:520),62,color(0xFFB14D),color(0xE56C22))
    chip(NSRect(x:416,y:437,width:192,height:192),color(0x15211E),color(0x87CDB9),color(0x4F746A))
    bolt(NSRect(x:474,y:470,width:83,height:126),color(0x7AF0CB))
    download(NSPoint(x:512,y:320),0.55,color(0xF2F9F6))
}
func terminalWindow() {
    let frame = NSRect(x:205,y:276,width:614,height:481)
    shadow(28,NSSize(width:0,height:-19),0.22) { gradient(frame,81,color(0x333940),color(0x171C22)) }
    outline(frame.insetBy(dx:11,dy:11),71,color(0xFFFFFF,0.19),3)
    line([NSPoint(x:236,y:644),NSPoint(x:788,y:644)],color(0x55606B),3)
    for (x,c) in [(267,UInt32(0xFF746B)),(307,UInt32(0xF6D663)),(347,UInt32(0x72D2A1))] { box(NSRect(x:x,y:683,width:21,height:21),10,color(c)) }
    line([NSPoint(x:296,y:555),NSPoint(x:389,y:473),NSPoint(x:296,y:391)],color(0xF7F9FA),35)
    line([NSPoint(x:453,y:392),NSPoint(x:542,y:392)],color(0xF7F9FA),31)
    download(NSPoint(x:667,y:486),0.75,color(0xFFE477))
}

let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
NSColor.clear.setFill(); NSRect(x:0,y:0,width:1024,height:1024).fill(using:.copy)
plate()
NSGraphicsContext.saveGraphicsState()
let terminal = NSAffineTransform()
terminal.translateX(by:106,yBy:331); terminal.scale(by:1.14); terminal.translateX(by:-205,yBy:-276); terminal.concat()
terminalWindow()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
let device = NSAffineTransform()
device.translateX(by:775,yBy:282); device.rotate(byDegrees:20); device.scale(by:0.48); device.translateX(by:-512,yBy:-512); device.concat()
probe()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using:.png,properties:[:]), png.count > 10_000 else { exit(1) }
try png.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
