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
    /// 右（下）の絵の切り抜き内での間違いの中心（0〜1 の正規化座標）
    let markerCenterB: CGPoint
    /// 切り抜き画像の一辺に対する、間違いを囲む円の直径の割合
    let markerFraction: CGFloat
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

    var hasImage: Bool { sourceImage != nil }

    private var sourceImage: CGImage?
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
        task = Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try detector.detect(in: source, options: options) }
            }.value
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let detection):
                result = detection
                phase = .finished
                redraw()
                makeThumbnails(source: source, result: detection)
            case .failure(let error):
                result = nil
                thumbnails = []
                phase = .failed(error.localizedDescription)
                displayImage = UIImage(cgImage: source)
            }
        }
    }

    private func redraw() {
        guard let sourceImage, let result,
              let rendered = ResultRenderer.render(source: sourceImage, result: result, showsRegions: showsRegions)
        else { return }
        displayImage = UIImage(cgImage: rendered)
    }

    /// 元画像から各間違いの周辺を A・B それぞれ正方形に切り抜く（⭕️は表示側で細く重ねる）
    private func makeThumbnails(source: CGImage, result: DetectionResult) {
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let minSide = CGFloat(min(source.width, source.height)) * 0.2
        func crop(_ center: CGPoint, side: CGFloat) -> (UIImage, CGPoint)? {
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
            guard let a = crop(difference.centerA, side: side), let b = crop(difference.centerB, side: side) else {
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
