// ScreenPin 图标生成器：swift tools/make-icon.swift
// 产出 Resources/icon-1024.png（再用 tools/make-icns.sh 生成 ScreenPin.icns）
import AppKit
import Foundation

let canvas: CGFloat = 1024
let outDir = "Resources"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("无图形上下文") }

// ---------- 背景：squircle + 糖果渐变 ----------
let iconRect = CGRect(x: 112, y: 112, width: 800, height: 800)
let corner = iconRect.width * 0.2237
let squircle = NSBezierPath(roundedRect: iconRect, xRadius: corner, yRadius: corner)

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.37, green: 0.70, blue: 1.00, alpha: 1), // #5EB1FF 青蓝
    NSColor(calibratedRed: 0.48, green: 0.42, blue: 1.00, alpha: 1), // #7B6CFF 蓝紫
    NSColor(calibratedRed: 0.71, green: 0.36, blue: 1.00, alpha: 1)  // #B45CFF 紫
])!
ctx.saveGState()
squircle.addClip()
gradient.draw(in: squircle, angle: -45)
ctx.restoreGState()

// ---------- 选区虚线框（抠图）----------
let marqueeRect = iconRect.insetBy(dx: 148, dy: 168)
let marquee = NSBezierPath(roundedRect: marqueeRect, xRadius: 40, yRadius: 40)
NSColor.white.withAlphaComponent(0.9).setStroke()
marquee.lineWidth = 14
marquee.lineCapStyle = .round
marquee.setLineDash([30, 22], count: 2, phase: 0)
marquee.stroke()

// ---------- 抠出来的小贴图（翘起 + 投影）----------
let snippetSize = CGSize(width: 300, height: 214)
let snippetCenter = CGPoint(x: marqueeRect.midX + 30, y: marqueeRect.midY + 10)
ctx.saveGState()
ctx.translateBy(x: snippetCenter.x, y: snippetCenter.y)
ctx.rotate(by: -9 * .pi / 180)
let local = CGRect(x: -snippetSize.width / 2, y: -snippetSize.height / 2,
                   width: snippetSize.width, height: snippetSize.height)
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30,
              color: NSColor.black.withAlphaComponent(0.30).cgColor)
NSColor.white.setFill()
NSBezierPath(roundedRect: local, xRadius: 26, yRadius: 26).fill()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// 贴图里的"图片内容"：小太阳 + 小山，俏皮一点
let contentColor = NSColor(calibratedRed: 0.48, green: 0.42, blue: 1.00, alpha: 1)
    .withAlphaComponent(0.75)
contentColor.setFill()
NSBezierPath(ovalIn: CGRect(x: local.minX + 34, y: local.maxY - 84, width: 44, height: 44)).fill()
let mountain = NSBezierPath()
mountain.move(to: CGPoint(x: local.minX + 26, y: local.minY + 26))
mountain.line(to: CGPoint(x: local.minX + 118, y: local.minY + 128))
mountain.line(to: CGPoint(x: local.minX + 176, y: local.minY + 60))
mountain.line(to: CGPoint(x: local.minX + 224, y: local.minY + 118))
mountain.line(to: CGPoint(x: local.maxX - 26, y: local.minY + 26))
mountain.close()
mountain.fill()
ctx.restoreGState()

// ---------- 小剪刀（斜放在选框角上）----------
let symConfig = NSImage.SymbolConfiguration(pointSize: 150, weight: .bold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let scissors = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
    .withSymbolConfiguration(symConfig) {
    let scSize = CGSize(width: 170, height: 170)
    let scCenter = CGPoint(x: marqueeRect.maxX + 6, y: marqueeRect.minY - 14)
    ctx.saveGState()
    ctx.translateBy(x: scCenter.x, y: scCenter.y)
    ctx.rotate(by: 18 * .pi / 180)
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18,
                  color: NSColor.black.withAlphaComponent(0.25).cgColor)
    scissors.draw(in: CGRect(x: -scSize.width / 2, y: -scSize.height / 2,
                             width: scSize.width, height: scSize.height))
    ctx.restoreGState()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG 编码失败")
}
try png.write(to: URL(fileURLWithPath: "\(outDir)/icon-1024.png"))
print("OK -> \(outDir)/icon-1024.png")
