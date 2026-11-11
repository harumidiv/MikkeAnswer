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
    /// 写真を読み込んだ直後に開いたか（撮り直し・選び直しができる）
    var isNewPhoto = false
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
    /// 答えの画像（2 枚目の絵に⭕️と番号を付けたもの）
    private(set) var answerImageB: UIImage?
    /// 答えの画像と同じ⭕️を 1 枚目の絵に付けた画像（左右の絵を交互に点滅させる用）
    private(set) var answerImageA: UIImage?
    /// 今の答えを保存済みか（解析し直すと新しい答えになるので戻す）
    private(set) var isAnswerSaved = false
    private(set) var result: DetectionResult?
    private(set) var thumbnails: [DifferenceThumbnail] = []
    var sensitivity: Double = 0.5
    var showsRegions = false {
        didSet { redraw() }
    }
    /// 表示中の範囲調整画面
    var regionEditor: RegionEditorRequest?
    /// 写真を読み込んでから、最初の範囲調整画面を閉じるまでの間か（この間は結果を出さない）
    private(set) var isAwaitingFirstRegionEdit = false

    var hasImage: Bool { sourceImage != nil }

    private var sourceImage: CGImage?
    /// ユーザーが指定した範囲で切り出した 2 枚と、ユーザーが重ねた B の位置（pictureB → pictureA の座標）
    private var manualOverlay: (alignment: ManualAlignment, overlay: CGAffineTransform)?
    /// 写真を読み込んだ直後の解析が終わったら、範囲の指定画面を開く
    private var opensEditorAfterAnalysis = false
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
            phase = .failed(String(localized: "画像を読み込めませんでした。"))
            return
        }
        sourceImage = cgImage
        manualOverlay = nil
        opensEditorAfterAnalysis = true
        isAwaitingFirstRegionEdit = true
        result = nil
        thumbnails = []
        answerImageA = nil
        answerImageB = nil
        displayImage = UIImage(cgImage: cgImage)
        analyze()
    }

    /// 結果画面から初期画面に戻ったとき、途中の解析を止めて読み込んだ写真と結果を捨てる
    func reset() {
        task?.cancel()
        task = nil
        sourceImage = nil
        manualOverlay = nil
        opensEditorAfterAnalysis = false
        isAwaitingFirstRegionEdit = false
        regionEditor = nil
        result = nil
        thumbnails = []
        answerImageA = nil
        answerImageB = nil
        isAnswerSaved = false
        displayImage = nil
        showsRegions = false
        phase = .idle
    }

    func analyze() {
        guard let source = sourceImage else { return }
        guard let detector else {
            // 範囲調整画面は開けないので、待たずにエラーを表示する
            isAwaitingFirstRegionEdit = false
            phase = .failed(detectorError ?? DetectionError.metalUnavailable.localizedDescription)
            return
        }
        task?.cancel()
        phase = .processing
        let options = DetectionOptions(sensitivity: Float(sensitivity))
        let manual = manualOverlay
        task = Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    if let manual {
                        try detector.detect(alignment: manual.alignment, overlay: manual.overlay, options: options)
                    } else {
                        try detector.detect(in: source, options: options)
                    }
                }
            }.value
            guard !Task.isCancelled else { return }
            defer {
                // 自動検出の結果（失敗した場合は画像を半分に分けた範囲）を初期位置にして、範囲を指定してもらう
                if opensEditorAfterAnalysis {
                    opensEditorAfterAnalysis = false
                    beginRegionEditing()
                    regionEditor?.isNewPhoto = true
                }
            }
            switch outcome {
            case .success(let detection):
                result = detection
                phase = .finished
                renderAnswers(result: detection)
                redraw()
                makeThumbnails(result: detection)
            case .failure(let error):
                result = nil
                thumbnails = []
                answerImageA = nil
                answerImageB = nil
                phase = .failed(error.localizedDescription)
                displayImage = UIImage(cgImage: source)
            }
        }
    }

    /// 範囲調整画面を開く。前回指定した範囲 → 検出済みの範囲 → 画像を半分に分けた範囲 の順に初期位置にする
    func beginRegionEditing() {
        if let alignment = manualOverlay?.alignment {
            regionEditor = RegionEditorRequest(image: alignment.image, quadA: alignment.quadA, quadB: alignment.quadB)
            return
        }
        if let result {
            regionEditor = RegionEditorRequest(image: result.straightenedImage, quadA: result.regionA, quadB: result.regionB)
            return
        }
        guard let image = sourceImage else { return }
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

    /// 写真を読み込んだ直後の範囲調整画面が閉じたとき（以降は結果を表示する）
    func endFirstRegionEdit() {
        isAwaitingFirstRegionEdit = false
    }

    /// 指定された範囲で 2 つの絵を同じ大きさに切り出す（ユーザーが重ね合わせる画面に渡す）
    func prepareAlignment(image: CGImage, quadA: [CGPoint], quadB: [CGPoint]) async throws -> ManualAlignment {
        guard let detector else { throw DetectionError.metalUnavailable }
        return try await Task.detached(priority: .userInitiated) {
            try detector.prepareAlignment(in: image, quadA: quadA, quadB: quadB)
        }.value
    }

    /// ユーザーが重ねた位置で解析し直す
    func applyOverlay(alignment: ManualAlignment, overlay: CGAffineTransform) {
        manualOverlay = (alignment, overlay)
        analyze()
    }

    /// 今の答えを保存用に作る（保存済み・答えがないときは nil）
    func makeSavedPuzzle() -> SavedPuzzle? {
        guard !isAnswerSaved, let result, let a = answerImageA, let b = answerImageB else { return nil }
        return SavedPuzzle(differenceCount: result.differences.count, answerA: a, answerB: b)
    }

    func markAnswerSaved() {
        isAnswerSaved = true
    }

    /// 左右の絵に、同じ大きさ・同じ⭕️で答えを描く
    private func renderAnswers(result: DetectionResult) {
        isAnswerSaved = false
        answerImageB = ResultRenderer.renderAnswer(result: result).map(UIImage.init(cgImage:))
        answerImageA = ResultRenderer.renderAnswer(result: result, picture: result.alignedA).map(UIImage.init(cgImage:))
    }

    /// 通常は 2 枚目の絵に⭕️を付けた答えの画像、範囲表示時は傾き補正後の写真に範囲を描いた画像
    private func redraw() {
        guard let result else { return }
        if showsRegions {
            guard let overview = ResultRenderer.renderOverview(result: result) else { return }
            displayImage = UIImage(cgImage: overview)
        } else if let answer = answerImageB {
            displayImage = answer
        }
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
