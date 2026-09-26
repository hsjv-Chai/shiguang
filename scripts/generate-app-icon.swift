#!/usr/bin/env swift
import AppKit

// One set of vector geometry drives both editable SVG and pixel-aligned PNGs.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("assets/AppIcon")
let fm = FileManager.default
try fm.createDirectory(at: output.appendingPathComponent("AppIcon.iconset"), withIntermediateDirectories: true)
func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
struct VectorPath {
    let cg = CGMutablePath()
    var svg = ""
    mutating func move(_ x: CGFloat, _ y: CGFloat) { cg.move(to: CGPoint(x: x, y: y)); svg += "M\(x),\(y) " }
    mutating func line(_ x: CGFloat, _ y: CGFloat) { cg.addLine(to: CGPoint(x: x, y: y)); svg += "L\(x),\(y) " }
    mutating func curve(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        cg.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
        svg += "C\(x1),\(y1) \(x2),\(y2) \(x),\(y) "
    }
    mutating func close() { cg.closeSubpath(); svg += "Z " }
}
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> VectorPath {
    let k: CGFloat = 0.5522847498
    var p = VectorPath(); p.move(x+r,y); p.line(x+w-r,y)
    p.curve(x+w-r+r*k,y,x+w,y+r-r*k,x+w,y+r); p.line(x+w,y+h-r)
    p.curve(x+w,y+h-r+r*k,x+w-r+r*k,y+h,x+w-r,y+h); p.line(x+r,y+h)
    p.curve(x+r-r*k,y+h,x,y+h-r+r*k,x,y+h-r); p.line(x,y+r)
    p.curve(x,y+r-r*k,x+r-r*k,y,x+r,y); p.close(); return p
}
func basePath() -> VectorPath {
    // Continuous-curvature corners, with the optical inset used by legacy Mac icons.
    var p = VectorPath(); p.move(330,100); p.line(694,100)
    p.curve(864,100,924,160,924,330); p.line(924,694)
    p.curve(924,864,864,924,694,924); p.line(330,924)
    p.curve(160,924,100,864,100,694); p.line(100,330)
    p.curve(100,160,160,100,330,100); p.close(); return p
}
func render(_ pixels: Int, simple: Bool = false) throws -> (CGImage, String) {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(pixels)); ctx.scaleBy(x: CGFloat(pixels)/1024, y: -CGFloat(pixels)/1024)
    var svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
    <title>拾光 — 叠放相片</title>
    <defs>
      <linearGradient id="moss" x1="0" y1="0" x2="0.7" y2="1"><stop stop-color="#587863"/><stop offset="0.6" stop-color="#40614D"/><stop offset="1" stop-color="#344F40"/></linearGradient>
      <filter id="shadow" x="-30%" y="-30%" width="160%" height="170%"><feDropShadow dx="0" dy="12" stdDeviation="12" flood-color="#13291C" flood-opacity="0.22"/></filter>
    </defs>
    """
    func shape(_ path: VectorPath, _ hex: UInt32, shadow: Bool = false, gradient: Bool = false) {
        ctx.saveGState()
        if shadow && !simple { ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0x13291C).copy(alpha: 0.22)) }
        ctx.addPath(path.cg); ctx.setFillColor(color(hex)); ctx.fillPath(); ctx.restoreGState()
        if gradient && !simple {
            ctx.saveGState(); ctx.addPath(path.cg); ctx.clip()
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x587863),color(0x40614D),color(0x344F40)] as CFArray, locations: [0,0.6,1])!
            ctx.drawLinearGradient(g, start: CGPoint(x:100,y:100), end: CGPoint(x:677,y:924), options: [.drawsBeforeStartLocation,.drawsAfterEndLocation]); ctx.restoreGState()
        }
        let fill = gradient && !simple ? "url(#moss)" : String(format:"#%06X",hex)
        svg += "<path d=\"\(path.svg)\" fill=\"\(fill)\"\(shadow && !simple ? " filter=\"url(#shadow)\"" : "")/>\n"
    }
    func beginRotation(_ degrees: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        ctx.saveGState(); ctx.translateBy(x:x,y:y); ctx.rotate(by:degrees * .pi / 180); ctx.translateBy(x:-x,y:-y)
        svg += "<g transform=\"rotate(\(degrees) \(x) \(y))\">\n"
    }
    func endGroup() { ctx.restoreGState(); svg += "</g>\n" }
    svg += "<g id=\"background\">\n"
    shape(basePath(),0x40614D,shadow:true,gradient:true); svg += "</g>\n<g id=\"foreground\">\n"
    beginRotation(-10,490,486)
    shape(rounded(252,242,476,478,34),0xC6D3C4,shadow:true)
    endGroup()
    beginRotation(simple ? 0 : 5,536,550)
    shape(rounded(294,306,484,478,34),0xF5F2EA,shadow:true)
    let window = rounded(330,342,412,332,14)
    shape(window,0xDCE4D5)
    ctx.saveGState(); ctx.addPath(window.cg); ctx.clip()
    svg += "<defs><clipPath id=\"photo-window\"><path d=\"\(window.svg)\"/></clipPath></defs><g clip-path=\"url(#photo-window)\">\n"
    let radius: CGFloat = simple ? 43 : 34
    shape(rounded(614-radius,421-radius,radius*2,radius*2,radius),0xE8CC8D)
    var mountain = VectorPath(); mountain.move(313,638); mountain.line(439,469); mountain.curve(446,460,453,460,461,470)
    mountain.line(610,654); mountain.line(610,700); mountain.line(313,700); mountain.close()
    shape(mountain,0x8FA98C)
    var near = VectorPath(); near.move(421,688); near.line(624,497); near.curve(631,490,640,490,647,498)
    near.line(762,609); near.line(762,700); near.line(421,700); near.close()
    shape(near,0x40614D)
    endGroup(); endGroup(); svg += "</g>\n</svg>\n"
    return (ctx.makeImage()!,svg)
}
func writePNG(_ image: CGImage, _ url: URL) throws {
    let rep = NSBitmapImageRep(cgImage:image)
    try rep.representation(using:.png,properties:[:])!.write(to:url)
}
let (master, svg) = try render(1024)
try writePNG(master,output.appendingPathComponent("AppIcon-1024.png"))
try svg.write(to:output.appendingPathComponent("AppIcon.svg"),atomically:true,encoding:.utf8)
for points in [16,32,128,256,512] {
    for scale in [1,2] {
        let suffix = scale == 1 ? "" : "@2x"
        let (image,_) = try render(points*scale,simple:points <= 32)
        try writePNG(image,output.appendingPathComponent("AppIcon.iconset/icon_\(points)x\(points)\(suffix).png"))
    }
}
// Native-size specimens on light and dark backgrounds, plus large artwork.
let width = 1536, height = 1152
let preview = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
preview.translateBy(x:0,y:CGFloat(height)); preview.scaleBy(x:1,y:-1)
for row in 0..<2 {
    preview.setFillColor(color(row == 0 ? 0xF2F1EE : 0x202923)); preview.fill(CGRect(x:0,y:row*576,width:width,height:576))
    var x: CGFloat = 24
    for size in [16,32,64,128,256,512] {
        let (image,_) = try render(size,simple:size <= 64)
        let y = CGFloat(row*576) + (576-CGFloat(size))/2
        preview.saveGState(); preview.translateBy(x:x,y:y+CGFloat(size)); preview.scaleBy(x:1,y:-1)
        preview.draw(image,in:CGRect(x:0,y:0,width:size,height:size)); preview.restoreGState()
        x += CGFloat(size)+48
    }
}
try writePNG(preview.makeImage()!,output.appendingPathComponent("AppIcon-preview.png"))
print("Generated SVG, PNG, iconset and preview in \(output.path)")
