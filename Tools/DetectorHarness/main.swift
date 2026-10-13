//
//  main.swift
//  DetectorHarness
//
//  DifferenceDetector を macOS 上で検証するためのコマンドラインツール。
//  使い方: run.sh [画像ファイル]   （省略時は合成した間違い探し画像で正解と照合する）
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Shape {
    enum Kind { case circle, rect }
    var kind: Kind
    var rect: CGRect
    var color: (CGFloat, CGFloat, CGFloat)
}

func drawPicture(_ ctx: CGContext, shapes: [Shape], size: CGSize) {
    ctx.setFillColor(red: 0.95, green: 0.93, blue: 0.85, alpha: 1)
    ctx.fill(CGRect(origin: .zero, size: size))
    for s in shapes {
        ctx.setFillColor(red: s.color.0, green: s.color.1, blue: s.color.2, alpha: 1)
        ctx.setStrokeColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        ctx.setLineWidth(3)
        switch s.kind {
        case .circle: ctx.fillEllipse(in: s.rect); ctx.strokeEllipse(in: s.rect)
        case .rect: ctx.fill(s.rect); ctx.stroke(s.rect)
        }
    }
    ctx.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
    ctx.setLineWidth(6)
    ctx.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3))
}

func makePictureImage(shapes: [Shape], size: CGSize) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // 左上原点で描く
    ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
    drawPicture(ctx, shapes: shapes, size: size)
    return ctx.makeImage()!
}

/// 2 枚の絵を並べた紙面を、照明ムラ・ノイズ・わずかな回転/拡大付きで生成する
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {   // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func makeSyntheticPuzzle(vertical: Bool, seed: UInt64) -> (CGImage, [CGPoint]) {
    var rng = SeededGenerator(state: seed)
    let pic = CGSize(width: 600, height: 450)
    var shapes: [Shape] = []
    for _ in 0..<45 {
        let w = CGFloat.random(in: 20...110, using: &rng), h = CGFloat.random(in: 20...110, using: &rng)
        shapes.append(Shape(kind: Bool.random(using: &rng) ? .circle : .rect,
                            rect: CGRect(x: .random(in: 10...(pic.width - w - 10), using: &rng),
                                         y: .random(in: 10...(pic.height - h - 10), using: &rng),
                                         width: w, height: h),
                            color: (.random(in: 0...1, using: &rng), .random(in: 0...1, using: &rng),
                                    .random(in: 0...1, using: &rng))))
    }
    var modified = shapes
    var truth: [CGPoint] = []   // 絵 A 内の正解中心
    // 色替え
    for i in [38, 41] {   // 前面に近い図形（他に隠れにくい）
        modified[i].color = (1 - shapes[i].color.0, 1 - shapes[i].color.1, shapes[i].color.2)
        truth.append(CGPoint(x: shapes[i].rect.midX, y: shapes[i].rect.midY))
    }
    // 追加
    let added = Shape(kind: .circle, rect: CGRect(x: 420, y: 60, width: 40, height: 40), color: (0.1, 0.6, 0.2))
    modified.append(added); truth.append(CGPoint(x: added.rect.midX, y: added.rect.midY))
    // 消去（最前面の図形）
    let removed = modified.remove(at: 44)
    truth.append(CGPoint(x: removed.rect.midX, y: removed.rect.midY))
    // 小さな追加
    let small = Shape(kind: .rect, rect: CGRect(x: 100, y: 380, width: 22, height: 22), color: (0.9, 0.1, 0.9))
    modified.append(small); truth.append(CGPoint(x: small.rect.midX, y: small.rect.midY))

    let a = makePictureImage(shapes: shapes, size: pic)
    let b = makePictureImage(shapes: modified, size: pic)

    let page = vertical ? CGSize(width: 800, height: 1150) : CGSize(width: 1450, height: 700)
    let ctx = CGContext(data: nil, width: Int(page.width), height: Int(page.height), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: page.height); ctx.scaleBy(x: 1, y: -1)
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(CGRect(origin: .zero, size: page))
    ctx.setFillColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)
    ctx.fill(CGRect(x: 80, y: 20, width: 400, height: 30))   // タイトル風の帯

    let originA = vertical ? CGPoint(x: 100, y: 70) : CGPoint(x: 60, y: 120)
    let originB = vertical ? CGPoint(x: 95, y: 620) : CGPoint(x: 760, y: 128)
    func place(_ image: CGImage, at origin: CGPoint, rotation: CGFloat, scale: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: origin.x + pic.width / 2, y: origin.y + pic.height / 2)
        ctx.rotate(by: rotation)
        ctx.scaleBy(x: scale, y: -scale)   // CGImage は下原点なので反転して描く
        ctx.draw(image, in: CGRect(x: -pic.width / 2, y: -pic.height / 2, width: pic.width, height: pic.height))
        ctx.restoreGState()
    }
    place(a, at: originA, rotation: 0, scale: 1)
    place(b, at: originB, rotation: 0.6 * .pi / 180, scale: 1.015)

    // 照明ムラ（右下ほど暗い）
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [CGColor(red: 0, green: 0, blue: 0, alpha: 0),
                                       CGColor(red: 0, green: 0, blue: 0, alpha: 0.25)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: page.width, y: page.height), options: [])

    var image = ctx.makeImage()!
    image = addNoise(image)
    return (image, truth.map { CGPoint(x: $0.x + originA.x, y: $0.y + originA.y) })
}

