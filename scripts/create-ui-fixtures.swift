import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/private/tmp/myphotos-ui-fixtures")
let count = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 36
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
var samples: [Data] = []
for i in 0..<12 {
    let ctx = CGContext(data: nil, width: 480, height: 320, bitsPerComponent: 8, bytesPerRow: 480 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let palettes: [[CGFloat]] = [[0.68,0.77,0.70],[0.80,0.66,0.46],[0.48,0.63,0.73],[0.76,0.64,0.62]]
    let p = palettes[i % 4]
    ctx.setFillColor(red: p[0], green: p[1], blue: p[2], alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
    ctx.setFillColor(red: 0.98, green: 0.9, blue: 0.65, alpha: 1); ctx.fillEllipse(in: CGRect(x: 290-i*7, y: 205, width: 50, height: 50))
    for layer in 0..<3 {
        let shade = CGFloat(layer) * 0.06
        ctx.setFillColor(red: 0.2+shade, green: 0.34+shade, blue: 0.29+shade, alpha: 1)
        ctx.beginPath(); ctx.move(to: CGPoint(x: 0, y: 0)); ctx.addLine(to: CGPoint(x: 0, y: 40+layer*30)); ctx.addLine(to: CGPoint(x: 130+i*8, y: 190-layer*30)); ctx.addLine(to: CGPoint(x: 290, y: 60+layer*10)); ctx.addLine(to: CGPoint(x: 410, y: 160-layer*25)); ctx.addLine(to: CGPoint(x: 480, y: 80)); ctx.addLine(to: CGPoint(x: 480, y: 0)); ctx.closePath(); ctx.fillPath()
    }
    let data = NSMutableData(); let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: String(format: "%04d:%02d:%02d 12:34:56", 2023+i%4, 1+i%12, 1+i%27)], kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    precondition(CGImageDestinationFinalize(dest)); samples.append(data as Data)
}
for i in 0..<count { try samples[i%12].write(to: root.appendingPathComponent(String(format: "测试照片-%05d.jpg", i))) }
print("Generated \(count) synthetic JPEG fixtures at \(root.path)")
