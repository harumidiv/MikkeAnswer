//
//  ResultRenderer.swift
//  MikkeAnswer
//

import CoreGraphics
import CoreText
import Foundation

/// 検出結果の描画
/// - comparison: 位置合わせ済みの 2 枚を並べ（横長の絵は上下、縦長の絵は左右）、2 枚目の絵の間違いに⭕️と番号を付ける
/// - overview  : 傾き補正後の写真に、検出した 2 つの絵の範囲を点線で描く
nonisolated enum ResultRenderer {

    private static let red = CGColor(srgbRed: 1, green: 0.08, blue: 0.2, alpha: 1)
    private static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let shadow = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)

    /// 左右の絵の間の余白（絵の幅に対する割合）
    private static let gapRatio: CGFloat = 0.03

    static func renderComparison(result: DetectionResult) -> CGImage? {
        let a = result.alignedA, b = result.alignedB
        // 横長の絵は上下、縦長の絵は左右に並べる（縦向きの画面で大きく表示できるように）
        let stacked = a.width > a.height
        let gap = (CGFloat(stacked ? a.height : a.width) * gapRatio).rounded()
        let offsetB = stacked ? CGPoint(x: 0, y: CGFloat(a.height) + gap) : CGPoint(x: CGFloat(a.width) + gap, y: 0)
        let width = stacked ? a.width : a.width * 2 + Int(gap)
        let height = stacked ? a.height * 2 + Int(gap) : a.height
        guard let context = makeContext(width: width, height: height) else { return nil }

        // CGContext は左下原点なので、上端からの位置を y に直して描く
        context.setFillColor(white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(a, in: CGRect(x: 0, y: height - a.height, width: a.width, height: a.height))
        context.draw(b, in: CGRect(x: offsetB.x, y: CGFloat(height) - offsetB.y - CGFloat(b.height),
                                   width: CGFloat(b.width), height: CGFloat(b.height)))

        // 以降は左上原点のピクセル座標で描く
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        // 画面に縮小表示しても太く見えるよう、画像サイズに比例させる
        let lineWidth = max(4, CGFloat(max(width, height)) * 0.006)
        for (index, difference) in result.differences.enumerated() {
            // 両方に付けると見比べにくいので、⭕️は 2 枚目の絵にだけ付ける
            let center = CGPoint(x: difference.center.x + offsetB.x, y: difference.center.y + offsetB.y)
            let r = markerRadius(for: difference, imageWidth: a.width, imageHeight: a.height)
            drawMarker(in: context, center: center, radius: r, lineWidth: lineWidth, number: index + 1)
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
