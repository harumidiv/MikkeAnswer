//
//  PuzzleSolverModel.swift
//  MikkeAnswer
//

import Observation
import UIKit

/// 一覧表示用の、間違い 1 箇所ぶんの切り抜き
struct DifferenceThumbnail: Identifiable {
    let id: Int
    let number: Int
    let imageA: UIImage
    let imageB: UIImage
    /// 右の絵の切り抜き内での間違いの中心（0〜1 の正規化座標）
    let markerCenterB: CGPoint
    /// 切り抜き画像の一辺に対する、間違いを囲む円の直径の割合
    let markerFraction: CGFloat
}

/// 範囲調整画面に渡す内容（四隅は image 上の座標：左上・右上・右下・左下）
struct RegionEditorRequest: Identifiable {
    let id = UUID()
    let image: CGImage
    let quadA: [CGPoint]
    let quadB: [CGPoint]
}

@Observable
final class PuzzleSolverModel {

    enum Phase: Equatable {
        case idle
        case processing
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var displayImage: UIImage?
    private(set) var result: DetectionResult?
    private(set) var thumbnails: [DifferenceThumbnail] = []
    var sensitivity: Double = 0.5
    var showsRegions = false {
        didSet { redraw() }
    }
    /// 表示中の範囲調整画面
    var regionEditor: RegionEditorRequest?

    var hasImage: Bool { sourceImage != nil }

    private var sourceImage: CGImage?
    /// ユーザーが指定した範囲と、その座標の基準になる画像
    private var manualRegions: (image: CGImage, a: [CGPoint], b: [CGPoint])?
    private var task: Task<Void, Never>?
    private let detector: DifferenceDetector?
    private let detectorError: String?

    /// 処理する画像の長辺の上限（px）
    private let maxImageDimension: CGFloat = 2048

    init() {
        do {
            detector = try DifferenceDetector()
            detectorError = nil
        } catch {
            detector = nil
            detectorError = error.localizedDescription
        }
    }

    func load(_ image: UIImage) {
        guard let cgImage = image.normalizedCGImage(maxDimension: maxImageDimension) else {
            phase = .failed("画像を読み込めませんでした。")
            return
        }
        sourceImage = cgImage
        manualRegions = nil
        result = nil
        thumbnails = []
        displayImage = UIImage(cgImage: cgImage)
        analyze()
    }

    func analyze() {
        guard let source = sourceImage else { return }
        guard let detector else {
            phase = .failed(detectorError ?? DetectionError.metalUnavailable.localizedDescription)
            return
        }
        task?.cancel()
        phase = .processing
        let options = DetectionOptions(sensitivity: Float(sensitivity))
        let manual = manualRegions
        task = Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    if let manual {
                        try detector.detect(in: manual.image, options: options, manualRegions: (manual.a, manual.b))
                    } else {
                        try detector.detect(in: source, options: options)
                    }
                }
            }.value
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let detection):
                result = detection
                phase = .finished
                redraw()
                makeThumbnails(result: detection)
            case .failure(let error):
                result = nil
                thumbnails = []
                phase = .failed(error.localizedDescription)
                displayImage = UIImage(cgImage: source)
            }
        }
    }

    /// 範囲調整画面を開く。検出済みならその範囲、未検出なら画像を半分に分けた範囲を初期位置にする
    func beginRegionEditing() {
        if let result {
            regionEditor = RegionEditorRequest(image: result.straightenedImage, quadA: result.regionA, quadB: result.regionB)
            return
        }
        guard let image = manualRegions?.image ?? sourceImage else { return }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        func quad(_ rect: CGRect) -> [CGPoint] {
            [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
             CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        }
        // 横長の写真なら左右、縦長なら上下に並んでいるとみなす
        let first: CGRect, second: CGRect
        if w >= h {
            first = CGRect(x: w * 0.05, y: h * 0.15, width: w * 0.4, height: h * 0.7)
            second = first.offsetBy(dx: w * 0.5, dy: 0)
        } else {
            first = CGRect(x: w * 0.1, y: h * 0.05, width: w * 0.8, height: h * 0.4)
            second = first.offsetBy(dx: 0, dy: h * 0.5)
        }
        regionEditor = RegionEditorRequest(image: image, quadA: quad(first), quadB: quad(second))
    }

    /// 範囲調整画面で決めた範囲で解析し直す
    func applyRegions(image: CGImage, quadA: [CGPoint], quadB: [CGPoint]) {
        manualRegions = (image, quadA, quadB)
        analyze()
    }

    /// 通常は位置合わせ済みの 2 枚を並べた画像、範囲表示時は傾き補正後の写真に範囲を描いた画像
    private func redraw() {
        guard let result else { return }
        let rendered = showsRegions
            ? ResultRenderer.renderOverview(result: result)
            : ResultRenderer.renderComparison(result: result)
        guard let rendered else { return }
        displayImage = UIImage(cgImage: rendered)
    }

    /// 位置合わせ済みの 2 枚から、各間違いの周辺を同じ位置で正方形に切り抜く（⭕️は表示側で細く重ねる）
    private func makeThumbnails(result: DetectionResult) {
        let bounds = CGRect(x: 0, y: 0, width: result.alignedA.width, height: result.alignedA.height)
        let minSide = min(bounds.width, bounds.height) * 0.2
        func crop(_ source: CGImage, _ center: CGPoint, side: CGFloat) -> (UIImage, CGPoint)? {
            // 端でも正方形を保つよう、はみ出す分は内側にずらす
            var rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side).integral
            rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
            guard let image = source.cropping(to: rect.intersection(bounds)) else { return nil }
            let marker = CGPoint(x: (center.x - rect.minX) / rect.width, y: (center.y - rect.minY) / rect.height)
            return (UIImage(cgImage: image), marker)
        }
        thumbnails = result.differences.enumerated().compactMap { index, difference in
            let side = min(max(difference.radius * 2.6, minSide), bounds.width, bounds.height)
            guard let a = crop(result.alignedA, difference.center, side: side),
                  let b = crop(result.alignedB, difference.center, side: side) else {
                return nil
            }
            return DifferenceThumbnail(id: difference.id, number: index + 1, imageA: a.0, imageB: b.0,
                                       markerCenterB: b.1,
                                       markerFraction: min(0.95, difference.radius * 2 / side))
        }
    }
}

private extension UIImage {
    /// 向きを正規化し、長辺を maxDimension 以下に縮小した sRGB 画像を返す
    func normalizedCGImage(maxDimension: CGFloat) -> CGImage? {
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        let factor = min(1, maxDimension / max(pixelSize.width, pixelSize.height))
        let target = CGSize(width: (pixelSize.width * factor).rounded(), height: (pixelSize.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }.cgImage
    }
}
