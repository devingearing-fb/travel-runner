#!/usr/bin/env swift
import AppKit

let sizes: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

func renderIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.22

    // Background gradient
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    let gradient = NSGradient(
        starting: NSColor(red: 0.08, green: 0.12, blue: 0.30, alpha: 1.0),
        ending: NSColor(red: 0.10, green: 0.28, blue: 0.42, alpha: 1.0)
    )!
    gradient.draw(in: path, angle: -45)

    // Subtle border
    let borderPath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor(white: 1.0, alpha: 0.1).setStroke()
    borderPath.lineWidth = size > 64 ? 1.5 : 0.5
    borderPath.stroke()

    // Draw suitcase symbol as white
    let symbolSize = size * 0.48
    let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "suitcase.rolling.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {

        let imgSize = symbol.size
        let x = (size - imgSize.width) / 2
        let y = (size - imgSize.height) / 2
        symbol.draw(in: NSRect(x: x, y: y, width: imgSize.width, height: imgSize.height),
                    from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconsetPath = "AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try! fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for (name, size) in sizes {
    let rep = renderIcon(size: size)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name).png"))
    print("  ✓ \(name).png")
}

print("  Converting to .icns...")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetPath]
try! task.run()
task.waitUntilExit()

try? fm.removeItem(atPath: iconsetPath)
print("  ✓ AppIcon.icns created")
