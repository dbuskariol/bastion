import AppKit
import Foundation

// Generates AppIcon.icns for Bastion via Core Graphics.
//
// Concept (per dual-model-consensus design):
//   - Background: rounded-corner square (Apple's 22.5% radius), vertical
//     linear gradient from slate (#1B2730) to teal (#0E5E63) — evokes
//     fortress stone and the night sky over a curtain wall.
//   - Foreground: a stylised "key" glyph in soft gold (#C2A14A) with three
//     small network nodes orbiting it — a key with a constellation. Says
//     "SSH keys, connected hosts" without being literal.
//
// Output: App/AppIcon.iconset/ (10 PNGs) → iconutil -c icns → App/AppIcon.icns

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("App/AppIcon.iconset", isDirectory: true)
let output = root.appendingPathComponent("App/AppIcon.icns")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [(name: String, size: Int, scale: Int)] = [
    ("icon_16x16.png", 16, 1),
    ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1),
    ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1),
    ("icon_512x512@2x.png", 512, 2)
]

func drawIcon(side: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: side, height: side)

    // Background rounded square with gradient.
    let cornerRadius = side * 0.225
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    bgPath.addClip()

    let gradient = NSGradient(starting: NSColor(red: 0.106, green: 0.153, blue: 0.188, alpha: 1.0),
                              ending: NSColor(red: 0.055, green: 0.369, blue: 0.388, alpha: 1.0))
    gradient?.draw(in: rect, angle: 270)

    // Subtle highlight ring at the top.
    let ringRect = NSRect(x: side * 0.05, y: side * 0.95, width: side * 0.9, height: 1)
    NSColor(white: 1.0, alpha: 0.08).setFill()
    ringRect.fill()

    // Gold key body (a horizontal pill with a tooth).
    let goldColour = NSColor(red: 0.761, green: 0.631, blue: 0.290, alpha: 1.0)
    let goldShadow = NSShadow()
    goldShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    goldShadow.shadowOffset = NSSize(width: 0, height: -side * 0.012)
    goldShadow.shadowBlurRadius = side * 0.04
    goldShadow.set()

    let keyHeadCentre = NSPoint(x: side * 0.30, y: side * 0.50)
    let keyHeadRadius = side * 0.115
    let keyHeadRect = NSRect(
        x: keyHeadCentre.x - keyHeadRadius,
        y: keyHeadCentre.y - keyHeadRadius,
        width: keyHeadRadius * 2,
        height: keyHeadRadius * 2
    )
    let keyHead = NSBezierPath(ovalIn: keyHeadRect)
    goldColour.setFill()
    keyHead.fill()

    // Inner hole in the key head (subtracted via fill with bg gradient colour mid-stop).
    let holeRadius = side * 0.045
    let holeRect = NSRect(
        x: keyHeadCentre.x - holeRadius,
        y: keyHeadCentre.y - holeRadius,
        width: holeRadius * 2,
        height: holeRadius * 2
    )
    let hole = NSBezierPath(ovalIn: holeRect)
    NSColor(red: 0.082, green: 0.265, blue: 0.290, alpha: 1.0).setFill()
    hole.fill()

    // Key shaft.
    let shaftRect = NSRect(
        x: keyHeadCentre.x + keyHeadRadius * 0.85,
        y: keyHeadCentre.y - side * 0.035,
        width: side * 0.35,
        height: side * 0.07
    )
    goldColour.setFill()
    let shaft = NSBezierPath(rect: shaftRect)
    shaft.fill()

    // Key teeth.
    let tooth1 = NSBezierPath(rect: NSRect(
        x: shaftRect.maxX - side * 0.06,
        y: keyHeadCentre.y - side * 0.085,
        width: side * 0.025,
        height: side * 0.05
    ))
    tooth1.fill()
    let tooth2 = NSBezierPath(rect: NSRect(
        x: shaftRect.maxX - side * 0.115,
        y: keyHeadCentre.y - side * 0.105,
        width: side * 0.025,
        height: side * 0.07
    ))
    tooth2.fill()

    // Three orbiting nodes forming a constellation (top-right of the canvas).
    NSShadow().set()
    let nodeColour = NSColor(red: 0.95, green: 0.85, blue: 0.55, alpha: 0.95)
    let nodes: [NSPoint] = [
        NSPoint(x: side * 0.72, y: side * 0.78),
        NSPoint(x: side * 0.83, y: side * 0.62),
        NSPoint(x: side * 0.66, y: side * 0.58)
    ]
    let nodeRadius = side * 0.03

    // Connecting lines first (under the nodes).
    let connectColour = NSColor(red: 0.95, green: 0.85, blue: 0.55, alpha: 0.5)
    connectColour.setStroke()
    let edges = NSBezierPath()
    edges.lineWidth = side * 0.012
    edges.move(to: nodes[0]); edges.line(to: nodes[1])
    edges.move(to: nodes[1]); edges.line(to: nodes[2])
    edges.move(to: nodes[2]); edges.line(to: nodes[0])
    edges.stroke()

    nodeColour.setFill()
    for node in nodes {
        let nodeRect = NSRect(
            x: node.x - nodeRadius,
            y: node.y - nodeRadius,
            width: nodeRadius * 2,
            height: nodeRadius * 2
        )
        NSBezierPath(ovalIn: nodeRect).fill()
    }

    return image
}

for spec in specs {
    let pixels = spec.size * spec.scale
    let image = drawIcon(side: CGFloat(pixels))
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to render \(spec.name)")
    }
    try png.write(to: iconset.appendingPathComponent(spec.name))
}

try? FileManager.default.removeItem(at: output)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    fatalError("iconutil failed")
}
