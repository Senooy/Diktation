// Dessine l'icône « Écho clair » de Diktation et produit assets/AppIcon.icns.
//
//   swiftc -O scripts/make_icon.swift -o target/make_icon && target/make_icon && \
//   iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
//
// Le dessin est défini sur une grille de 100 unités (comme la planche de
// logos), posé dans le gabarit des icônes macOS : corps de 824 px dans un
// canevas de 1024 px, avec l'ombre du Dock. Chaque taille est tracée en
// vectoriel à sa résolution, sans réduction d'image.

import AppKit
import CoreGraphics

let ink = CGColor(red: 0x25 / 255, green: 0x22 / 255, blue: 0x1D / 255, alpha: 1)
let indigo = CGColor(red: 0x46 / 255, green: 0x3F / 255, blue: 0xA6 / 255, alpha: 1)

/// Carré arrondi continu (même tracé que la planche : 'M50 0C78 0 88 0 94 6S…').
func squircle() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 50, y: 0))
    let curves: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (78, 0, 88, 0, 94, 6), (100, 12, 100, 22, 100, 50), (100, 78, 100, 88, 94, 94),
        (88, 100, 78, 100, 50, 100), (22, 100, 12, 100, 6, 94), (0, 88, 0, 78, 0, 50),
        (0, 22, 0, 12, 6, 6), (12, 0, 22, 0, 50, 0),
    ]
    for c in curves {
        p.addCurve(to: CGPoint(x: c.4, y: c.5), control1: CGPoint(x: c.0, y: c.1), control2: CGPoint(x: c.2, y: c.3))
    }
    p.closeSubpath()
    return p
}

func capsule(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: min(w, h) / 2, cornerHeight: min(w, h) / 2, transform: nil)
}

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Gabarit macOS : corps de 824/1024, centré.
    let body = size * 824 / 1024
    let origin = (size - body) / 2
    let unit = body / 100
    // Repère SVG (y vers le bas) dans le corps.
    ctx.translateBy(x: origin, y: size - origin)
    ctx.scaleBy(x: unit, y: -unit)

    // Ombre du Dock, puis fond dégradé blanc → blanc chaud.
    let shape = squircle()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -1.2), blur: 2.6, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        CGColor(red: 0xF3 / 255, green: 0xF1 / 255, blue: 0xEC / 255, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100), options: [])
    ctx.restoreGState()

    // Liseré fin.
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(red: 11 / 255, green: 10 / 255, blue: 9 / 255, alpha: 0.10))
    ctx.setLineWidth(max(0.35, 1.0 / unit))
    ctx.strokePath()

    // Ondes : anneaux réguliers (8 unités d'écart) autour de la barre, de
    // plus en plus pâles. En très petit, le dernier disparaît et les traits
    // épaississent.
    let small = pixels <= 32
    let opacities: [CGFloat] = [0.55, 0.32, 0.16]
    for k in 1...3 {
        if small && k == 3 { continue }
        let gap = 8 * CGFloat(k)
        ctx.addPath(capsule(45.5 - gap, 33 - gap, 9 + 2 * gap, 34 + 2 * gap))
        ctx.setStrokeColor(ink.copy(alpha: opacities[k - 1] * (small ? 1.25 : 1))!)
        ctx.setLineWidth(small ? 3.4 : 2.4)
        ctx.strokePath()
    }

    // Barre centrale à l'encre, cœur indigo.
    ctx.addPath(capsule(45.5, 33, 9, 34))
    ctx.setFillColor(ink)
    ctx.fillPath()
    ctx.addPath(capsule(47.4, 44, 5.2, 12))
    ctx.setFillColor(indigo)
    ctx.fillPath()

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let dir = URL(fileURLWithPath: "assets/AppIcon.iconset")
try? fm.removeItem(at: dir)
try fm.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(pixels: base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(pixels: 1024).write(to: URL(fileURLWithPath: "assets/AppIcon.png"))
print("OK → assets/AppIcon.iconset, assets/AppIcon.png")
