//
//  DetectionTypes.swift
//  MikkeAnswer
//

import CoreGraphics
import Foundation

nonisolated struct DetectionOptions: Sendable {
    /// 0（控えめ）〜 1（敏感）
    var sensitivity: Float = 0.5
    var maxDifferences: Int = 15
}

/// 検出した 1 つの間違い。座標はすべて入力画像のピクセル座標（左上原点）。
nonisolated struct PuzzleDifference: Sendable, Identifiable {
    let id: Int
    let centerA: CGPoint
    let centerB: CGPoint
    let radius: CGFloat
    let score: Float
}

nonisolated struct DetectionResult: Sendable {
    /// 2 つの絵の範囲（入力画像のピクセル座標）
    let regionA: CGRect
    let regionB: CGRect
    let differences: [PuzzleDifference]
    let elapsed: TimeInterval
}

nonisolated enum DetectionError: LocalizedError {
    case metalUnavailable
    case resourceCreationFailed
    case commandFailed
    case regionsNotFound

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "この端末では Metal を利用できません。"
        case .resourceCreationFailed:
            return "画像処理用のメモリを確保できませんでした。"
        case .commandFailed:
            return "GPU での画像処理に失敗しました。"
        case .regionsNotFound:
            return "2 つの絵を見つけられませんでした。2 枚の絵全体が写るように撮影してください。"
        }
    }
}
