import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let bounds = CGRect(x: 45, y: 45, width: 934, height: 934)
        let shape = CGPath(roundedRect: bounds, cornerWidth: 220, cornerHeight: 220, transform: nil)
        context.addPath(shape)
        context.setFillColor(CGColor(red: 0.085, green: 0.12, blue: 0.21, alpha: 1))
        context.fillPath()
        let colors = [CGColor(red: 0.19, green: 0.39, blue: 0.58, alpha: 1), CGColor(red: 0.08, green: 0.18, blue: 0.29, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        context.saveGState()
        context.addEllipse(in: CGRect(x: 261, y: 261, width: 502, height: 502)); context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: 300, y: 740), end: CGPoint(x: 750, y: 250), options: [])
        context.restoreGState()
        context.translateBy(x: 512, y: 512)
        context.rotate(by: .pi / 6)
        context.setStrokeColor(CGColor(red: 0.42, green: 0.88, blue: 0.78, alpha: 1))
        context.setLineWidth(18)
        context.strokeEllipse(in: CGRect(x: -370, y: -155, width: 740, height: 310))
        context.setLineWidth(4)
        context.setStrokeColor(CGColor(red: 0.46, green: 0.69, blue: 0.91, alpha: 0.6))
        context.strokeEllipse(in: CGRect(x: -251, y: -251, width: 502, height: 502))
        context.setFillColor(CGColor(red: 0.65, green: 1, blue: 0.88, alpha: 1))
        context.fillEllipse(in: CGRect(x: 303, y: 66, width: 44, height: 44))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) else { fatalError("无法生成图标") }
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
