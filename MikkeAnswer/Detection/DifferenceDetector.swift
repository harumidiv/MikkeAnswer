//
//  DifferenceDetector.swift
//  MikkeAnswer
//
//  1 枚の画像に並んだ 2 つの絵を見つけ、差分（間違い）を検出する。
//  重い画像処理はすべて Metal（独自カーネル + Metal Performance Shaders）で行う。
//
//  0. 傾き補正   : 輪郭の向きの分布から画像の傾きを求め、回転してまっすぐにする
//  1. 領域確定   : Vision の四角形検出で 2 つの絵の枠を探し、四隅から遠近補正して切り出す。
//                  枠が見つからなければ、画像を自分自身とずらして照合する方式で範囲を求める
//  2. 位置合わせ : Vision の画像位置合わせ（射影変換）で B を A に重ね、
//                  残りのずれをタイルごとの局所テンプレートマッチングで補正する
//  3. 差分       : 照明補正 + 近傍最小色差 → 二値化 → 収縮・膨張 → 連結成分を間違いとして抽出
//

import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders
import Vision

nonisolated private struct ShiftParams {
    var candidateCount: UInt32
    var stride: UInt32
}

nonisolated private struct WarpParams {
    var h0: SIMD3<Float>
    var h1: SIMD3<Float>
    var h2: SIMD3<Float>
    var affineX: SIMD3<Float>
    var affineY: SIMD3<Float>
    var origin: SIMD2<Float>
    var scale: SIMD2<Float>
    var sourceSize: SIMD2<Float>
    var tileSize: SIMD2<Float>
    var fieldDims: SIMD2<UInt32>
}

nonisolated private struct DifferenceParams {
    var gainPlane: SIMD3<Float>
    var radius: Int32
}

nonisolated private struct ThresholdParams {
    var threshold: Float
    var noiseWeight: Float
    var border: UInt32
}

/// 変位 = (x·p.x + y·p.y + 定数) のアフィンモデル
nonisolated private struct AffineModel {
    var x: SIMD3<Float>
    var y: SIMD3<Float>

    init(x: SIMD3<Float>, y: SIMD3<Float>) {
        self.x = x
        self.y = y
    }

    init(constant: SIMD2<Float>) {
        self.init(x: SIMD3(0, 0, constant.x), y: SIMD3(0, 0, constant.y))
    }

    func apply(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let h = SIMD3<Float>(p.x, p.y, 1)
        return SIMD2(simd_dot(x, h), simd_dot(y, h))
    }
}

/// 射影変換 q = H·p（同次座標）
nonisolated private struct Homography {
    var matrix: simd_double3x3

    static let identity = Homography(matrix: matrix_identity_double3x3)

    static func translation(_ t: SIMD2<Double>) -> Homography {
        Homography(matrix: simd_double3x3(rows: [SIMD3(1, 0, t.x), SIMD3(0, 1, t.y), SIMD3(0, 0, 1)]))
    }

    func apply(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let q = matrix * SIMD3(p.x, p.y, 1)
        return SIMD2(q.x, q.y) / q.z
    }

    /// 座標系を拡大する：S·H·S⁻¹（S = diag(sx, sy, 1)）
    func scaled(by s: SIMD2<Double>) -> Homography {
        let scale = simd_double3x3(diagonal: SIMD3(s.x, s.y, 1))
        return Homography(matrix: scale * matrix * scale.inverse)
    }

    /// シェーダに渡す行ベクトル
    var rows: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let t = matrix.transpose
        return (SIMD3<Float>(t.columns.0), SIMD3<Float>(t.columns.1), SIMD3<Float>(t.columns.2))
    }

    /// 対応点 p[i] → q[i] から最小二乗で求める（DLT、座標は normalization で割って条件を良くする）
    static func fit(from p: [SIMD2<Double>], to q: [SIMD2<Double>], normalization: Double) -> Homography? {
        guard p.count >= 4 else { return nil }
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
        var atb = [Double](repeating: 0, count: 8)
        for i in p.indices {
            let x = p[i].x / normalization, y = p[i].y / normalization
            let u = q[i].x / normalization, v = q[i].y / normalization
            for (row, target) in [([x, y, 1, 0, 0, 0, -x * u, -y * u], u), ([0, 0, 0, x, y, 1, -x * v, -y * v], v)] {
                for r in 0..<8 {
                    atb[r] += row[r] * target
                    for c in 0..<8 { ata[r][c] += row[r] * row[c] }
                }
            }
        }
        guard let h = solveLinear(ata, atb) else { return nil }
        let normalized = simd_double3x3(rows: [SIMD3(h[0], h[1], h[2]), SIMD3(h[3], h[4], h[5]), SIMD3(h[6], h[7], 1)])
        return Homography(matrix: normalized).scaled(by: SIMD2(repeating: normalization))
    }

    /// 部分ピボット付きガウス消去
    private static func solveLinear(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a, rhs = b
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }),
                  abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot)
            rhs.swapAt(col, pivot)
            for row in (col + 1)..<n {
                let f = m[row][col] / m[col][col]
                guard f != 0 else { continue }
                for c in col..<n { m[row][c] -= f * m[col][c] }
                rhs[row] -= f * rhs[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = rhs[row]
            for c in (row + 1)..<n { sum -= m[row][c] * x[c] }
            x[row] = sum / m[row][row]
        }
        return x
    }
}

/// B を A に重ねるための変位場（作業画素単位）。
/// 全体の傾き・拡大はアフィン変換で各画素ごとに計算し、残差だけをタイル中心の値から双線形補間する。
nonisolated private struct DisplacementField {
    var affine: AffineModel
    var residuals: [SIMD2<Float>]
    var dims: SIMD2<UInt32>
    var tileSize: SIMD2<Float>

    static func constant(_ value: SIMD2<Float>, size: SIMD2<Float>) -> DisplacementField {
        DisplacementField(affine: AffineModel(constant: value), residuals: [.zero], dims: SIMD2(1, 1), tileSize: size)
    }

    /// シェーダの warpCrop と同じ計算
    func sample(at pos: SIMD2<Float>) -> SIMD2<Float> {
        affine.apply(pos) + residual(at: pos)
    }

    private func residual(at pos: SIMD2<Float>) -> SIMD2<Float> {
        let values = residuals
        let maxIndex = SIMD2<Float>(Float(dims.x - 1), Float(dims.y - 1))
        let g = simd_clamp(pos / tileSize - 0.5, SIMD2<Float>(0, 0), maxIndex)
        let x0 = Int(g.x), y0 = Int(g.y)
        let x1 = min(x0 + 1, Int(dims.x) - 1), y1 = min(y0 + 1, Int(dims.y) - 1)
        let fx = g.x - Float(x0), fy = g.y - Float(y0)
        let w = Int(dims.x)
        let top = values[y0 * w + x0] * (1 - fx) + values[y0 * w + x1] * fx
        let bottom = values[y1 * w + x0] * (1 - fx) + values[y1 * w + x1] * fx
        return top * (1 - fy) + bottom * fy
    }
}

nonisolated private struct Blob {
    var minX: Int, minY: Int, maxX: Int, maxY: Int
    var core: Int
    /// core のうち範囲の縁の帯にあるもの
    var coreNearEdge: Int
    var score: Float

    func isNear(_ other: Blob, gap: Int) -> Bool {
        minX - gap <= other.maxX && other.minX <= maxX + gap
            && minY - gap <= other.maxY && other.minY <= maxY + gap
    }

    var boxArea: Int { (maxX - minX + 1) * (maxY - minY + 1) }

    /// 2 つを囲む外接矩形が、それぞれの外接矩形の合計よりあまり大きくならない（= 同じ物の断片が隣り合っている）
    func fitsTogether(with other: Blob, maxGrowth: Double) -> Bool {
        let union = (max(maxX, other.maxX) - min(minX, other.minX) + 1) * (max(maxY, other.maxY) - min(minY, other.minY) + 1)
        return Double(union) <= Double(boxArea + other.boxArea) * maxGrowth
    }

    mutating func absorb(_ other: Blob) {
        minX = min(minX, other.minX); minY = min(minY, other.minY)
        maxX = max(maxX, other.maxX); maxY = max(maxY, other.maxY)
        core += other.core
        coreNearEdge += other.coreNearEdge
        score += other.score
    }
}

