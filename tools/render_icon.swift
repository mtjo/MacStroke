import AppKit

// Renders the MacStroke app icon (macOS rounded-square tile + gesture stroke).
// Usage: swift tools/render_icon.swift <output.png> [pixelSize]
// The 1024 master is the source of truth; tools/make_icon.sh derives the iconset from it.

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/MacStrokeIcon.png"
let size = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2]) ?? 1024) : 1024

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write("cannot allocate bitmap\n".data(using: .utf8)!)
    exit(1)
}
context.imageInterpolation = .high
NSGraphicsContext.current = context

/// Apple's macOS icon grid: the tile is 824pt of the 1024pt canvas.
let side = size * 0.8047
let tile = NSRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: side * 0.225, yRadius: side * 0.225)

context.saveGraphicsState()
tilePath.addClip()
NSGradient(starting: NSColor(srgbRed: 0.99, green: 0.995, blue: 1.0, alpha: 1),
           ending: NSColor(srgbRed: 0.86, green: 0.90, blue: 0.97, alpha: 1))?.draw(in: tile, angle: -90)
context.restoreGraphicsState()

/// The stroke ramp the app itself draws gestures with (GestureStrokeRenderer),
/// with its washed-out mint end pulled back down to teal: at 16px the pale half
/// of the stroke disappears into the light tile.
func rampColor(_ t: CGFloat) -> NSColor {
    NSColor(red: 0.45 * t, green: 0.47 + 0.43 * t, blue: 0.9 - 0.04 * t, alpha: 1)
}

// A five-point zigzag that reads as an "M" — MacStroke's initial and a drawn stroke.
let controlPoints: [(CGFloat, CGFloat)] = [(0.24, 0.30), (0.40, 0.72), (0.56, 0.44), (0.68, 0.70), (0.80, 0.34)]
let steps = max(180, Int(90 * size / 1024))
var points: [CGPoint] = []
for s in 0...steps {
    let t = CGFloat(s) / CGFloat(steps) * CGFloat(controlPoints.count - 1)
    let i = min(Int(t), controlPoints.count - 2)
    let f = t - CGFloat(i)
    points.append(CGPoint(x: tile.minX + (controlPoints[i].0 + (controlPoints[i + 1].0 - controlPoints[i].0) * f) * tile.width,
                          y: tile.minY + (controlPoints[i].1 + (controlPoints[i + 1].1 - controlPoints[i].1) * f) * tile.height))
}

let total = CGFloat(points.count - 1)
let lineWidth = size * 0.075
for i in 0..<points.count - 1 {
    let path = NSBezierPath()
    path.lineWidth = lineWidth
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    rampColor(CGFloat(i) / total).setStroke()
    path.move(to: points[i])
    path.line(to: points[i + 1])
    path.stroke()
}

// The pen tip, same accent dot the replay animation draws.
if let tip = points.last {
    let radius = lineWidth * 0.62
    NSColor(srgbRed: 0.16, green: 0.45, blue: 0.95, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2)).fill()
}

context.flushGraphics()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: output))
print(output)
