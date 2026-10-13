//
//  ResultRenderer.swift
//  MikkeAnswer
//

import CoreGraphics

/// 検出結果を元画像に重ねて描画する（間違いに⭕️、必要なら絵の範囲を点線で）。
nonisolated enum ResultRenderer {

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

        let lineWidth = max(3, CGFloat(min(width, height)) * 0.006)

        if showsRegions {
            context.setStrokeColor(red: 0.1, green: 0.45, blue: 1, alpha: 0.85)
            context.setLineWidth(lineWidth * 0.6)
            context.setLineDash(phase: 0, lengths: [lineWidth * 3, lineWidth * 2])
            context.stroke(result.regionA)
            context.stroke(result.regionB)
            context.setLineDash(phase: 0, lengths: [])
        }

        for difference in result.differences {
            for center in [difference.centerA, difference.centerB] {
                let r = difference.radius
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                // 白い縁取りでどんな背景でも見やすくする
                context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.9)
                context.setLineWidth(lineWidth * 1.8)
                context.strokeEllipse(in: rect)
                context.setStrokeColor(red: 0.95, green: 0.1, blue: 0.15, alpha: 1)
                context.setLineWidth(lineWidth)
                context.strokeEllipse(in: rect)
            }
        }
        return context.makeImage()
    }
}
