// Draws Ground Control's icon — a radar scope in the dashboard's palette — into an
// .iconset folder that `iconutil` turns into AppIcon.icns.
//
//   GroundControlIcon <out.iconset>
//
// Original artwork drawn with Core Graphics, on purpose: Apple's SF Symbols licence does
// not allow the symbols in app icons. Pure CoreGraphics + ImageIO, so it also runs on a
// headless CI runner.
import CoreGraphics
import Foundation
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: GroundControlIcon <out.iconset>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: arguments[1], isDirectory: true)

// iconutil's required file names → pixel size.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ stops: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops as CFArray, locations: nil)!
}

/// Draws on Apple's 1024-point macOS icon grid: an 824-point rounded square, centred,
/// with room around it for the shadow.
func drawIcon(in ctx: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    // Hairlines vanish at 16 px: never thinner than one output pixel.
    func line(_ points: CGFloat) -> CGFloat { max(points, 1 / scale) }

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.45))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x0f1115))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0x222937), color(0x0c0e12)]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // The scope.
    let c = CGPoint(x: 512, y: 512)
    let r: CGFloat = 316
    let disc = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    ctx.saveGState()
    ctx.addEllipse(in: disc)
    ctx.clip()
    ctx.drawRadialGradient(
        gradient([color(0x173d2e), color(0x0b1912)]),
        startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])

    // The sweep turns clockwise, as a scope's does, so its afterglow fades out on the
    // counter-clockwise side of the leading edge (y points up here: larger angle = behind).
    let lead = CGFloat.pi / 4
    let span = CGFloat.pi / 2.1
    let slices = 90
    for i in 0..<slices {
        let t = CGFloat(i) / CGFloat(slices)
        let start = lead + span * t
        let end = lead + span * (t + 1 / CGFloat(slices))
        ctx.move(to: c)
        ctx.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false)
        ctx.closePath()
        ctx.setFillColor(color(0x36c08f, 0.55 * pow(1 - t, 1.7)))
        ctx.fillPath()
    }

    // Range rings and crosshair.
    ctx.setStrokeColor(color(0x36c08f, 0.30))
    ctx.setLineWidth(line(5))
    for k in 1...3 {
        let rr = r * CGFloat(k) / 4
        ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
    }
    ctx.setStrokeColor(color(0x36c08f, 0.22))
    ctx.setLineWidth(line(4))
    ctx.move(to: CGPoint(x: c.x - r, y: c.y))
    ctx.addLine(to: CGPoint(x: c.x + r, y: c.y))
    ctx.move(to: CGPoint(x: c.x, y: c.y - r))
    ctx.addLine(to: CGPoint(x: c.x, y: c.y + r))
    ctx.strokePath()

    // The leading edge of the sweep.
    ctx.setStrokeColor(color(0x9ff0cc, 0.95))
    ctx.setLineWidth(line(9))
    ctx.setLineCap(.round)
    ctx.move(to: c)
    ctx.addLine(to: CGPoint(x: c.x + r * cos(lead), y: c.y + r * sin(lead)))
    ctx.strokePath()

    // Contacts: one just swept (bright), one older (amber) — the dashboard's ok/warn.
    func blip(angle: CGFloat, distance: CGFloat, radius: CGFloat, hex: UInt32) {
        let p = CGPoint(x: c.x + r * distance * cos(angle), y: c.y + r * distance * sin(angle))
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: radius * 1.8, color: color(hex, 0.9))
        ctx.setFillColor(color(hex))
        ctx.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius))
        ctx.restoreGState()
    }
    blip(angle: lead + 0.30, distance: 0.62, radius: 22, hex: 0x8ff5c6)
    blip(angle: lead + 1.05, distance: 0.32, radius: 12, hex: 0x5fd2a0)
    blip(angle: lead + 2.60, distance: 0.50, radius: 17, hex: 0xf0b86e)
    ctx.restoreGState() // the disc clip

    // Scope rim and hub.
    ctx.setStrokeColor(color(0x5fd2a0, 0.85))
    ctx.setLineWidth(line(12))
    ctx.strokeEllipse(in: disc)
    ctx.setFillColor(color(0x9ff0cc))
    ctx.fillEllipse(in: CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22))
    ctx.restoreGState() // the body clip

    // A faint edge so the tile holds its shape on a dark Dock.
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(color(0xffffff, 0.08))
    ctx.setLineWidth(line(3))
    ctx.strokePath()
}

func render(pixels: Int) -> CGImage {
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("could not create a \(pixels)px bitmap context") }
    ctx.interpolationQuality = .high
    drawIcon(in: ctx, pixels: pixels)
    guard let image = ctx.makeImage() else { fatalError("could not render \(pixels)px") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { fatalError("cannot write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot finish \(url.path)") }
}

do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("cannot create \(outDir.path): \(error)\n".utf8))
    exit(1)
}
var rendered: [Int: CGImage] = [:]
for variant in variants {
    let image = rendered[variant.pixels] ?? render(pixels: variant.pixels)
    rendered[variant.pixels] = image
    writePNG(image, to: outDir.appendingPathComponent("\(variant.name).png"))
}
print("wrote \(variants.count) icon sizes to \(outDir.path)")
