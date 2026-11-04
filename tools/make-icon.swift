// Renders the app icon: an LED wall of panels with a snaking data run.
// Usage: swift tools/make-icon.swift LEDWallTool/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func draw(_ ctx: CGContext, _ S: CGFloat) {
    let u = S / 1024
    // macOS icon grid: 824 pt rounded square centered in 1024.
    let tile = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 28 * u, color: rgb(0x000000, 0.45))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x0B0E14)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0x1B2232), rgb(0x07090E)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // The wall: 4 × 3 panels with a slight gap, warm-to-cool across the columns.
    let cols = 4, rows = 3
    let wall = CGRect(x: tile.minX + 128 * u, y: tile.minY + 210 * u, width: 568 * u, height: 426 * u)
    let gap = 14 * u
    let pw = (wall.width - gap * CGFloat(cols - 1)) / CGFloat(cols), ph = (wall.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
    let colors: [UInt32] = [0x4F8CFF, 0x7B6CFF, 0xC86BFA, 0xFF7A59]
    func panel(_ c: Int, _ r: Int) -> CGRect {
        CGRect(x: wall.minX + CGFloat(c) * (pw + gap), y: wall.minY + CGFloat(r) * (ph + gap), width: pw, height: ph)
    }
    for c in 0..<cols {
        for r in 0..<rows {
            let p = panel(c, r)
            let path = CGPath(roundedRect: p, cornerWidth: 14 * u, cornerHeight: 14 * u, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 40 * u, color: rgb(colors[c], 0.55))
            ctx.addPath(path); ctx.setFillColor(rgb(colors[c], (c + r) % 2 == 0 ? 0.95 : 0.78)); ctx.fillPath()
            ctx.restoreGState()
            // LED pixel texture.
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            let dot = 11 * u
            var y = p.minY + dot
            while y < p.maxY {
                var x = p.minX + dot
                while x < p.maxX { ctx.setFillColor(rgb(0xFFFFFF, 0.13)); ctx.fillEllipse(in: CGRect(x: x - 2.5 * u, y: y - 2.5 * u, width: 5 * u, height: 5 * u)); x += dot * 2 }
                y += dot * 2
            }
            ctx.restoreGState()
        }
    }

    // Data run: a vertical snake (N pattern) through every panel, starting bottom-left.
    var pts: [CGPoint] = []
    for c in 0..<cols {
        let order = c % 2 == 0 ? Array(0..<rows) : Array((0..<rows).reversed())
        for r in order { let p = panel(c, r); pts.append(CGPoint(x: p.midX, y: p.midY)) }
    }
    let run = CGMutablePath()
    run.addLines(between: pts)
    ctx.setLineJoin(.round); ctx.setLineCap(.round)
    ctx.addPath(run); ctx.setStrokeColor(rgb(0x000000, 0.55)); ctx.setLineWidth(30 * u); ctx.strokePath()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 22 * u, color: rgb(0xFFFFFF, 0.9))
    ctx.addPath(run); ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(15 * u); ctx.strokePath()
    ctx.restoreGState()
    // Home-run port and arrowhead.
    let start = pts.first!, end = pts.last!
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: start.x - 26 * u, y: start.y - 26 * u, width: 52 * u, height: 52 * u))
    ctx.setFillColor(rgb(0x2ED573)); ctx.fillEllipse(in: CGRect(x: start.x - 15 * u, y: start.y - 15 * u, width: 30 * u, height: 30 * u))
    let a = CGMutablePath()
    a.move(to: CGPoint(x: end.x, y: end.y - 46 * u))
    a.addLine(to: CGPoint(x: end.x - 30 * u, y: end.y + 8 * u))
    a.addLine(to: CGPoint(x: end.x + 30 * u, y: end.y + 8 * u))
    a.closeSubpath()
    ctx.addPath(a); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()

    // Cable from the processor below the wall into the first panel.
    let cable = CGMutablePath()
    cable.move(to: CGPoint(x: start.x, y: start.y - 26 * u))
    cable.addLine(to: CGPoint(x: start.x, y: tile.minY + 120 * u))
    ctx.addPath(cable); ctx.setStrokeColor(rgb(0x2ED573)); ctx.setLineWidth(12 * u); ctx.strokePath()
    let proc = CGRect(x: start.x - 66 * u, y: tile.minY + 72 * u, width: 300 * u, height: 62 * u)
    ctx.addPath(CGPath(roundedRect: proc, cornerWidth: 14 * u, cornerHeight: 14 * u, transform: nil))
    ctx.setFillColor(rgb(0x2A3346)); ctx.fillPath()
    for i in 0..<6 {
        ctx.setFillColor(rgb(i == 0 ? 0x2ED573 : 0x5B6B88))
        ctx.fill(CGRect(x: proc.minX + 28 * u + CGFloat(i) * 42 * u, y: proc.midY - 9 * u, width: 26 * u, height: 18 * u))
    }

    // Glass highlight.
    let hl = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
    ctx.restoreGState()

    ctx.addPath(shape); ctx.setStrokeColor(rgb(0xFFFFFF, 0.12)); ctx.setLineWidth(2 * u); ctx.strokePath()
}

var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx, CGFloat(px))
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(out.path)")
