// Genera AppIcon.icns con el icono de SaySo en la rejilla de los iconos Pepebits:
// campo tinta, unas comillas de bloques en hueso («say») y el bit rojo («so»).
// El mismo dibujo está en assets/brand/sayso-icon.svg.
// Uso: swift scripts/make-icon.swift <carpeta-de-salida>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    // Margen del lienzo de iconos de macOS (~10 %); dentro, la rejilla de 120 con el origen arriba.
    let margin = CGFloat(px) * 0.1
    let side = CGFloat(px) - margin * 2
    let u = side / 120
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: margin + x * u, y: margin + (120 - y - h) * u, width: w * u, height: h * u)
    }
    ctx.setFillColor(color(0x1c1b1b)); ctx.fill(rect(0, 0, 120, 120))
    ctx.setFillColor(color(0xfcf9f8))
    for x: CGFloat in [26, 50] { ctx.fill(rect(x, 30, 18, 32)); ctx.fill(rect(x, 62, 9, 16)) }
    ctx.setFillColor(color(0xff3e3e)); ctx.fill(rect(74, 70, 20, 20))
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512),
                   ("512x512@2x", 1024)] {
    try render(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
