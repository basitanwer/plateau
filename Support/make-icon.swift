// Renders the Plateau app icon: a minimal white battery, filled to the 80% limit,
// with a lightning bolt cut out of the fill, on a green squircle. Usage: swift make-icon.swift out.png
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Squircle background (Apple icon grid: 824pt body, 100pt margin)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.3))
ctx.addPath(squircle); ctx.setFillColor(rgb(0x14945F)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [rgb(0x5FE0A0), rgb(0x12865A)] as CFArray,
                                  locations: [0, 1])!,
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Battery: white outline + cap, solid fill up to 80%
let bat = CGRect(x: 362, y: 230, width: 300, height: 520)
let line: CGFloat = 34
ctx.addPath(CGPath(roundedRect: bat.insetBy(dx: line / 2, dy: line / 2), cornerWidth: 70, cornerHeight: 70, transform: nil))
ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(line); ctx.strokePath()
ctx.addPath(CGPath(roundedRect: CGRect(x: 457, y: 762, width: 110, height: 44), cornerWidth: 18, cornerHeight: 18, transform: nil))
ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()

let inner = bat.insetBy(dx: line + 22, dy: line + 22)
let fill = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height * 0.8)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.addPath(CGPath(roundedRect: fill, cornerWidth: 34, cornerHeight: 34, transform: nil))
ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
// bolt knocked out of the fill so the green shows through
let c = CGPoint(x: fill.midX, y: fill.midY)
let bolt: [CGPoint] = [(28, 120), (-70, -12), (-6, -12), (-28, -120), (70, 12), (6, 12)]
    .map { CGPoint(x: c.x + $0.0, y: c.y + $0.1) }
ctx.addLines(between: bolt); ctx.closePath()
ctx.setBlendMode(.clear); ctx.fillPath()
ctx.endTransparencyLayer()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
