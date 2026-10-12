import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Provide an iconset output directory") }
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func drawIcon(size: Int) throws -> Data {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let rect = NSRect(x: 36, y: 36, width: 952, height: 952)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220)
    let background = NSGradient(starting: NSColor(red: 0.19, green: 0.21, blue: 0.30, alpha: 1), ending: NSColor(red: 0.065, green: 0.075, blue: 0.12, alpha: 1))!
    background.draw(in: shape, angle: -70)
    NSColor(white: 1, alpha: 0.11).setStroke()
    shape.lineWidth = 3
    shape.stroke()

    // A pair of inset trays and a clean transfer arrow form the LoadSide mark.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 35
    shadow.shadowOffset = NSSize(width: 0, height: -15)
    shadow.set()
    let tray = NSBezierPath()
    tray.move(to: NSPoint(x: 247, y: 471))
    tray.line(to: NSPoint(x: 247, y: 272))
    tray.curve(to: NSPoint(x: 287, y: 232), controlPoint1: NSPoint(x: 247, y: 246), controlPoint2: NSPoint(x: 260, y: 232))
    tray.line(to: NSPoint(x: 737, y: 232))
    tray.curve(to: NSPoint(x: 777, y: 272), controlPoint1: NSPoint(x: 764, y: 232), controlPoint2: NSPoint(x: 777, y: 246))
    tray.line(to: NSPoint(x: 777, y: 471))
    tray.lineWidth = 57
    tray.lineCapStyle = .round
    tray.lineJoinStyle = .round
    NSColor(red: 0.47, green: 0.54, blue: 0.98, alpha: 1).setStroke()
    tray.stroke()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 512, y: 781))
    arrow.line(to: NSPoint(x: 512, y: 422))
    arrow.move(to: NSPoint(x: 362, y: 565))
    arrow.line(to: NSPoint(x: 512, y: 415))
    arrow.line(to: NSPoint(x: 662, y: 565))
    arrow.lineWidth = 65
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(red: 0.92, green: 0.94, blue: 1.0, alpha: 1).setStroke()
    arrow.stroke()
    NSShadow().set()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Unable to render icon") }
    return png
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let data = try drawIcon(size: points * scale)
        try data.write(to: destination.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
