// 앱 아이콘 생성: 반사된 g (1024×1024 PNG)
// 사용법: swift make_icon.swift <출력 경로.png>
import AppKit
import CoreText

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S: CGFloat = 1024

func hex(_ v: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS 아이콘 그리드: 824px 본체 + 그림자
let inset: CGFloat = 100
let body = NSRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
hex(0xF1EFE8).setFill()
NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).fill()
NSGraphicsContext.restoreGraphicsState()

// 거울 축
let cx = S / 2
hex(0x85B7EB).setFill()
NSBezierPath(roundedRect: NSRect(x: cx - 4, y: 250, width: 8, height: 524), xRadius: 4, yRadius: 4).fill()

// g 글자
let fontSize: CGFloat = 480
let font = NSFont(name: "AvenirNext-UltraLight", size: fontSize)
    ?? NSFont.systemFont(ofSize: fontSize, weight: .ultraLight)

func line(_ color: NSColor) -> CTLine {
    let s = NSAttributedString(string: "g", attributes: [
        .font: font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
    ])
    return CTLineCreateWithAttributedString(s)
}

let dark = line(hex(0x2C2C2A))
let light = line(hex(0x85B7EB))
let b = CTLineGetImageBounds(dark, ctx)
let gap: CGFloat = 28
let x = cx - gap - (b.origin.x + b.width)
let y = S / 2 - (b.origin.y + b.height / 2)

// 왼쪽: 원본
ctx.textPosition = CGPoint(x: x, y: y)
CTLineDraw(dark, ctx)

// 오른쪽: 축 기준 좌우반전
ctx.saveGState()
ctx.translateBy(x: 2 * cx, y: 0)
ctx.scaleBy(x: -1, y: 1)
ctx.textPosition = CGPoint(x: x, y: y)
CTLineDraw(light, ctx)
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("아이콘 생성: \(out)")
