import AppKit
import Foundation

let output = CommandLine.arguments.dropFirst().first ?? "dmg-background.png"
let size = NSSize(width: 720, height: 420)
let image = NSImage(size: size)

image.lockFocus()

let bounds = NSRect(origin: .zero, size: size)
NSColor(calibratedRed: 0.965, green: 0.972, blue: 0.985, alpha: 1.0).setFill()
bounds.fill()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.99, green: 0.995, blue: 1.0, alpha: 1.0),
    NSColor(calibratedRed: 0.91, green: 0.935, blue: 0.975, alpha: 1.0)
])!
gradient.draw(in: bounds, angle: -24)

NSColor(calibratedRed: 0.18, green: 0.30, blue: 0.52, alpha: 0.22).setStroke()
let guide = NSBezierPath()
guide.move(to: NSPoint(x: 236, y: 214))
guide.line(to: NSPoint(x: 484, y: 214))
guide.lineWidth = 2
guide.setLineDash([8, 9], count: 2, phase: 0)
guide.stroke()

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 468, y: 227))
arrow.line(to: NSPoint(x: 488, y: 214))
arrow.line(to: NSPoint(x: 468, y: 201))
arrow.lineWidth = 2
arrow.stroke()

func drawText(_ text: String, at point: NSPoint, size fontSize: CGFloat, weight: NSFont.Weight, alpha: CGFloat, alignment: NSTextAlignment = .center) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
        .foregroundColor: NSColor(calibratedRed: 0.075, green: 0.095, blue: 0.135, alpha: alpha),
        .paragraphStyle: paragraph
    ]
    let rect = NSRect(x: point.x, y: point.y, width: 720 - point.x * 2, height: fontSize + 12)
    text.draw(in: rect, withAttributes: attrs)
}

drawText("Rift", at: NSPoint(x: 0, y: 336), size: 36, weight: .semibold, alpha: 0.96)
drawText("Arrastra la app a Aplicaciones", at: NSPoint(x: 0, y: 292), size: 22, weight: .medium, alpha: 0.82)
drawText("para instalar Rift en tu Mac", at: NSPoint(x: 0, y: 266), size: 14, weight: .regular, alpha: 0.54)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("No se pudo generar el fondo del DMG\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: output))
