//
//  ResultRenderer.swift
//  MikkeAnswer
//

import CoreGraphics
import CoreText
import Foundation

/// 検出結果を元画像に重ねて描画する（右（下）の絵の間違いに⭕️と番号、必要なら絵の範囲を点線で）。
nonisolated enum ResultRenderer {

    private static let red = CGColor(srgbRed: 1, green: 0.08, blue: 0.2, alpha: 1)
    private static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let shadow = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)

    static func render(source: CGImage, result: DetectionResult, showsRegions: Bool) -> CGImage? {
        let width = source.width, height = source.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 以降は左上原点のピクセル座標で描く
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        // 画面に縮小表示しても太く見えるよう、画像サイズに比例させる
        let shortSide = CGFloat(min(width, height))
        let lineWidth = max(6, shortSide * 0.014)

        if showsRegions {
            context.setStrokeColor(red: 0.1, green: 0.45, blue: 1, alpha: 0.85)
            context.setLineWidth(lineWidth * 0.4)
            context.setLineDash(phase: 0, lengths: [lineWidth * 2, lineWidth * 1.5])
            context.stroke(result.regionA)
            context.stroke(result.regionB)
            context.setLineDash(phase: 0, lengths: [])
        }

        for (index, difference) in result.differences.enumerated() {
            let r = markerRadius(for: difference, imageWidth: width, imageHeight: height)
            // 両方に付けると見比べにくいので、⭕️は右（下）の絵にだけ付ける
            drawMarker(in: context, center: difference.centerB, radius: r, lineWidth: lineWidth, number: index + 1)
        }
        return context.makeImage()
    }

    /// 描画する⭕️の半径（小さな間違いでも見えるよう最小値を設ける）
    static func markerRadius(for difference: PuzzleDifference, imageWidth: Int, imageHeight: Int) -> CGFloat {
        max(difference.radius, CGFloat(min(imageWidth, imageHeight)) * 0.045)
    }

    private static func drawMarker(in context: CGContext, center: CGPoint, radius r: CGFloat,
                                   lineWidth: CGFloat, number: Int) {
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)

        // 薄い赤の塗りで範囲を強調
        context.setFillColor(red: 1, green: 0.1, blue: 0.2, alpha: 0.15)
        context.fillEllipse(in: rect)

        // 影付きの白い縁取り → 赤い太線（どんな背景でも見やすくする）
        context.saveGState()
        context.setShadow(offset: .zero, blur: lineWidth * 1.5, color: shadow)
        context.setStrokeColor(white)
        context.setLineWidth(lineWidth * 2)
        context.strokeEllipse(in: rect)
        context.restoreGState()

        context.setStrokeColor(red)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: rect)

        // 右上に番号バッジ（一覧の番号と対応する）
        let badgeRadius = max(lineWidth * 2.2, r * 0.32)
        let badgeCenter = CGPoint(x: center.x + r * 0.7071, y: center.y - r * 0.7071)
        let badgeRect = CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                               width: badgeRadius * 2, height: badgeRadius * 2)
        context.saveGState()
        context.setShadow(offset: .zero, blur: lineWidth, color: shadow)
        context.setFillColor(red)
        context.fillEllipse(in: badgeRect)
        context.restoreGState()
        context.setStrokeColor(white)
        context.setLineWidth(lineWidth * 0.5)
        context.strokeEllipse(in: badgeRect)
        drawNumber(number, in: context, center: badgeCenter, fontSize: badgeRadius * 1.25)
    }

    private static func drawNumber(_ number: Int, in context: CGContext, center: CGPoint, fontSize: CGFloat) {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(number)", attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

        context.saveGState()
        // 左上原点に反転したコンテキストなので、文字だけ上下を戻して描く
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y + bounds.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