nonisolated final class DifferenceDetector: @unchecked Sendable {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let gradientPipeline: MTLComputePipelineState
    private let shiftPipeline: MTLComputePipelineState
    private let warpPipeline: MTLComputePipelineState
    private let differencePipeline: MTLComputePipelineState
    private let thresholdPipeline: MTLComputePipelineState
    private let lock = NSLock()

    /// 傾きの推定に使う縮小画像の長辺
    private let skewSearchDimension = 640
    /// 領域確定に使う低解像度画像の長辺
    private let regionSearchDimension = 320
    /// 差分計算に使う作業解像度の長辺
    private let maxWorkDimension: CGFloat = 1024
    /// 小さい絵を作業解像度に拡大するときの上限倍率
    private let maxUpscale = 4.0
    /// 局所位置合わせのタイルサイズ（作業画素）
    private let tileTargetSize: Double = 80
    /// 局所位置合わせの探索半径（作業画素）
    private let localSearchRadius = 6
    private let shiftThreadgroupSize = 256
    /// 照明補正の推定に使う縮小画像の長辺
    private let illuminationGridSize: Double = 48
    /// 周囲の差分の平均を取る範囲（ガウスの σ、絵の長辺に対する割合）
    private let noiseSigmaRatio: Float = 0.08
    /// 平均を取る前に差分を頭打ちにする値（基本のしきい値に対する倍率）
    private let noiseClip: Float = 1
    /// 近接した断片をまとめるとき、外接矩形の面積が元の合計の何倍まで膨らむのを許すか
    private let mergeGrowthLimit = 1.25
    /// 周囲の差分の平均の何倍を超えたら間違いとみなすか
    private let noiseWeight: Float = 4

    /// 検証用：中間結果（名前, 値, 幅, 高さ）を受け取る
    var debugSink: ((String, [Float], Int, Int) -> Void)?

    /// - Parameter metallibURL: 指定しない場合はアプリに同梱された default.metallib を使う
    init(metallibURL: URL? = nil) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw DetectionError.metalUnavailable
        }
        let library: MTLLibrary
        if let metallibURL {
            library = try device.makeLibrary(URL: metallibURL)
        } else if let defaultLibrary = device.makeDefaultLibrary() {
            library = defaultLibrary
        } else {
            throw DetectionError.metalUnavailable
        }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw DetectionError.metalUnavailable
            }
            return try device.makeComputePipelineState(function: function)
        }
        self.device = device
        self.queue = queue
        gradientPipeline = try pipeline("gradientMagnitude")
        shiftPipeline = try pipeline("shiftScore")
        warpPipeline = try pipeline("warpCrop")
        differencePipeline = try pipeline("colorDifference")
        thresholdPipeline = try pipeline("thresholdMask")
    }

    // MARK: - 検出

    /// - Parameters:
    ///   - manualRegions: ユーザーが指定した 2 つの絵の範囲（image 上の四隅：左上・右上・右下・左下）。
    ///     指定した場合は傾き補正・範囲の自動検出・範囲の削り込みを行わず、この範囲をそのまま使う
    func detect(in image: CGImage, options: DetectionOptions = DetectionOptions(),
                manualRegions: (a: [CGPoint], b: [CGPoint])? = nil) throws -> DetectionResult {
        lock.lock()
        defer { lock.unlock() }
        let start = Date()

        let input = try makeTexture(from: image)
        let sourceSize = SIMD2<Float>(Float(input.width), Float(input.height))

        // 0. 傾きを補正した画像を以降の処理の元にする
        let rotationDegrees = manualRegions == nil ? try estimateSkew(of: input) : 0
        let deskew = Self.rotation(degrees: rotationDegrees,
                                   center: SIMD2(Double(input.width) / 2, Double(input.height) / 2))
        let source = try makeTexture(width: input.width, height: input.height, format: .rgba8Unorm)
        try run { cb in
            try encodeWarp(cb, source: input, destination: source, homography: deskew,
                           field: .constant(.zero, size: sourceSize))
        }

        guard let straightened = makeImage(from: source) else { throw DetectionError.resourceCreationFailed }

        // 1. 2 つの絵の範囲を確定（作業画素 → 傾き補正後の画像 への変換 mapA / mapB として表す）
        let pair: PicturePair
        if let manualRegions {
            let toSIMD = { (points: [CGPoint]) in points.map { SIMD2(Double($0.x), Double($0.y)) } }
            guard let manual = rectifiedPair(quadA: toSIMD(manualRegions.a), quadB: toSIMD(manualRegions.b)) else {
                throw DetectionError.regionsNotFound
            }
            // 指定された四隅のずれは Vision の位置合わせで補う（重なりが良くなる場合だけ採用）
            let refined = try refineWithVision(source: source, pair: manual)
            pair = refined.correction.isFinite
                ? try betterAligned(manual, refined.pair, source: source)
                : manual
        } else {
            pair = try locatePictures(in: source, image: straightened)
        }
        return try detectDifferences(source: source, straightened: straightened, deskew: deskew,
                                     rotationDegrees: rotationDegrees, pair: pair,
                                     fixedTrim: manualRegions == nil ? nil : CGRect(x: 0, y: 0, width: pair.width, height: pair.height),
                                     options: options, start: start)
    }

    /// ユーザーが 2 つの絵を重ね合わせるための下準備。指定された範囲を A の大きさに遠近補正して切り出し、
    /// Vision の位置合わせで B を A に近づけておく（重なりが良くなる場合だけ）
    /// - Parameters:
    ///   - quadA, quadB: image 上の四隅（左上・右上・右下・左下）
    func prepareAlignment(in image: CGImage, quadA: [CGPoint], quadB: [CGPoint]) throws -> ManualAlignment {
        lock.lock()
        defer { lock.unlock() }

        let source = try makeTexture(from: image)
        let toSIMD = { (points: [CGPoint]) in points.map { SIMD2(Double($0.x), Double($0.y)) } }
        guard let manual = rectifiedPair(quadA: toSIMD(quadA), quadB: toSIMD(quadB)) else {
            throw DetectionError.regionsNotFound
        }
        let refined = try refineWithVision(source: source, pair: manual)
        let pair = refined.correction.isFinite ? try betterAligned(manual, refined.pair, source: source) : manual

        let identity = DisplacementField.constant(.zero, size: SIMD2(Float(pair.width), Float(pair.height)))
        let cropA = try makeTexture(width: pair.width, height: pair.height, format: .rgba8Unorm)
        let cropB = try makeTexture(width: pair.width, height: pair.height, format: .rgba8Unorm)
        try run { cb in
            try encodeWarp(cb, source: source, destination: cropA, homography: pair.mapA, field: identity)
            try encodeWarp(cb, source: source, destination: cropB, homography: pair.mapB, field: identity)
        }
        guard let pictureA = makeImage(from: cropA), let pictureB = makeImage(from: cropB) else {
            throw DetectionError.resourceCreationFailed
        }
        return ManualAlignment(image: image, quadA: quadA, quadB: quadB, pictureA: pictureA, pictureB: pictureB,
                               mapA: pair.mapA.matrix, mapB: pair.mapB.matrix)
    }

    /// ユーザーが重ね合わせた 2 枚から間違いを検出する
    /// - Parameter overlay: 重ねた B の位置（pictureB の座標 → pictureA の座標）。2 枚が重なる部分だけを調べる
    func detect(alignment: ManualAlignment, overlay: CGAffineTransform,
                options: DetectionOptions = DetectionOptions()) throws -> DetectionResult {
        lock.lock()
        defer { lock.unlock() }
        let start = Date()

        let source = try makeTexture(from: alignment.image)
        let width = alignment.pictureA.width, height = alignment.pictureA.height
        // 作業画素（A の座標）→ B の切り出し画像の座標 → 元画像の座標
        let inverse = overlay.inverted()
        let aToB = simd_double3x3(rows: [SIMD3(Double(inverse.a), Double(inverse.c), Double(inverse.tx)),
                                         SIMD3(Double(inverse.b), Double(inverse.d), Double(inverse.ty)),
                                         SIMD3(0, 0, 1)])
        let overlaid = PicturePair(mapA: Homography(matrix: alignment.mapA),
                                   mapB: Homography(matrix: alignment.mapB * aToB),
                                   width: width, height: height)
        // 手で重ねたわずかなずれは、そこを出発点に Vision で合わせ直す（重なりが良くなる場合だけ採用）
        let refined = try refineWithVision(source: source, pair: overlaid)
        let pair = refined.correction.isFinite ? try betterAligned(overlaid, refined.pair, source: source) : overlaid
        let correction = pair.mapB.matrix == overlaid.mapB.matrix ? 0 : CGFloat(refined.correction)

        // 重ねた B が覆っている、A の中の長方形（回転は小さい前提で、内側に収まる範囲を取る）
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0), CGPoint(x: width, y: height), CGPoint(x: 0, y: height)]
            .map { $0.applying(overlay) }
        let minX = (max(0, corners[0].x, corners[3].x) + correction).rounded(.up)
        let maxX = (min(CGFloat(width), corners[1].x, corners[2].x) - correction).rounded(.down)
        let minY = (max(0, corners[0].y, corners[1].y) + correction).rounded(.up)
        let maxY = (min(CGFloat(height), corners[2].y, corners[3].y) - correction).rounded(.down)
        guard maxX - minX >= 32, maxY - minY >= 32 else { throw DetectionError.overlapTooSmall }

        return try detectDifferences(source: source, straightened: alignment.image, deskew: .identity,
                                     rotationDegrees: 0, pair: pair,
                                     fixedTrim: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                                     options: options, start: start)
    }

    /// 2 つの絵の範囲が決まった後の処理（位置合わせの仕上げ → 差分 → 間違いの抽出）
    /// - Parameter fixedTrim: 間違いを探す範囲（作業画素）。nil なら 2 枚がよく重なる部分を自動で求める
    private func detectDifferences(source: MTLTexture, straightened: CGImage, deskew: Homography,
                                   rotationDegrees: Double, pair: PicturePair, fixedTrim: CGRect?,
                                   options: DetectionOptions, start: Date) throws -> DetectionResult {
        let workW = pair.width, workH = pair.height
        let workSize = SIMD2<Float>(Float(workW), Float(workH))
        let mapA = pair.mapA, mapB = pair.mapB
        // 小さい絵を拡大して処理している場合の倍率（元の 1px が作業画素で何 px か）。
        // ぼかし・位置ずれの許容・ノイズ除去などの大きさを、元の画素単位で揃えるのに使う
        let center = SIMD2(Double(workW) / 2, Double(workH) / 2)
        let sourcePerWork = simd_distance(mapA.apply(center), mapA.apply(center + SIMD2(1, 0)))
        let upscale = Float(max(1, 1 / max(sourcePerWork, 1e-6)))
        func oddSize(_ value: Float) -> Int { Int(value.rounded()) / 2 * 2 + 1 }

        // 2. 作業解像度で A を切り出し、B は射影変換で A に重ねて切り出す。位置合わせ用の勾配画像も作る
        let cropA = try makeTexture(width: workW, height: workH, format: .rgba8Unorm)
        let cropB = try makeTexture(width: workW, height: workH, format: .rgba8Unorm)
        let rawGradA = try makeTexture(width: workW, height: workH, format: .r32Float)
        let rawGradB = try makeTexture(width: workW, height: workH, format: .r32Float)
        let gradA = try makeTexture(width: workW, height: workH, format: .r32Float)
        let gradB = try makeTexture(width: workW, height: workH, format: .r32Float)
        let identity = DisplacementField.constant(.zero, size: workSize)
        try run { cb in
            try encodeWarp(cb, source: source, destination: cropA, homography: mapA, field: identity)
            try encodeWarp(cb, source: source, destination: cropB, homography: mapB, field: identity)
            try encodeGradient(cb, source: cropA, destination: rawGradA)
            try encodeGradient(cb, source: cropB, destination: rawGradB)
            gaussian(sigma: upscale).encode(commandBuffer: cb, sourceTexture: rawGradA, destinationTexture: gradA)
            gaussian(sigma: upscale).encode(commandBuffer: cb, sourceTexture: rawGradB, destinationTexture: gradB)
        }

        // 3. 射影変換で合わせきれない残りのずれ（局所変位場）
        let field = try estimateField(gradA: gradA, gradB: gradB, width: workW, height: workH, upscale: Double(upscale))

        // 4. B をワープして差分を取る
        let warpedB = try makeTexture(width: workW, height: workH, format: .rgba8Unorm)
        let smoothA = try makeTexture(width: workW, height: workH, format: .rgba8Unorm)
        let smoothB = try makeTexture(width: workW, height: workH, format: .rgba8Unorm)
        let thumbW = max(4, Int((Double(workW) * illuminationGridSize / Double(max(workW, workH))).rounded()))
        let thumbH = max(4, Int((Double(workH) * illuminationGridSize / Double(max(workW, workH))).rounded()))
        let thumbA = try makeTexture(width: thumbW, height: thumbH, format: .rgba8Unorm)
        let thumbB = try makeTexture(width: thumbW, height: thumbH, format: .rgba8Unorm)
        let difference = try makeTexture(width: workW, height: workH, format: .r32Float)
        let clipped = try makeTexture(width: workW, height: workH, format: .r32Float)
        let noise = try makeTexture(width: workW, height: workH, format: .r32Float)
        let mask = try makeTexture(width: workW, height: workH, format: .r8Unorm)
        let eroded = try makeTexture(width: workW, height: workH, format: .r8Unorm)
        let dilated = try makeTexture(width: workW, height: workH, format: .r8Unorm)

        let sensitivity = min(max(options.sensitivity, 0), 1)
        // RGB ユークリッド距離（0〜√3）に対するしきい値。
        // ボケ・照明ムラのある部分は周囲の差分の平均でしきい値を上げるので、基本のしきい値は低めにできる
        let threshold = 0.32 - 0.24 * sensitivity
        // 範囲の削り込みで「2 枚が合っている」とみなす差分の基準（間違いの判定とは別に固定）
        let agreementThreshold = 0.40 - 0.28 * sensitivity
        let border = UInt32(Double(min(workW, workH)) * 0.015) + 2

        try run { cb in
            try encodeWarp(cb, source: source, destination: warpedB, homography: mapB, field: field)
            gaussian(sigma: upscale).encode(commandBuffer: cb, sourceTexture: cropA, destinationTexture: smoothA)
            gaussian(sigma: upscale).encode(commandBuffer: cb, sourceTexture: warpedB, destinationTexture: smoothB)
            let downscale = MPSImageLanczosScale(device: device)
            downscale.encode(commandBuffer: cb, sourceTexture: cropA, destinationTexture: thumbA)
            downscale.encode(commandBuffer: cb, sourceTexture: warpedB, destinationTexture: thumbB)
        }
        let gainPlane = Self.fitGainPlane(a: readBytes(thumbA, bytesPerPixel: 4), b: readBytes(thumbB, bytesPerPixel: 4),
                                          width: thumbW, height: thumbH)

        try run { cb in
            var differenceParams = DifferenceParams(gainPlane: gainPlane, radius: Int32((2 * upscale).rounded()))
            try encodeKernel(cb, differencePipeline, width: workW, height: workH) { enc in
                enc.setTexture(smoothA, index: 0)
                enc.setTexture(smoothB, index: 1)
                enc.setTexture(difference, index: 2)
                enc.setBytes(&differenceParams, length: MemoryLayout<DifferenceParams>.stride, index: 0)
            }

            // 間違いそのものが平均を押し上げないよう、しきい値で頭打ちにしてから平均する
            MPSImageThresholdTruncate(device: device, thresholdValue: threshold * noiseClip, linearGrayColorTransform: nil)
                .encode(commandBuffer: cb, sourceTexture: difference, destinationTexture: clipped)
            gaussian(sigma: noiseSigmaRatio * Float(max(workW, workH)))
                .encode(commandBuffer: cb, sourceTexture: clipped, destinationTexture: noise)
            var params = ThresholdParams(threshold: threshold, noiseWeight: noiseWeight, border: border)
            try encodeKernel(cb, thresholdPipeline, width: workW, height: workH) { enc in
                enc.setTexture(difference, index: 0)
                enc.setTexture(noise, index: 1)
                enc.setTexture(mask, index: 2)
                enc.setBytes(&params, length: MemoryLayout<ThresholdParams>.stride, index: 0)
            }
            let erosion = oddSize(3 * upscale.squareRoot()), dilation = min(31, oddSize(9 * upscale))
            MPSImageAreaMin(device: device, kernelWidth: erosion, kernelHeight: erosion)
                .encode(commandBuffer: cb, sourceTexture: mask, destinationTexture: eroded)
            MPSImageAreaMax(device: device, kernelWidth: dilation, kernelHeight: dilation)
                .encode(commandBuffer: cb, sourceTexture: eroded, destinationTexture: dilated)
        }

        if let debugSink {
            debugSink("difference", readFloats(difference), workW, workH)
            debugSink("residual", field.residuals.map { simd_length($0) }, Int(field.dims.x), Int(field.dims.y))
        }

        // 5. 2 枚を重ねて輪郭がよく合う部分を絵の範囲とし、外側（文字・余白・紙の縁）を削る
        let differenceValues = readFloats(difference)
        let trim = fixedTrim.map { (minX: Int($0.minX), minY: Int($0.minY), maxX: Int($0.maxX) - 1, maxY: Int($0.maxY) - 1) }
            ?? Self.overlapBounds(difference: differenceValues, gradA: readFloats(gradA), gradB: readFloats(gradB),
                                 width: workW, height: workH, threshold: agreementThreshold)
        let trimW = trim.maxX - trim.minX + 1, trimH = trim.maxY - trim.minY + 1
        func cropped<T>(_ values: [T]) -> [T] {
            (trim.minY...trim.maxY).flatMap { y in values[(y * workW + trim.minX)...(y * workW + trim.maxX)] }
        }

        // 6. 連結成分 → 間違い
        let limits = readFloats(noise).map { max(threshold, noiseWeight * $0) }
        let blobs = extractBlobs(mask: cropped(readBytes(dilated)), difference: cropped(differenceValues),
                                 limits: cropped(limits), width: trimW, height: trimH,
                                 edgeBand: Int(border) + Int(8 * upscale),
                                 maxCount: options.maxDifferences)
        let trimOrigin = SIMD2<Float>(Float(trim.minX), Float(trim.minY))

        let minRadius = Double(min(trimW, trimH)) * 0.03
        let differences = blobs.enumerated().map { index, blob -> PuzzleDifference in
            let center = SIMD2<Float>(Float(blob.minX + blob.maxX + 1) / 2, Float(blob.minY + blob.maxY + 1) / 2)
            let halfExtent = Double(max(blob.maxX - blob.minX + 1, blob.maxY - blob.minY + 1)) / 2
            let sourceA = deskew.apply(mapA.apply(SIMD2<Double>(center + trimOrigin)))
            return PuzzleDifference(id: index,
                                    center: CGPoint(x: CGFloat(center.x), y: CGFloat(center.y)),
                                    radius: CGFloat(max(minRadius, halfExtent * 1.25 + 4)),
                                    sourceCenterA: CGPoint(x: sourceA.x, y: sourceA.y),
                                    score: blob.score)
        }

        // 表示用：位置合わせ済みの 2 枚と、傾き補正後の画像上での範囲（B は射影変換で写した四角形）
        let workCorners = [SIMD2<Float>(Float(trim.minX), Float(trim.minY)),
                           SIMD2<Float>(Float(trim.maxX + 1), Float(trim.minY)),
                           SIMD2<Float>(Float(trim.maxX + 1), Float(trim.maxY + 1)),
                           SIMD2<Float>(Float(trim.minX), Float(trim.maxY + 1))]
        let cornersA = workCorners.map { p -> CGPoint in
            let q = mapA.apply(SIMD2<Double>(p))
            return CGPoint(x: q.x, y: q.y)
        }
        let cornersB = workCorners.map { p -> CGPoint in
            let q = mapB.apply(SIMD2<Double>(p + field.sample(at: p)))
            return CGPoint(x: q.x, y: q.y)
        }
        let trimRect = CGRect(x: trim.minX, y: trim.minY, width: trimW, height: trimH)
        guard let alignedA = makeImage(from: cropA)?.cropping(to: trimRect),
              let alignedB = makeImage(from: warpedB)?.cropping(to: trimRect) else {
            throw DetectionError.resourceCreationFailed
        }
        return DetectionResult(alignedA: alignedA, alignedB: alignedB, straightenedImage: straightened,
                               rotationDegrees: rotationDegrees, regionA: cornersA, regionB: cornersB,
                               differences: differences, elapsed: Date().timeIntervalSince(start))
    }

    // MARK: - 0. 傾き補正

    /// 輪郭の向き（90° で折り返した角度）の分布のピークを画像の傾きとみなす。
    /// 絵の枠・紙の縁・文字の行などの水平垂直な線が手がかりになる。
    private func estimateSkew(of source: MTLTexture) throws -> Double {
        let scale = min(1, Double(skewSearchDimension) / Double(max(source.width, source.height)))
        let w = max(32, Int((Double(source.width) * scale).rounded()))
        let h = max(32, Int((Double(source.height) * scale).rounded()))
        let small = try makeTexture(width: w, height: h, format: .rgba8Unorm)
        try run { cb in
            MPSImageLanczosScale(device: device).encode(commandBuffer: cb, sourceTexture: source, destinationTexture: small)
        }
        let bytes = readBytes(small, bytesPerPixel: 4)
        var luma = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            luma[i] = 0.299 * Float(bytes[i * 4]) + 0.587 * Float(bytes[i * 4 + 1]) + 0.114 * Float(bytes[i * 4 + 2])
        }

        let maxAngle = 20.0, binWidth = 0.25
        let binCount = Int(2 * maxAngle / binWidth) + 1
        var histogram = [Double](repeating: 0, count: binCount)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                func l(_ dx: Int, _ dy: Int) -> Float { luma[(y + dy) * w + x + dx] }
                let gx = (l(1, -1) + 2 * l(1, 0) + l(1, 1)) - (l(-1, -1) + 2 * l(-1, 0) + l(-1, 1))
                let gy = (l(-1, 1) + 2 * l(0, 1) + l(1, 1)) - (l(-1, -1) + 2 * l(0, -1) + l(1, -1))
                let magnitude = Double(gx * gx + gy * gy)
                guard magnitude > 400 else { continue }
                // 輪郭の法線の向きを [-45°, 45°) に折り返す
                var angle = atan2(Double(gy), Double(gx)) * 180 / .pi
                angle = (angle + 45).truncatingRemainder(dividingBy: 90)
                if angle < 0 { angle += 90 }
                angle -= 45
                guard abs(angle) <= maxAngle else { continue }
                histogram[Int(((angle + maxAngle) / binWidth).rounded())] += magnitude
            }
        }
        // 平滑化してピークを探す
        let smoothed = histogram.indices.map { i in
            histogram[max(0, i - 2)...min(binCount - 1, i + 2)].reduce(0, +)
        }
        guard let peak = smoothed.indices.max(by: { smoothed[$0] < smoothed[$1] }) else { return 0 }
        let mean = smoothed.reduce(0, +) / Double(binCount)
        guard smoothed[peak] > mean * 3 else { return 0 }   // はっきりした向きがなければ補正しない
        var offset = 0.0
        if peak > 0 && peak < binCount - 1 {
            let l = smoothed[peak - 1], c = smoothed[peak], r = smoothed[peak + 1]
            let denominator = l - 2 * c + r
            if denominator < 0 { offset = min(0.5, max(-0.5, 0.5 * (l - r) / denominator)) }
        }
        let degrees = (Double(peak) + offset) * binWidth - maxAngle
        return abs(degrees) < 0.2 ? 0 : degrees
    }

    /// 補正後の座標 → 元画像の座標への回転（中心 center、時計回りに degrees）
    private static func rotation(degrees: Double, center: SIMD2<Double>) -> Homography {
        let r = degrees * .pi / 180
        let c = cos(r), s = sin(r)
        return Homography(matrix: simd_double3x3(rows: [
            SIMD3(c, -s, center.x - c * center.x + s * center.y),
            SIMD3(s, c, center.y - s * center.x - c * center.y),
            SIMD3(0, 0, 1),
        ]))
    }

    // MARK: - 1. 領域確定

    private struct PicturePair {
        /// 作業画素 → 傾き補正後の画像の座標
        var mapA: Homography
        var mapB: Homography
        var width: Int
        var height: Int
    }

    /// 2 つの絵の範囲を求め、Vision の画像位置合わせで B を A にぴったり重ねた変換を返す。
    /// 四角形検出（枠のある絵）と、自分自身とずらして照合する方式の両方で候補を作り、
    /// 2 枚の輪郭が最もよく重なるものを選ぶ
    private func locatePictures(in source: MTLTexture, image: CGImage) throws -> PicturePair {
        var candidates: [PicturePair] = []
        if let framed = try detectFramedPictures(in: image) {
            candidates.append(framed)
            let refined = try refineWithVision(source: source, pair: framed)
            if refined.correction.isFinite { candidates.append(refined.pair) }
        }
        if let shifted = try? locateShiftedPictures(in: source) {
            candidates.append(shifted)
            let refined = try refineWithVision(source: source, pair: shifted)
            if refined.correction.isFinite { candidates.append(refined.pair) }
        }
        let errors = try candidates.map { try alignmentError(of: $0, source: source) }
        guard let best = errors.indices.min(by: { errors[$0] < errors[$1] }) else {
            throw DetectionError.regionsNotFound
        }
        return candidates[best]
    }

    /// 2 つの候補のうち、2 枚の輪郭がよく重なる（ずれが小さい）ほうを返す
    private func betterAligned(_ a: PicturePair, _ b: PicturePair, source: MTLTexture) throws -> PicturePair {
        try alignmentError(of: b, source: source) < alignmentError(of: a, source: source) ? b : a
    }

    /// 切り出した 2 枚の勾配画像の差の割合 Σ|a-b| / Σ(a+b)（小さいほどよく重なっている）
    private func alignmentError(of pair: PicturePair, source: MTLTexture) throws -> Float {
        let identity = DisplacementField.constant(.zero, size: SIMD2(Float(pair.width), Float(pair.height)))
        let crops = try (0..<2).map { _ in try makeTexture(width: pair.width, height: pair.height, format: .rgba8Unorm) }
        let gradients = try (0..<4).map { _ in try makeTexture(width: pair.width, height: pair.height, format: .r32Float) }
        try run { cb in
            for (i, map) in [pair.mapA, pair.mapB].enumerated() {
                try encodeWarp(cb, source: source, destination: crops[i], homography: map, field: identity)
                try encodeGradient(cb, source: crops[i], destination: gradients[i])
                gaussian(sigma: 1.0).encode(commandBuffer: cb, sourceTexture: gradients[i], destinationTexture: gradients[i + 2])
            }
        }
        let whole = [SIMD4<Int32>(0, 0, Int32(pair.width), Int32(pair.height))]
        let score = try shiftScores(a: gradients[2], b: gradients[3], tiles: whole, candidates: [.zero], stride: 2)[0]
        return Self.ratio(score)
    }

    private func locateShiftedPictures(in source: MTLTexture) throws -> PicturePair {
        let regions = try locateRegions(in: source)
        let rect = regions.a
        let scale = Double(workScale(forLongSide: Double(max(rect.width, rect.height))))
        let width = max(32, Int((rect.width * scale).rounded())), height = max(32, Int((rect.height * scale).rounded()))
        let toSource = Homography(matrix: simd_double3x3(rows: [
            SIMD3(Double(rect.width) / Double(width), 0, Double(rect.minX)),
            SIMD3(0, Double(rect.height) / Double(height), Double(rect.minY)),
            SIMD3(0, 0, 1),
        ]))
        return PicturePair(mapA: toSource, mapB: Homography(matrix: regions.homography.matrix * toSource.matrix),
                           width: width, height: height)
    }

    /// Vision の四角形検出で、大きさと形の似た 2 つの四角形（= 2 つの絵の枠）を探す。
    /// 見つかれば四隅から遠近補正する変換を作る
    private func detectFramedPictures(in image: CGImage) throws -> PicturePair? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 12
        request.minimumSize = 0.2
        request.minimumConfidence = 0.3
        request.minimumAspectRatio = 0.3
        request.quadratureTolerance = 25
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let w = Double(image.width), h = Double(image.height)
        // Vision は左下原点の正規化座標なので、左上原点のピクセル座標（左上・右上・右下・左下）に直す
        func pixel(_ p: CGPoint) -> SIMD2<Double> {
            SIMD2(Double(p.x) * w, (1 - Double(p.y)) * h)
        }
        let quads: [[SIMD2<Double>]] = (request.results ?? []).map { r in
            [pixel(r.topLeft), pixel(r.topRight), pixel(r.bottomRight), pixel(r.bottomLeft)]
        }
        func size(_ q: [SIMD2<Double>]) -> SIMD2<Double> {
            let top: Double = simd_distance(q[0], q[1]), bottom: Double = simd_distance(q[3], q[2])
            let left: Double = simd_distance(q[0], q[3]), right: Double = simd_distance(q[1], q[2])
            return SIMD2((top + bottom) / 2, (left + right) / 2)
        }
        func bounds(_ q: [SIMD2<Double>]) -> CGRect {
            let xs = q.map(\.x), ys = q.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }

        var best: (a: [SIMD2<Double>], b: [SIMD2<Double>], area: Double)?
        for i in quads.indices {
            for j in quads.indices where j > i {
                let si = size(quads[i]), sj = size(quads[j])
                let areaI: Double = si.x * si.y, areaJ: Double = sj.x * sj.y
                let aspectI: Double = si.x / si.y, aspectJ: Double = sj.x / sj.y
                let areaRatio = min(areaI, areaJ) / max(areaI, areaJ)
                let aspectRatio = min(aspectI, aspectJ) / max(aspectI, aspectJ)
                let bi = bounds(quads[i]), bj = bounds(quads[j])
                let overlap = bi.intersection(bj)
                let overlapArea: Double = overlap.isNull ? 0 : Double(overlap.width * overlap.height)
                // 絵の中の図形どうしでできた小さな四角形のペアを拾わないよう、十分大きいものに限る
                let minimumArea = 0.1 * w * h
                guard areaRatio > 0.8, aspectRatio > 0.85, min(areaI, areaJ) > minimumArea,
                      overlapArea < 0.05 * Double(bi.width * bi.height) else { continue }
                let area = areaI + areaJ
                guard area > (best?.area ?? 0) else { continue }
                // 左右並びなら左、上下並びなら上を A とする
                let horizontal = abs(bi.midX - bj.midX) >= abs(bi.midY - bj.midY)
                let iFirst = horizontal ? bi.midX < bj.midX : bi.midY < bj.midY
                best = iFirst ? (quads[i], quads[j], area) : (quads[j], quads[i], area)
            }
        }
        guard let best else { return nil }
        return rectifiedPair(quadA: best.a, quadB: best.b)
    }

    /// 作業解像度への倍率。大きい絵は長辺 maxWorkDimension に縮小し、
    /// 小さい絵（ネットの画像など）は拡大して、小さな間違いがノイズ除去で消えないようにする
    private func workScale(forLongSide length: Double) -> Double {
        min(maxUpscale, Double(maxWorkDimension) / length)
    }

    /// 2 つの四角形（左上・右上・右下・左下）を、A の大きさの長方形に遠近補正する変換を作る
    private func rectifiedPair(quadA: [SIMD2<Double>], quadB: [SIMD2<Double>]) -> PicturePair? {
        guard quadA.count == 4, quadB.count == 4 else { return nil }
        let top = simd_distance(quadA[0], quadA[1]), bottom = simd_distance(quadA[3], quadA[2])
        let left = simd_distance(quadA[0], quadA[3]), right = simd_distance(quadA[1], quadA[2])
        let sizeA = SIMD2((top + bottom) / 2, (left + right) / 2)
        guard sizeA.x >= 16, sizeA.y >= 16 else { return nil }
        let scale = workScale(forLongSide: max(sizeA.x, sizeA.y))
        let width = max(32, Int((sizeA.x * scale).rounded())), height = max(32, Int((sizeA.y * scale).rounded()))
        let rectCorners = [SIMD2(0, 0), SIMD2(Double(width), 0), SIMD2(Double(width), Double(height)), SIMD2(0, Double(height))]
        let normalization = Double(max(width, height))
        guard let mapA = Homography.fit(from: rectCorners, to: quadA, normalization: normalization),
              let mapB = Homography.fit(from: rectCorners, to: quadB, normalization: normalization) else { return nil }
        return PicturePair(mapA: mapA, mapB: mapB, width: width, height: height)
    }

    // MARK: - 2. 位置合わせ（Vision）

    /// 切り出した A と B を Vision の画像位置合わせ（射影変換）で重ね、B 側の変換を補正する。
    /// 失敗したり結果が不自然なら補正しない。correction は四隅の最大移動量（作業画素）
    private func refineWithVision(source: MTLTexture,
                                  pair: PicturePair) throws -> (pair: PicturePair, correction: Double) {
        let mapA = pair.mapA, mapB = pair.mapB, width = pair.width, height = pair.height
        let identity = DisplacementField.constant(.zero, size: SIMD2(Float(width), Float(height)))
        let cropA = try makeTexture(width: width, height: height, format: .rgba8Unorm)
        let cropB = try makeTexture(width: width, height: height, format: .rgba8Unorm)
        try run { cb in
            try encodeWarp(cb, source: source, destination: cropA, homography: mapA, field: identity)
            try encodeWarp(cb, source: source, destination: cropB, homography: mapB, field: identity)
        }
        guard let imageA = makeImage(from: cropA), let imageB = makeImage(from: cropB) else { return (pair, 0) }

        let request = VNHomographicImageRegistrationRequest(targetedCGImage: imageB, options: [:])
        do {
            try VNImageRequestHandler(cgImage: imageA, options: [:]).perform([request])
        } catch {
            return (pair, 0)
        }
        guard let warp = request.results?.first?.warpTransform else { return (pair, 0) }

        // Vision の行列は「B の座標 → A の座標」（左下原点）。左上原点に直して逆変換すると A → B
        let m = simd_double3x3(columns: (SIMD3<Double>(warp.columns.0), SIMD3<Double>(warp.columns.1),
                                         SIMD3<Double>(warp.columns.2)))
        let flip = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, -1, Double(height)), SIMD3(0, 0, 1)])
        let aToB = Homography(matrix: (flip * m * flip).inverse)

        // 四隅の移動量が絵の大きさの 15% を超えるなら誤推定とみなす
        let corners = [SIMD2(0, 0), SIMD2(Double(width), 0), SIMD2(Double(width), Double(height)), SIMD2(0, Double(height))]
        let correction = corners.map { simd_distance(aToB.apply($0), $0) }.max() ?? 0
        guard correction < 0.15 * Double(max(width, height)) else { return (pair, .infinity) }
        var refined = pair
        refined.mapB = Homography(matrix: mapB.matrix * aToB.matrix)
        return (refined, correction)
    }

    /// 画像を自分自身とずらして重ね、最もよく一致するずれ量 = 2 つの絵の間隔とみなす。
    /// そこからタイル照合で A → B の射影変換を求め、それで一致する部分の範囲を A、写した先を B とする。
    private func locateRegions(in source: MTLTexture) throws -> (a: CGRect, homography: Homography) {
        let scale = min(1, Double(regionSearchDimension) / Double(max(source.width, source.height)))
        let lw = max(32, Int((Double(source.width) * scale).rounded()))
        let lh = max(32, Int((Double(source.height) * scale).rounded()))

        let small = try makeTexture(width: lw, height: lh, format: .rgba8Unorm)
        let rawGradient = try makeTexture(width: lw, height: lh, format: .r32Float)
        let gradient = try makeTexture(width: lw, height: lh, format: .r32Float)
        try run { cb in
            MPSImageLanczosScale(device: device).encode(commandBuffer: cb, sourceTexture: source, destinationTexture: small)
            try encodeGradient(cb, source: small, destination: rawGradient)
            gaussian(sigma: 1.0).encode(commandBuffer: cb, sourceTexture: rawGradient, destinationTexture: gradient)
        }

        // 左右並び・上下並びの両方を探索する
        var candidates: [SIMD2<Int32>] = []
        let skewX = Int(Double(lw) * 0.08), skewY = Int(Double(lh) * 0.08)
        for dx in Int(Double(lw) * 0.25)...Int(Double(lw) * 0.75) {
            for dy in -skewY...skewY { candidates.append(SIMD2(Int32(dx), Int32(dy))) }
        }
        for dy in Int(Double(lh) * 0.25)...Int(Double(lh) * 0.75) {
            for dx in -skewX...skewX { candidates.append(SIMD2(Int32(dx), Int32(dy))) }
        }

        let whole = [SIMD4<Int32>(0, 0, Int32(lw), Int32(lh))]
        let scores = try shiftScores(a: gradient, b: gradient, tiles: whole, candidates: candidates, stride: 1)
        let maxTotal = scores.map(\.y).max() ?? 0
        var best = -1
        var bestRatio = Float.infinity
        for (i, s) in scores.enumerated() where s.y > maxTotal * 0.15 {
            let ratio = s.x / s.y
            if ratio < bestRatio { bestRatio = ratio; best = i }
        }
        guard best >= 0, bestRatio < 0.6 else { throw DetectionError.regionsNotFound }
        let dx = Int(candidates[best].x), dy = Int(candidates[best].y)

        // カメラの傾きで 2 つの絵の大きさ・形が少し違うので、平行移動ではなく射影変換で対応付ける
        let lowHomography = try estimateLowResHomography(gradient: gradient, width: lw, height: lh,
                                                         shift: SIMD2(Double(dx), Double(dy)))

        // 射影変換で一致するエッジの分布から A の範囲を求める
        let g = readFloats(gradient)
        let threshold = g.reduce(0, +) / Float(g.count) * 0.5
        var matched = [Bool](repeating: false, count: lw * lh)
        var textured = [Bool](repeating: false, count: lw * lh)
        for y in 0..<lh {
            for x in 0..<lw {
                let q = lowHomography.apply(SIMD2(Double(x) + 0.5, Double(y) + 0.5))
                let qx = Int(q.x.rounded(.down)), qy = Int(q.y.rounded(.down))
                guard qx >= 0, qx < lw, qy >= 0, qy < lh else { continue }
                let a = g[y * lw + x], b = g[qy * lw + qx]
                textured[y * lw + x] = max(a, b) > threshold
                matched[y * lw + x] = min(a, b) > threshold && abs(a - b) < 0.5 * max(a, b)
            }
        }

        // 絵の中ではエッジの大半が一致するが、絵の外の文字などは偶然の一致がまばらにあるだけ。
        // 周囲のエッジの一致率が高い点だけを残し、それを膨張させてつなげた大きな塊（= 絵本体）で範囲を求める
        let dense = Self.denseMatches(matched: matched, textured: textured, width: lw, height: lh,
                                      radius: max(3, Int(Double(max(lw, lh)) * 0.015)))
        matched = zip(matched, dense).map { $0 && $1 }
        let component = Self.largestCluster(of: matched, width: lw, height: lh,
                                            closingRadius: max(4, Int(Double(max(lw, lh)) * 0.025)),
                                            openingRadius: max(2, Int(Double(max(lw, lh)) * 0.012)))
        debugSink?("map_region", (0..<(lw * lh)).map { i in
            component[i] ? (matched[i] ? 1 : 0.5) : (textured[i] ? 0.2 : 0)
        }, lw, lh)
        var columns = [Float](repeating: 0, count: lw)
        var rows = [Float](repeating: 0, count: lh)
        for y in 0..<lh {
            for x in 0..<lw where matched[y * lw + x] && component[y * lw + x] {
                columns[x] += 1
                rows[y] += 1
            }
        }
        guard var (x0, x1) = Self.extent(of: columns), var (y0, y1) = Self.extent(of: rows) else {
            throw DetectionError.regionsNotFound
        }

        // 絵の端が欠けないよう広めに取る（はみ出した分は位置合わせ後に重なり具合を見て削る）
        let margin = max(2, Int(Double(max(x1 - x0, y1 - y0)) * 0.06))
        x0 = max(0, x0 - margin); y0 = max(0, y0 - margin)
        x1 = min(lw - 1, x1 + margin); y1 = min(lh - 1, y1 + margin)

        // A と B が重ならないように制限（B の手前の辺より内側に収める）
        let cornersB = [(x0, y0), (x1 + 1, y0), (x0, y1 + 1), (x1 + 1, y1 + 1)]
            .map { lowHomography.apply(SIMD2(Double($0.0), Double($0.1))) }
        if abs(dx) >= abs(dy) {
            x1 = min(x1, Int(cornersB.map(\.x).min()!.rounded(.down)) - 1)
        } else {
            y1 = min(y1, Int(cornersB.map(\.y).min()!.rounded(.down)) - 1)
        }
        guard x1 > x0, y1 > y0 else { throw DetectionError.regionsNotFound }

        let factor = SIMD2(Double(source.width) / Double(lw), Double(source.height) / Double(lh))
        let homography = lowHomography.scaled(by: factor)
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let rectA = CGRect(x: Double(x0) * factor.x, y: Double(y0) * factor.y,
                           width: Double(x1 - x0 + 1) * factor.x, height: Double(y1 - y0 + 1) * factor.y)
            .intersection(bounds)
            .integral
        guard !rectA.isNull, rectA.width >= 48, rectA.height >= 48 else { throw DetectionError.regionsNotFound }
        return (rectA, homography)
    }

    /// 低解像度の勾配画像をタイルに分けてずれ量 shift の周辺を探索し、
    /// RANSAC で外れ値（文字や間違い部分のタイル）を除いて A → B の射影変換を求める。
    private func estimateLowResHomography(gradient: MTLTexture, width: Int, height: Int,
                                          shift: SIMD2<Double>) throws -> Homography {
        let fallback = Homography.translation(shift)
        let tile = max(12, Int(Double(max(width, height)) / 14))
        let gx = max(1, width / tile), gy = max(1, height / tile)
        let tileW = Double(width) / Double(gx), tileH = Double(height) / Double(gy)
        var tiles: [SIMD4<Int32>] = []
        var centers: [SIMD2<Double>] = []
        for j in 0..<gy {
            for i in 0..<gx {
                let c = SIMD2((Double(i) + 0.5) * tileW, (Double(j) + 0.5) * tileH)
                centers.append(c)
                tiles.append(SIMD4(Int32(c.x - tileW), Int32(c.y - tileH), Int32(tileW * 2), Int32(tileH * 2)))
            }
        }
        let r = max(6, Int(Double(max(width, height)) * 0.04)), side = 2 * r + 1
        var candidates: [SIMD2<Int32>] = []
        for oy in -r...r {
            for ox in -r...r { candidates.append(SIMD2(Int32(shift.x) + Int32(ox), Int32(shift.y) + Int32(oy))) }
        }
        let scores = try shiftScores(a: gradient, b: gradient, tiles: tiles, candidates: candidates, stride: 1)

        let centerIndex = r * side + r
        let totals = tiles.indices.map { scores[$0 * candidates.count + centerIndex].y }
        let meanTotal = totals.reduce(0, +) / Float(max(1, totals.count))
        var from: [SIMD2<Double>] = [], to: [SIMD2<Double>] = []
        for t in tiles.indices where totals[t] > meanTotal * 0.25 {
            let base = t * candidates.count
            var bestIndex = 0
            var bestRatio = Float.infinity
            for k in 0..<candidates.count {
                let value = Self.ratio(scores[base + k])
                if value < bestRatio { bestRatio = value; bestIndex = k }
            }
            guard bestRatio < 0.5 else { continue }
            let kx = bestIndex % side, ky = bestIndex / side
            func ratioAt(_ x: Int, _ y: Int) -> Float { Self.ratio(scores[base + y * side + x]) }
            var sub = SIMD2<Double>(0, 0)
            if kx > 0 && kx < side - 1 {
                sub.x = Double(Self.parabolaPeak(ratioAt(kx - 1, ky), bestRatio, ratioAt(kx + 1, ky)))
            }
            if ky > 0 && ky < side - 1 {
                sub.y = Double(Self.parabolaPeak(ratioAt(kx, ky - 1), bestRatio, ratioAt(kx, ky + 1)))
            }
            let c = candidates[bestIndex]
            from.append(centers[t])
            to.append(centers[t] + SIMD2(Double(c.x), Double(c.y)) + sub)
        }
        return Self.ransacHomography(from: from, to: to, normalization: Double(max(width, height)),
                                     inlierDistance: 1.5) ?? fallback
    }

    private static func ransacHomography(from p: [SIMD2<Double>], to q: [SIMD2<Double>],
                                         normalization: Double, inlierDistance: Double) -> Homography? {
        guard p.count >= 6 else { return nil }
        func inliers(of h: Homography) -> [Int] {
            p.indices.filter { simd_length(h.apply(p[$0]) - q[$0]) <= inlierDistance }
        }
        var best: [Int] = []
        var state: UInt64 = 0x2545_F491_4F6C_DD1D   // 結果が毎回同じになるよう固定シードの xorshift
        func random(_ n: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(n))
        }
        for _ in 0..<300 {
            var sample = Set<Int>()
            while sample.count < 4 { sample.insert(random(p.count)) }
            let indices = Array(sample)
            guard let h = Homography.fit(from: indices.map { p[$0] }, to: indices.map { q[$0] },
                                         normalization: normalization) else { continue }
            let found = inliers(of: h)
            if found.count > best.count { best = found }
        }
        guard best.count >= 6 else { return nil }
        // インライアで再推定し、もう一度インライアを取り直して仕上げる
        var model = Homography.fit(from: best.map { p[$0] }, to: best.map { q[$0] }, normalization: normalization)
        if let refined = model {
            let again = inliers(of: refined)
            if again.count >= 6 {
                model = Homography.fit(from: again.map { p[$0] }, to: again.map { q[$0] }, normalization: normalization) ?? model
            }
        }
        return model
    }

    /// 正方形 (2r+1)² による二値膨張（横 → 縦の分離可能な実装）
    private static func dilate(_ points: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        func pass(_ input: [Bool], length: Int, lines: Int, index: (Int, Int) -> Int) -> [Bool] {
            var output = [Bool](repeating: false, count: input.count)
            var nextHit = [Int](repeating: 0, count: length)
            for line in 0..<lines {
                var upcoming = Int.max / 2
                for i in stride(from: length - 1, through: 0, by: -1) {
                    if input[index(line, i)] { upcoming = i }
                    nextHit[i] = upcoming
                }
                var lastHit = Int.min / 2
                for i in 0..<length {
                    if input[index(line, i)] { lastHit = i }
                    output[index(line, i)] = i - lastHit <= radius || nextHit[i] - i <= radius
                }
            }
            return output
        }
        let horizontal = pass(points, length: width, lines: height) { $0 * width + $1 }
        return pass(horizontal, length: height, lines: width) { $1 * width + $0 }
    }

    private static func erode(_ points: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        dilate(points.map { !$0 }, width: width, height: height, radius: radius).map { !$0 }
    }

    /// 周囲 (2r+1)² のエッジのうち一致したものの割合が十分高い点
    private static func denseMatches(matched: [Bool], textured: [Bool], width: Int, height: Int,
                                     radius: Int) -> [Bool] {
        // 積分画像で窓内の個数を数える
        func integral(_ values: [Bool]) -> [Int] {
            var sums = [Int](repeating: 0, count: (width + 1) * (height + 1))
            for y in 0..<height {
                var row = 0
                for x in 0..<width {
                    if values[y * width + x] { row += 1 }
                    sums[(y + 1) * (width + 1) + x + 1] = sums[y * (width + 1) + x + 1] + row
                }
            }
            return sums
        }
        let m = integral(matched), t = integral(textured)
        func count(_ sums: [Int], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
            sums[y1 * (width + 1) + x1] - sums[y0 * (width + 1) + x1] - sums[y1 * (width + 1) + x0]
                + sums[y0 * (width + 1) + x0]
        }
        var result = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width where matched[y * width + x] {
                let x0 = max(0, x - radius), y0 = max(0, y - radius)
                let x1 = min(width, x + radius + 1), y1 = min(height, y + radius + 1)
                let edges = count(t, x0, y0, x1, y1)
                result[y * width + x] = edges >= 6 && Double(count(m, x0, y0, x1, y1)) >= Double(edges) * 0.45
            }
        }
        return result
    }

    /// 点の集まりを塊にして 4 近傍でつなぎ、元の点を多く含む塊（最大の塊の 1/10 以上）を返す
    private static func largestCluster(of points: [Bool], width: Int, height: Int,
                                       closingRadius: Int, openingRadius: Int) -> [Bool] {
        // 大きめのクロージングで絵の中（図形の輪郭どうしの隙間）を塗りつぶし、
        // オープニングで紙の縁などの孤立した細い線を消す
        let closed = erode(dilate(points, width: width, height: height, radius: closingRadius),
                           width: width, height: height, radius: closingRadius)
        let dilated = dilate(erode(closed, width: width, height: height, radius: openingRadius),
                             width: width, height: height, radius: openingRadius)

        var labels = [Int](repeating: -1, count: points.count)
        var counts: [Int] = []
        var thicknesses: [Int] = []
        var stack: [Int] = []
        for start in points.indices where dilated[start] && labels[start] < 0 {
            let label = counts.count
            var count = 0
            var minX = width, maxX = 0, minY = height, maxY = 0
            labels[start] = label
            stack.append(start)
            while let index = stack.popLast() {
                if points[index] { count += 1 }
                let x = index % width, y = index / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && nx < width && ny >= 0 && ny < height {
                    let n = ny * width + nx
                    if dilated[n] && labels[n] < 0 {
                        labels[n] = label
                        stack.append(n)
                    }
                }
            }
            counts.append(count)
            thicknesses.append(min(maxX - minX, maxY - minY) + 1)
        }
        // 紙の縁や罫線のような細長い直線は、ずらしても自分自身と一致してしまうので絵とみなさない
        let minThickness = Int(Double(min(width, height)) * 0.08)
        let candidates = counts.indices.filter { thicknesses[$0] >= minThickness }
        // 絵の中の平坦な部分で塊が分かれることがあるので、十分大きい塊はすべて含める
        guard let largest = candidates.map({ counts[$0] }).max(), largest > 0 else {
            return [Bool](repeating: false, count: points.count)
        }
        let significant = counts.indices.map { thicknesses[$0] >= minThickness && counts[$0] >= max(1, largest / 10) }
        return labels.map { $0 >= 0 && significant[$0] }
    }

    /// プロファイルが最大値の 12% を超える最初と最後の位置
    private static func extent(of profile: [Float]) -> (Int, Int)? {
        let n = profile.count
        var smoothed = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - 2), hi = min(n - 1, i + 2)
            smoothed[i] = profile[lo...hi].reduce(0, +) / Float(hi - lo + 1)
        }
        guard let peak = smoothed.max(), peak > 0 else { return nil }
        let limit = peak * 0.12
        guard let first = smoothed.firstIndex(where: { $0 > limit }),
              let last = smoothed.lastIndex(where: { $0 > limit }), last > first else { return nil }
        return (first, last)
    }

    // MARK: - 2. 位置合わせ

    /// 射影変換で重ねた後に残るずれを、タイルごとの探索 + 外れ値に強いフィットで変位場にする。
    /// 低解像度での推定誤差や紙のたわみを吸収する。
    private func estimateField(gradA: MTLTexture, gradB: MTLTexture, width: Int,
                               height: Int, upscale: Double) throws -> DisplacementField {
        // 拡大している場合は、タイルと探索範囲も元の画素単位で揃える
        let tileSize = tileTargetSize * max(1, upscale / 2)
        let gx = max(1, Int((Double(width) / tileSize).rounded()))
        let gy = max(1, Int((Double(height) / tileSize).rounded()))
        let tileW = Float(width) / Float(gx), tileH = Float(height) / Float(gy)

        var tiles: [SIMD4<Int32>] = []
        for j in 0..<gy {
            for i in 0..<gx {
                let cx = (Float(i) + 0.5) * tileW, cy = (Float(j) + 0.5) * tileH
                tiles.append(SIMD4(Int32(cx - tileW), Int32(cy - tileH), Int32(tileW * 2), Int32(tileH * 2)))
            }
        }
        let r = min(16, Int((Double(localSearchRadius) * upscale.squareRoot()).rounded())), side = 2 * r + 1
        var candidates: [SIMD2<Int32>] = []
        for dy in -r...r {
            for dx in -r...r { candidates.append(SIMD2(Int32(dx), Int32(dy))) }
        }
        let scores = try shiftScores(a: gradA, b: gradB, tiles: tiles, candidates: candidates, stride: 2)

        let centerIndex = r * side + r
        let totals = tiles.indices.map { scores[$0 * candidates.count + centerIndex].y }
        let meanTotal = totals.reduce(0, +) / Float(max(1, totals.count))

        var estimates = [SIMD2<Float>?](repeating: nil, count: tiles.count)
        for t in tiles.indices {
            let base = t * candidates.count
            func ratioAt(_ x: Int, _ y: Int) -> Float { Self.ratio(scores[base + y * side + x]) }
            var bestIndex = 0
            var bestRatio = Float.infinity
            for k in 0..<candidates.count {
                let value = Self.ratio(scores[base + k])
                if value < bestRatio { bestRatio = value; bestIndex = k }
            }
            guard totals[t] > meanTotal * 0.25, bestRatio < 0.7 else { continue }
            let kx = bestIndex % side, ky = bestIndex / side
            var sub = SIMD2<Float>(0, 0)
            if kx > 0 && kx < side - 1 {
                sub.x = Self.parabolaPeak(ratioAt(kx - 1, ky), bestRatio, ratioAt(kx + 1, ky))
            }
            if ky > 0 && ky < side - 1 {
                sub.y = Self.parabolaPeak(ratioAt(kx, ky - 1), bestRatio, ratioAt(kx, ky + 1))
            }
            let c = candidates[bestIndex]
            estimates[t] = SIMD2<Float>(Float(c.x), Float(c.y)) + sub
        }

        // 全体の傾き・拡大はアフィン変換で表し、残差（紙のたわみ等）だけを 3x3 メディアンで平滑化する。
        // 間違い部分などでの誤推定はアフィンの外れ値除去とメディアンで周囲に合わせられる。
        let centers = tiles.indices.map { t in
            SIMD2<Float>((Float(t % gx) + 0.5) * tileW, (Float(t / gx) + 0.5) * tileH)
        }
        let affine = Self.fitAffine(points: centers, estimates: estimates) ?? AffineModel(constant: .zero)

        var residuals = [SIMD2<Float>](repeating: .zero, count: tiles.count)
        for j in 0..<gy {
            for i in 0..<gx {
                var xs: [Float] = [], ys: [Float] = []
                for nj in max(0, j - 1)...min(gy - 1, j + 1) {
                    for ni in max(0, i - 1)...min(gx - 1, i + 1) {
                        let n = nj * gx + ni
                        if let e = estimates[n] {
                            let residual = e - affine.apply(centers[n])
                            xs.append(residual.x); ys.append(residual.y)
                        }
                    }
                }
                guard !xs.isEmpty else { continue }
                xs.sort(); ys.sort()
                residuals[j * gx + i] = simd_clamp(SIMD2(xs[xs.count / 2], ys[ys.count / 2]),
                                                   SIMD2(repeating: -3), SIMD2(repeating: 3))
            }
        }
        return DisplacementField(affine: affine, residuals: residuals, dims: SIMD2(UInt32(gx), UInt32(gy)),
                                 tileSize: SIMD2(tileW, tileH))
    }

    /// 縮小画像の輝度比 A/B に平面 gain = x·u + y·v + z をフィットする（u, v は 0〜1）。
    /// 間違い部分は外れ値として除かれるので、その周囲の補正が歪まない。
    private static func fitGainPlane(a: [UInt8], b: [UInt8], width: Int, height: Int) -> SIMD3<Float> {
        func luma(_ p: [UInt8], _ i: Int) -> Float {
            (0.299 * Float(p[i]) + 0.587 * Float(p[i + 1]) + 0.114 * Float(p[i + 2])) / 255
        }
        var points: [SIMD2<Float>] = []
        var ratios: [SIMD2<Float>?] = []
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                points.append(SIMD2((Float(x) + 0.5) / Float(width), (Float(y) + 0.5) / Float(height)))
                let ratio = (luma(a, i) + 0.02) / (luma(b, i) + 0.02)
                ratios.append(SIMD2(ratio, 0))
            }
        }
        guard let model = fitAffine(points: points, estimates: ratios, minimumLimit: 0.03) else {
            return SIMD3(0, 0, 1)
        }
        return model.x
    }

    /// 外れ値を除きながら最小二乗でアフィン変換をフィットする
    private static func fitAffine(points: [SIMD2<Float>], estimates: [SIMD2<Float>?],
                                  minimumLimit: Float = 1.0) -> AffineModel? {
        var inliers = points.indices.filter { estimates[$0] != nil }
        var model: AffineModel?
        for _ in 0..<3 {
            guard inliers.count >= 6 else { return model }
            // 正規方程式 (XᵀX) β = Xᵀy を x 成分・y 成分それぞれで解く
            var xtx = simd_double3x3(0)
            var xty = (SIMD3<Double>(repeating: 0), SIMD3<Double>(repeating: 0))
            for i in inliers {
                let row = SIMD3<Double>(Double(points[i].x), Double(points[i].y), 1)
                let e = estimates[i]!
                xtx += simd_double3x3(rows: [row * row.x, row * row.y, row * row.z])
                xty.0 += row * Double(e.x)
                xty.1 += row * Double(e.y)
            }
            guard abs(xtx.determinant) > 1e-9 else { return model }
            let inverse = xtx.inverse
            let fitted = AffineModel(x: SIMD3<Float>(inverse * xty.0), y: SIMD3<Float>(inverse * xty.1))
            model = fitted
            let residuals = inliers.map { simd_length(estimates[$0]! - fitted.apply(points[$0])) }
            let sorted = residuals.sorted()
            let limit = max(minimumLimit, sorted[sorted.count / 2] * 3)
            inliers = zip(inliers, residuals).filter { $0.1 <= limit }.map(\.0)
        }
        return model
    }

    private static func ratio(_ score: SIMD2<Float>) -> Float {
        score.y > 1e-6 ? score.x / score.y : .infinity
    }

    private static func parabolaPeak(_ left: Float, _ center: Float, _ right: Float) -> Float {
        let denominator = left - 2 * center + right
        guard denominator > 1e-6, left.isFinite, right.isFinite else { return 0 }
        return min(0.5, max(-0.5, 0.5 * (left - right) / denominator))
    }

    // MARK: - 3. 範囲の仕上げ

    /// 位置合わせ後の 2 枚を重ね、行・列ごとに輪郭が「合う」「合わない（文字など）」「ない」を判定し、
    /// 外側の合わない部分を削る。残った範囲 = 2 枚がよく重なる部分 = 絵本体
    /// 列の判定は決まった行の範囲だけで行う（逆も同様）ので、上下の文字が列の判定を乱さない。
    private static func overlapBounds(difference: [Float], gradA: [Float], gradB: [Float], width: Int, height: Int,
                                      threshold: Float) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        let edgeLevel = max(gradA.reduce(0, +), gradB.reduce(0, +)) / Float(width * height)
        let isEdge = gradA.indices.map { max(gradA[$0], gradB[$0]) > edgeLevel }
        let agrees = difference.map { $0 < threshold * 0.6 }

        enum Kind { case good, bad, empty }
        let binCount = 8
        /// 区間 lines を、範囲 span 内の画素で判定し、最も良い区間を返す
        func bestRun(lines: Int, span: ClosedRange<Int>, index: (Int, Int) -> Int) -> ClosedRange<Int>? {
            // 線ごと・区画ごとの輪郭の数と、そのうち合っている数
            var edges = [[Int]](repeating: [Int](repeating: 0, count: binCount), count: lines)
            var agree = edges
            for line in 0..<lines {
                for p in span {
                    let i = index(line, p)
                    guard isEdge[i] else { continue }
                    let bin = (p - span.lowerBound) * binCount / span.count
                    edges[line][bin] += 1
                    if agrees[i] { agree[line][bin] += 1 }
                }
            }
            // 5 本ずつまとめ、区画ごとに「合う」「合わない」を判定する。
            // 間違いは一部の区画にしか出ないが、文字の行などは多くの区画で合わない
            let minEdges = max(3, Int(Double(span.count) / Double(binCount) * 5 * 0.02))
            let kinds = (0..<lines).map { line -> Kind in
                let range = max(0, line - 2)...min(lines - 1, line + 2)
                var agreeBins = 0, disagreeBins = 0, edgeBins = 0
                for bin in 0..<binCount {
                    let e = range.reduce(0) { $0 + edges[$1][bin] }, a = range.reduce(0) { $0 + agree[$1][bin] }
                    guard e >= minEdges else { continue }
                    edgeBins += 1
                    if Double(a) >= Double(e) * 0.6 { agreeBins += 1 } else if Double(a) < Double(e) * 0.4 { disagreeBins += 1 }
                }
                // まばらな文字だけの線も「合わない」とみなす
                if disagreeBins > 0 && agreeBins == 0 { return .bad }
                guard edgeBins >= 2 else { return .empty }
                if disagreeBins * 2 >= edgeBins { return .bad }
                return agreeBins * 2 >= edgeBins ? .good : .empty
            }
            // 端から内側へ見て「合う」線がまとまって続き始める位置を絵の始まりとし、
            // それより外側の最後の「合わない」線までを削る。
            // 絵の中の間違いで合わない線があっても、絵の途中で切ることはしない
            let window = max(3, lines / 20)
            func startsPicture(_ line: Int, step: Int) -> Bool {
                guard kinds[line] == .good else { return false }
                var good = 0, bad = 0
                for k in 0..<window {
                    let i = line + k * step
                    guard i >= 0 && i < lines else { break }
                    if kinds[i] == .good { good += 1 } else if kinds[i] == .bad { bad += 1 }
                }
                return good >= bad * 3 && good * 3 >= window
            }
            func trimmed(from edge: Int, step: Int) -> Int? {
                var line = edge, lastBad: Int?
                var start: Int?
                while line >= 0 && line < lines {
                    if startsPicture(line, step: step) { start = lastBad.map { $0 + step } ?? edge; break }
                    if kinds[line] == .bad { lastBad = line }
                    line += step
                }
                guard var start else { return nil }
                // 紙の縁など、2 枚で同じ位置に写って「合う」構造が外側にあると、その内側の文字などが残る。
                // 外側 12% の中で「合わない」線が 5 本以上続く所があれば、そこまで削る
                var run = 0
                for k in 0..<(lines * 12 / 100) {
                    let i = edge + k * step
                    run = kinds[i] == .bad ? run + 1 : 0
                    if run >= 5, (i - start) * step >= 0 { start = i + step }
                }
                return start
            }
            guard let first = trimmed(from: 0, step: 1), let last = trimmed(from: lines - 1, step: -1),
                  last - first + 1 >= lines / 4 else { return nil }   // うまく判定できなければ削らない
            return first...last
        }

        var rows = 0...(height - 1), columns = 0...(width - 1)
        for _ in 0..<2 {
            rows = bestRun(lines: height, span: columns) { $0 * width + $1 } ?? rows
            columns = bestRun(lines: width, span: rows) { $1 * width + $0 } ?? columns
        }
        return (columns.lowerBound, rows.lowerBound, columns.upperBound, rows.upperBound)
    }

    // MARK: - 4. 連結成分

    /// - Parameter limits: 画素ごとのしきい値（これ以上の差分を間違いの芯とする）
    private func extractBlobs(mask: [UInt8], difference: [Float], limits: [Float], width: Int, height: Int,
                              edgeBand band: Int, maxCount: Int) -> [Blob] {
        var visited = [Bool](repeating: false, count: width * height)
        var blobs: [Blob] = []
        var stack: [Int] = []

        for start in 0..<(width * height) where mask[start] > 127 && !visited[start] {
            visited[start] = true
            stack.append(start)
            var blob = Blob(minX: width, minY: height, maxX: 0, maxY: 0, core: 0, coreNearEdge: 0, score: 0)
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                blob.minX = min(blob.minX, x); blob.maxX = max(blob.maxX, x)
                blob.minY = min(blob.minY, y); blob.maxY = max(blob.maxY, y)
                let d = difference[index]
                if d >= limits[index] {
                    blob.core += 1
                    blob.score += d
                    if x < band || y < band || x >= width - band || y >= height - band { blob.coreNearEdge += 1 }
                }
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) {
                        let n = ny * width + nx
                        if mask[n] > 127 && !visited[n] {
                            visited[n] = true
                            stack.append(n)
                        }
                    }
                }
            }
            blobs.append(blob)
        }

        // 範囲の縁に沿って細長く伸びる差分や、差分の大半が縁の帯にあるものは、
        // 絵の境界（外側の余白・文字・枠）のずれなので除く
        blobs.removeAll { blob in
            if Double(blob.coreNearEdge) > Double(blob.core) * 0.6 { return true }
            let w = blob.maxX - blob.minX + 1, h = blob.maxY - blob.minY + 1
            let touchesVerticalEdge = blob.minX <= band || blob.maxX >= width - 1 - band
            let touchesHorizontalEdge = blob.minY <= band || blob.maxY >= height - 1 - band
            return (touchesVerticalEdge && h >= w * 3) || (touchesHorizontalEdge && w >= h * 3)
        }

        // ノイズが多い場合でも計算量を抑える
        if blobs.count > 200 {
            blobs = Array(blobs.sorted { $0.score > $1.score }.prefix(200))
        }

        // 近接した断片を 1 つの間違いにまとめる。
        // 大きな間違い（色の変わった敷物など）が近くの別の間違いを次々と取り込まないよう、
        // まとめると外接矩形が大きく膨らむ組み合わせはまとめない
        let gap = Int(Double(max(width, height)) * 0.02)
        var merged = true
        while merged {
            merged = false
            search: for i in blobs.indices {
                for j in (i + 1)..<blobs.count where blobs[i].isNear(blobs[j], gap: gap)
                        && blobs[i].fitsTogether(with: blobs[j], maxGrowth: mergeGrowthLimit) {
                    blobs[i].absorb(blobs[j])
                    blobs.remove(at: j)
                    merged = true
                    break search
                }
            }
        }

        let minCore = max(12, Int(Double(width * height) * 0.00003))
        // 一番大きい間違いとの比で足切りすると、大きな間違い（傘など）があるときに細い線の間違いが消えるので、
        // 大きさの下限だけで判定する（ノイズは画素ごとのしきい値 limits で抑えている）
        return Array(blobs.filter { $0.core >= minCore }.sorted { $0.score > $1.score }.prefix(maxCount))
    }

    // MARK: - Metal ヘルパー

    private func shiftScores(a: MTLTexture, b: MTLTexture, tiles: [SIMD4<Int32>],
                             candidates: [SIMD2<Int32>], stride: Int) throws -> [SIMD2<Float>] {
        let count = tiles.count * candidates.count
        guard let tileBuffer = device.makeBuffer(bytes: tiles, length: MemoryLayout<SIMD4<Int32>>.stride * tiles.count,
                                                 options: .storageModeShared),
              let candidateBuffer = device.makeBuffer(bytes: candidates,
                                                      length: MemoryLayout<SIMD2<Int32>>.stride * candidates.count,
                                                      options: .storageModeShared),
              let scoreBuffer = device.makeBuffer(length: MemoryLayout<SIMD2<Float>>.stride * count,
                                                  options: .storageModeShared) else {
            throw DetectionError.resourceCreationFailed
        }
        var params = ShiftParams(candidateCount: UInt32(candidates.count), stride: UInt32(stride))
        try run { cb in
            guard let enc = cb.makeComputeCommandEncoder() else { throw DetectionError.commandFailed }
            enc.setComputePipelineState(shiftPipeline)
            enc.setTexture(a, index: 0)
            enc.setTexture(b, index: 1)
            enc.setBuffer(tileBuffer, offset: 0, index: 0)
            enc.setBuffer(candidateBuffer, offset: 0, index: 1)
            enc.setBuffer(scoreBuffer, offset: 0, index: 2)
            enc.setBytes(&params, length: MemoryLayout<ShiftParams>.stride, index: 3)
            enc.dispatchThreadgroups(MTLSize(width: candidates.count, height: tiles.count, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: shiftThreadgroupSize, height: 1, depth: 1))
            enc.endEncoding()
        }
        let pointer = scoreBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private func encodeGradient(_ cb: MTLCommandBuffer, source: MTLTexture, destination: MTLTexture) throws {
        try encodeKernel(cb, gradientPipeline, width: destination.width, height: destination.height) { enc in
            enc.setTexture(source, index: 0)
            enc.setTexture(destination, index: 1)
        }
    }

    /// destination の画素 p に、source の homography(p + 変位場(p)) の色を書く
    private func encodeWarp(_ cb: MTLCommandBuffer, source: MTLTexture, destination: MTLTexture,
                            homography: Homography, field: DisplacementField) throws {
        let origin = SIMD2<Float>(0, 0), scale = SIMD2<Float>(1, 1)
        let sourceSize = SIMD2<Float>(Float(source.width), Float(source.height))
        guard let fieldBuffer = device.makeBuffer(bytes: field.residuals,
                                                  length: MemoryLayout<SIMD2<Float>>.stride * field.residuals.count,
                                                  options: .storageModeShared) else {
            throw DetectionError.resourceCreationFailed
        }
        let h = homography.rows
        var params = WarpParams(h0: h.0, h1: h.1, h2: h.2, affineX: field.affine.x, affineY: field.affine.y, origin: origin, scale: scale, sourceSize: sourceSize,
                                tileSize: field.tileSize, fieldDims: field.dims)
        try encodeKernel(cb, warpPipeline, width: destination.width, height: destination.height) { enc in
            enc.setTexture(source, index: 0)
            enc.setTexture(destination, index: 1)
            enc.setBuffer(fieldBuffer, offset: 0, index: 0)
            enc.setBytes(&params, length: MemoryLayout<WarpParams>.stride, index: 1)
        }
    }

    private func gaussian(sigma: Float) -> MPSImageGaussianBlur {
        let blur = MPSImageGaussianBlur(device: device, sigma: sigma)
        blur.edgeMode = .clamp
        return blur
    }

    private func encodeKernel(_ cb: MTLCommandBuffer, _ pipeline: MTLComputePipelineState, width: Int, height: Int,
                              _ configure: (MTLComputeCommandEncoder) -> Void) throws {
        guard let enc = cb.makeComputeCommandEncoder() else { throw DetectionError.commandFailed }
        enc.setComputePipelineState(pipeline)
        configure(enc)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
    }

    private func run(_ encode: (MTLCommandBuffer) throws -> Void) throws {
        guard let cb = queue.makeCommandBuffer() else { throw DetectionError.commandFailed }
        try encode(cb)
        cb.commit()
        cb.waitUntilCompleted()
        if cb.status == .error { throw DetectionError.commandFailed }
    }

    private func makeTexture(width: Int, height: Int, format: MTLPixelFormat) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw DetectionError.resourceCreationFailed
        }
        return texture
    }

    private func makeTexture(from image: CGImage) throws -> MTLTexture {
        let width = image.width, height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw DetectionError.resourceCreationFailed }
        let texture = try makeTexture(width: width, height: height, format: .rgba8Unorm)
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: bytesPerRow)
        return texture
    }

    private func makeImage(from texture: MTLTexture) -> CGImage? {
        let bytesPerRow = texture.width * 4
        let bytes = readBytes(texture, bytesPerPixel: 4)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func readFloats(_ texture: MTLTexture) -> [Float] {
        var values = [Float](repeating: 0, count: texture.width * texture.height)
        values.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: texture.width * MemoryLayout<Float>.stride,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return values
    }

    private func readBytes(_ texture: MTLTexture, bytesPerPixel: Int = 1) -> [UInt8] {
        var values = [UInt8](repeating: 0, count: texture.width * texture.height * bytesPerPixel)
        values.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: texture.width * bytesPerPixel,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return values
    }
}
