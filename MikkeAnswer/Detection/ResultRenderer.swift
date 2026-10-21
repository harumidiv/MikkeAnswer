//
//  ResultRenderer.swift
//  MikkeAnswer
//

import CoreGraphics
import CoreText
import Foundation

/// 検出結果の描画
/// - answer  : 位置合わせ済みの 2 枚目の絵に、間違いの⭕️と番号を付ける（答えだけを大きく見せる）
/// - overview  : 傾き補正後の写真に、検出した 2 つの絵の範囲を点線で描く
nonisolated enum ResultRenderer {

    private static let red = CGColor(srgbRed: 1, green: 0.08, blue: 0.2, alpha: 1)
    private static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let shadow = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)

    static func renderAnswer(result: DetectionResult) -> CGImage? {
        let b = result.alignedB
        // 画面に縮小表示しても太く見えるよう、画像サイズに比例させる
        let lineWidth = max(4, CGFloat(max(b.width, b.height)) * 0.006)
        // 端の間違いでも⭕️と番号が切れないよう、透明な余白を付ける
        let margin = Int((lineWidth * 5).rounded())
        let width = b.width + margin * 2, height = b.height + margin * 2
        guard let context = makeContext(width: width, height: height) else { return nil }
        context.draw(b, in: CGRect(x: margin, y: margin, width: b.width, height: b.height))

        // 以降は左上原点のピクセル座標で描く
        context.translateBy(x: CGFloat(margin), y: CGFloat(height - margin))
        context.scaleBy(x: 1, y: -1)

        for (index, difference) in result.differences.enumerated() {
            let r = markerRadius(for: difference, imageWidth: b.width, imageHeight: b.height)
            drawMarker(in: context, center: difference.center, radius: r, lineWidth: lineWidth, number: index + 1,
                       fillBounds: CGRect(x: 0, y: 0, width: b.width, height: b.height))
        }
        return context.makeImage()
    }

    static func renderOverview(result: DetectionResult) -> CGImage? {
        let image = result.straightenedImage
        let width = image.width, height = image.height
        guard let context = makeContext(width: width, height: height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let lineWidth = max(3, CGFloat(min(width, height)) * 0.006)
        context.setStrokeColor(red: 0.1, green: 0.45, blue: 1, alpha: 0.9)
        context.setLineWidth(lineWidth)
        context.setLineDash(phase: 0, lengths: [lineWidth * 3, lineWidth * 2])
        for corners in [result.regionA, result.regionB] where corners.count == 4 {
            context.addLines(between: corners)
            context.closePath()
            context.strokePath()
        }
        return context.makeImage()
    }

    /// 描画する⭕️の半径（小さな間違いでも見えるよう最小値を設ける）
    static func markerRadius(for difference: PuzzleDifference, imageWidth: Int, imageHeight: Int) -> CGFloat {
        max(difference.radius, CGFloat(min(imageWidth, imageHeight)) * 0.045)
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func drawMarker(in context: CGContext, center: CGPoint, radius r: CGFloat,
                                   lineWidth: CGFloat, number: Int, fillBounds: CGRect) {
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)

        // 薄い赤の塗りで範囲を強調（絵の外の余白は塗らない）
        context.saveGState()
        context.clip(to: fillBounds)
        context.setFillColor(red: 1, green: 0.1, blue: 0.2, alpha: 0.15)
        context.fillEllipse(in: rect)
        context.restoreGState()

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

        // 右上に番号バッジ（一覧の番号と対応する）。大きな⭕️でもバッジが絵を隠さないよう上限を設ける
        let badgeRadius = min(max(lineWidth * 2.2, r * 0.32), lineWidth * 4)
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
