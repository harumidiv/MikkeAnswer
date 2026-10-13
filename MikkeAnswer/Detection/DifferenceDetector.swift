//
//  DifferenceDetector.swift
//  MikkeAnswer
//
//  1 枚の画像に並んだ 2 つの絵を見つけ、差分（間違い）を検出する。
//  重い画像処理はすべて Metal（独自カーネル + Metal Performance Shaders）で行う。
//
//  1. 領域確定   : 低解像度の勾配画像を自分自身とずらして照合し、2 つの絵のずれ量を求める。
//                  さらにタイル照合から A → B の射影変換を推定し、それで一致する画素の塊を絵の範囲とする
//  2. 位置合わせ : 射影変換で B を重ねたうえで、タイルごとの局所テンプレートマッチングで残りのずれを補正する
//  3. 差分       : 照明補正 + 近傍最小色差 → 二値化 → 収縮・膨張 → 連結成分を間違いとして抽出
//

import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders

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

    /// 領域確定に使う低解像度画像の長辺
    private let regionSearchDimension = 320
    /// 差分計算に使う作業解像度の長辺
    private let maxWorkDimension: CGFloat = 1024
    /// 局所位置合わせのタイルサイズ（作業画素）
    private let tileTargetSize: Double = 80
    /// 局所位置合わせの探索半径（作業画素）
    private let localSearchRadius = 6
    private let shiftThreadgroupSize = 256
    /// 照明補正の推定に使う縮小画像の長辺
    private let illuminationGridSize: Double = 48

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

    func detect(in image: CGImage, options: DetectionOptions = DetectionOptions()) throws -> DetectionResult {
        lock.lock()
        defer { lock.unlock() }
        let start = Date()

        let source = try makeTexture(from: image)
        let sourceSize = SIMD2<Float>(Float(source.width), Float(source.height))

        // 1. 2 つの絵の範囲を確定
        let regions = try locateRegions(in: source)
        let rectA = regions.a, rectB = regions.b, homography = regions.homography

        let workScale = min(1, maxWorkDimension / max(rectA.width, rectA.height))
        let workW = max(32, Int((rectA.width * workScale).rounded()))
        let workH = max(32, Int((rectA.height * workScale).rounded()))
        let workSize = SIMD2<Float>(Float(workW), Float(workH))
        let pixelScale = SIMD2<Float>(Float(rectA.width) / Float(workW), Float(rectA.height) / Float(workH))
        let originA = SIMD2<Float>(Float(rectA.minX), Float(rectA.minY))

        // 2. 作業解像度で A を切り出し、B は射影変換で A に重ねて切り出す。位置合わせ用の勾配画像も作る
        let cropA = try makeTexture(width: workW, height: workH, format: .rgba8Unorm)
        let cropB = try makeTexture(width: workW, height: workH, format: .rgba8Unorm)
        let rawGradA = try makeTexture(width: workW, height: workH, format: .r32Float)
        let rawGradB = try makeTexture(width: workW, height: workH, format: .r32Float)
        let gradA = try makeTexture(width: workW, height: workH, format: .r32Float)
        let gradB = try makeTexture(width: workW, height: workH, format: .r32Float)
        let identity = DisplacementField.constant(.zero, size: workSize)
        try run { cb in
            try encodeWarp(cb, source: source, destination: cropA, origin: originA, scale: pixelScale,
                           sourceSize: sourceSize, homography: .identity, field: identity)
            try encodeWarp(cb, source: source, destination: cropB, origin: originA, scale: pixelScale,
                           sourceSize: sourceSize, homography: homography, field: identity)
            try encodeGradient(cb, source: cropA, destination: rawGradA)
            try encodeGradient(cb, source: cropB, destination: rawGradB)
            gaussian(sigma: 1.0).encode(commandBuffer: cb, sourceTexture: rawGradA, destinationTexture: gradA)
            gaussian(sigma: 1.0).encode(commandBuffer: cb, sourceTexture: rawGradB, destinationTexture: gradB)
        }

        // 3. 射影変換で合わせきれない残りのずれ（局所変位場）
        let field = try estimateField(gradA: gradA, gradB: gradB, width: workW, height: workH)

        // 4. B をワープして差分を取る
        let warpedB = try makeTexture(width: workW, height: workH, format: .rgba8Unorm)
        let smoothA = try makeTexture(width: workW, height: workH, format: .rgba8Unorm)
        let smoothB = try makeTexture(width: workW, height: workH, format: .rgba8Unorm)
        let thumbW = max(4, Int((Double(workW) * illuminationGridSize / Double(max(workW, workH))).rounded()))
        let thumbH = max(4, Int((Double(workH) * illuminationGridSize / Double(max(workW, workH))).rounded()))
        let thumbA = try makeTexture(width: thumbW, height: thumbH, format: .rgba8Unorm)
        let thumbB = try makeTexture(width: thumbW, height: thumbH, format: .rgba8Unorm)
        let difference = try makeTexture(width: workW, height: workH, format: .r32Float)
        let mask = try makeTexture(width: workW, height: workH, format: .r8Unorm)
        let eroded = try makeTexture(width: workW, height: workH, format: .r8Unorm)
        let dilated = try makeTexture(width: workW, height: workH, format: .r8Unorm)

        let sensitivity = min(max(options.sensitivity, 0), 1)
        // RGB ユークリッド距離（0〜√3）に対するしきい値
        let threshold = 0.40 - 0.28 * sensitivity
        let border = UInt32(Double(min(workW, workH)) * 0.015) + 2

        try run { cb in
            try encodeWarp(cb, source: source, destination: warpedB, origin: originA, scale: pixelScale,
                           sourceSize: sourceSize, homography: homography, field: field)
            gaussian(sigma: 1.0).encode(commandBuffer: cb, sourceTexture: cropA, destinationTexture: smoothA)
            gaussian(sigma: 1.0).encode(commandBuffer: cb, sourceTexture: warpedB, destinationTexture: smoothB)
            let downscale = MPSImageLanczosScale(device: device)
            downscale.encode(commandBuffer: cb, sourceTexture: cropA, destinationTexture: thumbA)
            downscale.encode(commandBuffer: cb, sourceTexture: warpedB, destinationTexture: thumbB)
        }
        let gainPlane = Self.fitGainPlane(a: readBytes(thumbA, bytesPerPixel: 4), b: readBytes(thumbB, bytesPerPixel: 4),
                                          width: thumbW, height: thumbH)

        try run { cb in
            var differenceParams = DifferenceParams(gainPlane: gainPlane, radius: 2)
            try encodeKernel(cb, differencePipeline, width: workW, height: workH) { enc in
                enc.setTexture(smoothA, index: 0)
                enc.setTexture(smoothB, index: 1)
                enc.setTexture(difference, index: 2)
                enc.setBytes(&differenceParams, length: MemoryLayout<DifferenceParams>.stride, index: 0)
            }

            var params = ThresholdParams(threshold: threshold, border: border)
            try encodeKernel(cb, thresholdPipeline, width: workW, height: workH) { enc in
                enc.setTexture(difference, index: 0)
                enc.setTexture(mask, index: 1)
                enc.setBytes(&params, length: MemoryLayout<ThresholdParams>.stride, index: 0)
            }
            MPSImageAreaMin(device: device, kernelWidth: 3, kernelHeight: 3)
                .encode(commandBuffer: cb, sourceTexture: mask, destinationTexture: eroded)
            MPSImageAreaMax(device: device, kernelWidth: 9, kernelHeight: 9)
                .encode(commandBuffer: cb, sourceTexture: eroded, destinationTexture: dilated)
        }

        if let debugSink {
            debugSink("difference", readFloats(difference), workW, workH)
            debugSink("residual", field.residuals.map { simd_length($0) }, Int(field.dims.x), Int(field.dims.y))
        }

        // 5. 連結成分 → 間違い
        let blobs = extractBlobs(mask: readBytes(dilated), difference: readFloats(difference),
                                 width: workW, height: workH, threshold: threshold, border: Int(border),
                                 maxCount: options.maxDifferences)

        let maxScale = CGFloat(max(pixelScale.x, pixelScale.y))
        let minRadius = Double(min(workW, workH)) * 0.03
        let differences = blobs.enumerated().map { index, blob -> PuzzleDifference in
            let center = SIMD2<Float>(Float(blob.minX + blob.maxX + 1) / 2, Float(blob.minY + blob.maxY + 1) / 2)
            let halfExtent = Double(max(blob.maxX - blob.minX + 1, blob.maxY - blob.minY + 1)) / 2
            let radius = CGFloat(max(minRadius, halfExtent * 1.25 + 4)) * maxScale
            let pointA = originA + center * pixelScale
            let pointB = homography.apply(SIMD2<Double>(originA + (center + field.sample(at: center)) * pixelScale))
            return PuzzleDifference(id: index,
                                    centerA: CGPoint(x: CGFloat(pointA.x), y: CGFloat(pointA.y)),
                                    centerB: CGPoint(x: CGFloat(pointB.x), y: CGFloat(pointB.y)),
                                    radius: radius,
                                    score: blob.score)
        }

        return DetectionResult(regionA: rectA, regionB: rectB, differences: differences,
                               elapsed: Date().timeIntervalSince(start))
    }

    // MARK: - 1. 領域確定

    /// 画像を自分自身とずらして重ね、最もよく一致するずれ量 = 2 つの絵の間隔とみなす。
    /// そこからタイル照合で A → B の射影変換を求め、それで一致する部分の範囲を A、写した先を B とする。
    private func locateRegions(in source: MTLTexture) throws -> (a: CGRect, b: CGRect, homography: Homography) {
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

        // A と B が重ならないように制限（B の手前の辺より内側に収める）
        let cornersB = [(x0, y0), (x1 + 1, y0), (x0, y1 + 1), (x1 + 1, y1 + 1)]
            .map { lowHomography.apply(SIMD2(Double($0.0), Double($0.1))) }
        if abs(dx) >= abs(dy) {
            x1 = min(x1, Int(cornersB.map(\.x).min()!.rounded(.down)) - 1)
        } else {
            y1 = min(y1, Int(cornersB.map(\.y).min()!.rounded(.down)) - 1)
        }
        x0 = max(0, x0 - 1); y0 = max(0, y0 - 1)
        x1 = min(lw - 1, x1 + 1); y1 = min(lh - 1, y1 + 1)
        guard x1 > x0, y1 > y0 else { throw DetectionError.regionsNotFound }

        let factor = SIMD2(Double(source.width) / Double(lw), Double(source.height) / Double(lh))
        let homography = lowHomography.scaled(by: factor)
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let rectA = CGRect(x: Double(x0) * factor.x, y: Double(y0) * factor.y,
                           width: Double(x1 - x0 + 1) * factor.x, height: Double(y1 - y0 + 1) * factor.y)
            .intersection(bounds)
            .integral
        guard !rectA.isNull, rectA.width >= 48, rectA.height >= 48 else { throw DetectionError.regionsNotFound }

        let projected = [CGPoint(x: rectA.minX, y: rectA.minY), CGPoint(x: rectA.maxX, y: rectA.minY),
                         CGPoint(x: rectA.minX, y: rectA.maxY), CGPoint(x: rectA.maxX, y: rectA.maxY)]
            .map { homography.apply(SIMD2(Double($0.x), Double($0.y))) }
        let rectB = CGRect(x: projected.map(\.x).min()!, y: projected.map(\.y).min()!,
                           width: projected.map(\.x).max()! - projected.map(\.x).min()!,
                           height: projected.map(\.y).max()! - projected.map(\.y).min()!)
            .intersection(bounds)
        return (rectA, rectB, homography)
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
                               height: Int) throws -> DisplacementField {
        let gx = max(1, Int((Double(width) / tileTargetSize).rounded()))
        let gy = max(1, Int((Double(height) / tileTargetSize).rounded()))
        let tileW = Float(width) / Float(gx), tileH = Float(height) / Float(gy)

        var tiles: [SIMD4<Int32>] = []
        for j in 0..<gy {
            for i in 0..<gx {
                let cx = (Float(i) + 0.5) * tileW, cy = (Float(j) + 0.5) * tileH
                tiles.append(SIMD4(Int32(cx - tileW), Int32(cy - tileH), Int32(tileW * 2), Int32(tileH * 2)))
            }
        }
        let r = localSearchRadius, side = 2 * r + 1
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

    // MARK: - 3. 連結成分

    private func extractBlobs(mask: [UInt8], difference: [Float], width: Int, height: Int,
                              threshold: Float, border: Int, maxCount: Int) -> [Blob] {
        let band = border + 8
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
                if d >= threshold {
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

        // 近接した断片を 1 つの間違いにまとめる
        let gap = Int(Double(max(width, height)) * 0.02)
        var merged = true
        while merged {
            merged = false
            search: for i in blobs.indices {
                for j in (i + 1)..<blobs.count where blobs[i].isNear(blobs[j], gap: gap) {
                    blobs[i].absorb(blobs[j])
                    blobs.remove(at: j)
                    merged = true
                    break search
                }
            }
        }

        let minCore = max(12, Int(Double(width * height) * 0.00003))
        let sorted = blobs.filter { $0.core >= minCore }.sorted { $0.score > $1.score }
        guard let top = sorted.first?.score else { return [] }
        return Array(sorted.filter { $0.score >= top * 0.03 }.prefix(maxCount))
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

    private func encodeWarp(_ cb: MTLCommandBuffer, source: MTLTexture, destination: MTLTexture,
                            origin: SIMD2<Float>, scale: SIMD2<Float>, sourceSize: SIMD2<Float>,
                            homography: Homography, field: DisplacementField) throws {
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
