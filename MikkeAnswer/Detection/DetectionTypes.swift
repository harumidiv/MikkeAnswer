//
//  DetectionTypes.swift
//  MikkeAnswer
//

import CoreGraphics
import Foundation
import simd

nonisolated struct DetectionOptions: Sendable {
    /// 0（控えめ）〜 1（敏感）
    var sensitivity: Float = 0.5
    var maxDifferences: Int = 15
}

/// 検出した 1 つの間違い
nonisolated struct PuzzleDifference: Sendable, Identifiable {
    let id: Int
    /// 位置合わせ済みの 2 枚の絵（alignedA / alignedB 共通）上の中心と半径（px）
    let center: CGPoint
    let radius: CGFloat
    /// 入力画像上での A 側の中心（検証用）
    let sourceCenterA: CGPoint
    let score: Float
}

nonisolated struct DetectionResult: Sendable {
    /// 範囲 A を切り出した絵
    let alignedA: CGImage
    /// 範囲 B を A にぴったり重なるようワープした絵（alignedA と同じサイズ）
    let alignedB: CGImage
    /// 傾きを補正した入力画像
    let straightenedImage: CGImage
    /// 補正した傾き（度、時計回りが正）
    let rotationDegrees: Double
    /// 2 つの絵の範囲（straightenedImage 上の四隅：左上・右上・右下・左下）
    let regionA: [CGPoint]
    let regionB: [CGPoint]
    let differences: [PuzzleDifference]
    let elapsed: TimeInterval
}

/// ユーザーが 2 つの絵を重ね合わせるための、同じ大きさに切り出した 2 枚
nonisolated struct ManualAlignment: Sendable {
    /// 範囲を指定した画像
    let image: CGImage
    /// 指定した範囲（image 上の四隅：左上・右上・右下・左下）
    let quadA: [CGPoint]
    let quadB: [CGPoint]
    /// 範囲 A / B を遠近補正して切り出した絵（同じサイズ。B は Vision で A に近づけてある）
    let pictureA: CGImage
    let pictureB: CGImage
    /// 切り出した絵の座標 → image の座標への射影変換
    let mapA: simd_double3x3
    let mapB: simd_double3x3
}

nonisolated enum DetectionError: LocalizedError {
    case metalUnavailable
    case resourceCreationFailed
    case commandFailed
    case regionsNotFound
    case overlapTooSmall

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "この端末では Metal を利用できません。"
        case .resourceCreationFailed:
            return "画像処理用のメモリを確保できませんでした。"
        case .commandFailed:
            return "GPU での画像処理に失敗しました。"
        case .regionsNotFound:
            return "2 つの絵を見つけられませんでした。2 枚の絵全体が写るように撮影するか、「範囲・重ね方を調整」で絵の範囲を指定してください。"
        case .overlapTooSmall:
            return "2 つの絵の重なりが小さすぎます。「範囲・重ね方を調整」から重ね直してください。"
        }
    }
}
