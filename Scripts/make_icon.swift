// 生成 PDFChat 应用图标
// 用法: swift Scripts/make_icon.swift <size> <output.png>
// 所有几何坐标基于 1024×1024 画布,按输出尺寸等比缩放。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3, let size = Int(args[1]), size > 0 else {
    fputs("用法: swift make_icon.swift <size> <output.png>\n", stderr)
    exit(1)
}
let outputURL = URL(fileURLWithPath: args[2])
let s = CGFloat(size) / 1024.0

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            a,
        ]
    )!
}

func scaled(_ v: CGFloat) -> CGFloat { v * s }

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(
        roundedRect: CGRect(
            x: scaled(x), y: scaled(y), width: scaled(w), height: scaled(h)
        ),
        cornerWidth: scaled(r), cornerHeight: scaled(r), transform: nil
    )
}

func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat, color: CGColor) {
    ctx.setFillColor(color)
    ctx.addPath(roundedRect(x, y, w, h, radius))
    ctx.fillPath()
}

// MARK: - 配色
let blueTop = rgba(0x5CB0FF)
let blueBottom = rgba(0x1560D4)
let paperWhite = rgba(0xFDFEFF)
let foldGray = rgba(0xDDE3EE)
let lineGray = rgba(0xC9D2E0)
let highlightYellow = rgba(0xFFE94D)
let dotBlue = rgba(0x2F7CF6)

// MARK: - 1. 底板 squircle (100,100,824,824) 圆角 185
let plateRect = CGRect(x: scaled(100), y: scaled(100), width: scaled(824), height: scaled(824))
let platePath = CGPath(
    roundedRect: plateRect, cornerWidth: scaled(185.4), cornerHeight: scaled(185.4), transform: nil
)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: scaled(-18)), blur: scaled(36), color: rgba(0x000000, 0.30))
ctx.setFillColor(rgba(0x2F6FD8))
ctx.addPath(platePath)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: space,
    colors: [blueTop, blueBottom] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: scaled(512), y: scaled(924)),
    end: CGPoint(x: scaled(512), y: scaled(100)),
    options: []
)
// 底部渐暗,增加体积感
let shade = CGGradient(
    colorsSpace: space,
    colors: [rgba(0x000000, 0.0), rgba(0x000000, 0.16)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    shade,
    start: CGPoint(x: scaled(512), y: scaled(480)),
    end: CGPoint(x: scaled(512), y: scaled(100)),
    options: []
)
ctx.restoreGState()

// 内描边高光
ctx.saveGState()
ctx.addPath(platePath)
ctx.setStrokeColor(rgba(0xFFFFFF, 0.22))
ctx.setLineWidth(scaled(3))
ctx.strokePath()
ctx.restoreGState()

// MARK: - 2. PDF 纸张 (260,270)-(680,810),右上折角 84
let paper = CGMutablePath()
paper.move(to: CGPoint(x: scaled(260), y: scaled(810)))
paper.addLine(to: CGPoint(x: scaled(596), y: scaled(810)))
paper.addLine(to: CGPoint(x: scaled(680), y: scaled(726)))
paper.addLine(to: CGPoint(x: scaled(680), y: scaled(270)))
paper.addLine(to: CGPoint(x: scaled(260), y: scaled(270)))
paper.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: scaled(-14)), blur: scaled(28), color: rgba(0x0A2A66, 0.35))
ctx.setFillColor(paperWhite)
ctx.addPath(paper)
ctx.fillPath()
ctx.restoreGState()

// 折角翻面
let fold = CGMutablePath()
fold.move(to: CGPoint(x: scaled(596), y: scaled(810)))
fold.addLine(to: CGPoint(x: scaled(680), y: scaled(726)))
fold.addLine(to: CGPoint(x: scaled(596), y: scaled(726)))
fold.closeSubpath()
ctx.setFillColor(foldGray)
ctx.addPath(fold)
ctx.fillPath()

// 纸上的文字行:其中第三行带荧光黄高亮
bar(296, 566, 276, 46, radius: 10, color: highlightYellow)
bar(300, 726, 340, 26, radius: 13, color: lineGray)
bar(300, 651, 340, 26, radius: 13, color: lineGray)
bar(304, 578, 264, 26, radius: 13, color: rgba(0x8A93A6))
bar(300, 501, 340, 26, radius: 13, color: lineGray)
bar(300, 426, 220, 26, radius: 13, color: lineGray)

// MARK: - 3. 聊天气泡 (570,300)-(856,470) + 左下尾巴
let bubble = roundedRect(570, 300, 286, 170, 85)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: scaled(-10)), blur: scaled(24), color: rgba(0x0A2A66, 0.30))
ctx.setFillColor(rgba(0xFFFFFF))
ctx.addPath(bubble)
ctx.fillPath()
ctx.restoreGState()

// 尾巴后画,直接叠在气泡底边上,保证无缝衔接
let tail = CGMutablePath()
tail.move(to: CGPoint(x: scaled(614), y: scaled(250)))
tail.addLine(to: CGPoint(x: scaled(700), y: scaled(330)))
tail.addLine(to: CGPoint(x: scaled(748), y: scaled(322)))
tail.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: scaled(-8)), blur: scaled(14), color: rgba(0x0A2A66, 0.20))
ctx.setFillColor(rgba(0xFFFFFF))
ctx.addPath(tail)
ctx.fillPath()
ctx.restoreGState()

// 气泡内三个"正在输入"圆点
for dx in [0.0, 62.0, 124.0] {
    let dot = CGRect(
        x: scaled(660 + dx - 21), y: scaled(385 - 21), width: scaled(42), height: scaled(42)
    )
    ctx.setFillColor(dotBlue)
    ctx.fillEllipse(in: dot)
}

// MARK: - 输出 PNG
guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
          outputURL as CFURL, UTType.png.identifier as CFString, 1, nil
      )
else {
    fputs("写入 PNG 失败: \(outputURL.path)\n", stderr)
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("已生成 \(outputURL.path) (\(size)x\(size))")
