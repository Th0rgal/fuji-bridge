// Draws the Fuji Bridge app icon: a flat, geometric Mount Fuji in ink on dark gold.
//
//     swift tools/icon.swift FujiBridge/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// 1024 × 1024, opaque (the App Store refuses an alpha channel). iOS and macOS apply the rounded mask.
import AppKit
import CoreGraphics

let size = 1024.0
let args = CommandLine.arguments.dropFirst()
let out = args.first { !$0.hasPrefix("--") } ?? "AppIcon.png"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Work top-down, like a design tool.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

let ink = rgb(0x1B1510)
let cream = rgb(0xF4E9CF)

// Background: one dark gold, barely lighter at the top so it reads as metal rather than paint.
let gold = CGGradient(colorsSpace: space, colors: [rgb(0xC9A04C), rgb(0xA87E32)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gold, start: CGPoint(x: size / 2, y: 0), end: CGPoint(x: size / 2, y: size), options: [])

// Geometry: a symmetric cone, flat crater, sides drawn in slightly so it is Fuji and not a pyramid.
let foot = 742.0, summit = 330.0
let baseHalf = 372.0, topHalf = 88.0
let cx = size / 2

let mountain = CGMutablePath()
mountain.move(to: CGPoint(x: cx - baseHalf, y: foot))
mountain.addQuadCurve(to: CGPoint(x: cx - topHalf, y: summit), control: CGPoint(x: cx - 170, y: 600))
mountain.addLine(to: CGPoint(x: cx + topHalf, y: summit))
mountain.addQuadCurve(to: CGPoint(x: cx + baseHalf, y: foot), control: CGPoint(x: cx + 170, y: 600))
mountain.closeSubpath()

ctx.setFillColor(ink)
ctx.addPath(mountain)
ctx.fillPath()

// Snow: the top of the cone, ending in three soft scallops.
ctx.saveGState()
ctx.addPath(mountain)
ctx.clip()
let snowLine = 468.0, dip = 40.0
// Where the flank crosses the snow line, so the outer scallops start exactly on the slope.
func flankHalfWidth(at y: Double) -> Double {
    var lo = 0.0, hi = 1.0
    for _ in 0..<40 {
        let t = (lo + hi) / 2
        let yt = (1 - t) * (1 - t) * foot + 2 * t * (1 - t) * 600 + t * t * summit
        if yt > y { lo = t } else { hi = t }
    }
    let t = (lo + hi) / 2
    return (1 - t) * (1 - t) * baseHalf + 2 * t * (1 - t) * 170 + t * t * topHalf
}
let half = flankHalfWidth(at: snowLine)
let left = cx - half, right = cx + half
let snow = CGMutablePath()
snow.move(to: CGPoint(x: left - 200, y: 0))
snow.addLine(to: CGPoint(x: right + 200, y: 0))
snow.addLine(to: CGPoint(x: right + 200, y: snowLine))
snow.addLine(to: CGPoint(x: right, y: snowLine))
let bumps = 3
let step = (right - left) / Double(bumps)
for i in 0..<bumps {
    let x0 = right - Double(i) * step
    let x1 = x0 - step
    snow.addQuadCurve(to: CGPoint(x: x1, y: snowLine), control: CGPoint(x: (x0 + x1) / 2, y: snowLine + dip * 2))
}
snow.addLine(to: CGPoint(x: left - 200, y: snowLine))
snow.closeSubpath()
ctx.setFillColor(cream)
ctx.addPath(snow)
ctx.fillPath()
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
