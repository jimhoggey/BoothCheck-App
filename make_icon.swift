// Draws Booth Check's 1024 px icon: a dark booth-console tile with a warm stage-light glow and an
// amber tick. build.sh turns the PNG into AppIcon.icns. Usage: make_icon <out.png>

import AppKit

let side = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.current = ctx

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// macOS icon grid: an 824 px rounded tile centred in the 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
NSGradient(starting: rgb(40, 44, 54), ending: rgb(18, 20, 26))!.draw(in: shape, angle: -90)

// A soft beam of warm light falling from the top edge, clipped to the tile.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
let beam = NSBezierPath()
beam.move(to: NSPoint(x: 452, y: 924))
beam.line(to: NSPoint(x: 572, y: 924))
beam.line(to: NSPoint(x: 800, y: 180))
beam.line(to: NSPoint(x: 224, y: 180))
beam.close()
NSGradient(starting: rgb(255, 196, 92, 0.34), ending: rgb(255, 176, 32, 0.0))!.draw(in: beam, angle: -90)
NSGradient(colors: [rgb(255, 200, 110, 0.55), rgb(255, 176, 32, 0.0)])!
    .draw(fromCenter: NSPoint(x: 512, y: 924), radius: 0, toCenter: NSPoint(x: 512, y: 924), radius: 260, options: [])
NSGraphicsContext.restoreGraphicsState()

// The tick.
let tick = NSBezierPath()
tick.move(to: NSPoint(x: 322, y: 468))
tick.line(to: NSPoint(x: 452, y: 338))
tick.line(to: NSPoint(x: 712, y: 628))
tick.lineWidth = 96
tick.lineCapStyle = .round
tick.lineJoinStyle = .round
rgb(255, 176, 32).setStroke()
tick.stroke()

NSGraphicsContext.current = nil
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