func addNoise(_ image: CGImage) -> CGImage {
    let w = image.width, h = image.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var noiseRNG = SeededGenerator(state: 42)
    for i in 0..<(w * h * 4) where i % 4 != 3 {
        px[i] = UInt8(clamping: Int(px[i]) + Int.random(in: -12...12, using: &noiseRNG))
    }
    return ctx.makeImage()!
}

func loadImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceCreateThumbnailWithTransform: true,
                                 kCGImageSourceThumbnailMaxPixelSize: 2048]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}

func savePNG(_ image: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
let outputDir = URL(fileURLWithPath: args[1])
let detector = try DifferenceDetector(metallibURL: outputDir.appendingPathComponent("default.metallib"))
var debugName = ""
detector.debugSink = { name, values, width, height in
    guard !debugName.isEmpty else { return }
    guard name == "difference" else {
        print("   [\(name)] \(width)x\(height): " + values.map { String(format: "%.1f", $0) }.joined(separator: " "))
        return
    }
    let bytes = values.map { UInt8(clamping: Int(min(1, $0 * 2) * 255)) }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent)!
    savePNG(image, outputDir.appendingPathComponent("\(debugName)_\(name).png").path)
}
let sensitivity = Float(ProcessInfo.processInfo.environment["SENSITIVITY"] ?? "") ?? 0.5

/// - Returns: (正解のうち検出できた数, 誤検出数, 処理時間)
@discardableResult
func report(_ name: String, image: CGImage, truth: [CGPoint]?, verbose: Bool = true) throws -> (Int, Int, Double) {
    debugName = verbose ? name : ""
    _ = try detector.detect(in: image)   // ウォームアップ
    let result = try detector.detect(in: image, options: DetectionOptions(sensitivity: sensitivity))
    if verbose {
        print("== \(name): \(image.width)x\(image.height)  \(String(format: "%.1f", result.elapsed * 1000)) ms")
        print("   regionA=\(result.regionA) regionB=\(result.regionB)")
        for d in result.differences {
            print(String(format: "   diff #%d A=(%.0f,%.0f) B=(%.0f,%.0f) r=%.0f score=%.1f", d.id,
                         d.centerA.x, d.centerA.y, d.centerB.x, d.centerB.y, d.radius, d.score))
        }
    }
    var hits = 0, falsePositives = 0
    if let truth {
        // 円の中心が正解から 30px 以内、または円が正解点を含む（半径の 0.8 倍以内）なら一致
        func matches(_ d: PuzzleDifference, _ t: CGPoint) -> Bool {
            let distance = hypot(d.centerA.x - t.x, d.centerA.y - t.y)
            return distance < max(30, d.radius * 0.8)
        }
        hits = truth.filter { t in result.differences.contains { matches($0, t) } }.count
        falsePositives = result.differences.filter { d in !truth.contains { matches(d, $0) } }.count
        if verbose { print("   正解 \(hits)/\(truth.count) 検出, 誤検出 \(falsePositives)") }
    }
    if verbose, let annotated = ResultRenderer.render(source: image, result: result, showsRegions: true) {
        savePNG(annotated, outputDir.appendingPathComponent("\(name)_result.png").path)
    }
    return (hits, falsePositives, result.elapsed)
}

if args.count > 2 {
    for path in args.dropFirst(2) {
        guard let image = loadImage(path) else { print("読み込めません: \(path)"); continue }
        try report(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, image: image, truth: nil)
    }
} else {
    let trials = Int(ProcessInfo.processInfo.environment["TRIALS"] ?? "") ?? 10
    for vertical in [false, true] {
        let name = vertical ? "synthetic_vertical" : "synthetic_horizontal"
        var hits = 0, total = 0, falsePositives = 0, failures = 0, elapsed = 0.0
        let onlySeed = UInt64(ProcessInfo.processInfo.environment["SEED"] ?? "")
        for trial in 0..<trials {
            let seed = onlySeed ?? UInt64(trial + 1)
            let (image, truth) = makeSyntheticPuzzle(vertical: vertical, seed: seed)
            let verbose = onlySeed != nil
            if verbose { savePNG(image, outputDir.appendingPathComponent("\(name).png").path) }
            do {
                let r = try report(name, image: image, truth: truth, verbose: verbose)
                hits += r.0; falsePositives += r.1; elapsed += r.2
                if r.0 < truth.count || r.1 > 0 {
                    print("   seed \(seed): 正解 \(r.0)/\(truth.count) 誤検出 \(r.1)")
                }
            } catch {
                failures += 1
                print("   seed \(seed): \(error.localizedDescription)")
            }
            total += truth.count
            if onlySeed != nil { break }
        }
        print(String(format: "## %@: %d 試行  検出率 %d/%d  誤検出 %d  領域検出失敗 %d  平均 %.1f ms",
                     name, trials, hits, total, falsePositives, failures,
                     elapsed / Double(max(1, trials - failures)) * 1000))
    }
}
