//
//  PuzzleSolverModel.swift
//  MikkeAnswer
//

import Observation
import UIKit

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
            case .failure(let error):
                result = nil
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
