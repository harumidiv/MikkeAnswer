//
//  Theme.swift
//  MikkeAnswer
//

import SwiftUI
import UIKit

/// アプリ全体の色。ライト・ダークで切り替わる
extension Color {
    /// 画面の地の色
    static let appGround = Color(light: 0xFFF8F1, dark: 0x1C1714)
    /// カードの色
    static let appCard = Color(light: 0xFFFFFF, dark: 0x2A221E)
    /// メインのボタンの色（白い文字が読める濃さにしている）
    static let appBrand = Color(light: 0xC2410C, dark: 0xC2410C)
    /// 淡いオレンジ（ステップの番号・控えめなボタンの地）
    static let appBrandSoft = Color(light: 0xFFE8D8, dark: 0x4A2A1A)
    /// 淡いオレンジの上に載せる文字の色
    static let appBrandText = Color(light: 0x9A3412, dark: 0xFDBA8C)
    /// 控えめなボタンの枠線
    static let appBrandLine = Color(light: 0xF3C9AE, dark: 0x6B3A22)
    /// 補足の文字の色
    static let appSubtext = Color(light: 0x6B5347, dark: 0xC9B3A6)
    /// 間違いの数など、答えを示す赤
    static let appAnswer = Color(light: 0xB91C1C, dark: 0xF87171)
    /// 1 つずつ見ているときの、今の間違いの⭕️の色（ResultRenderer の highlight と同じ）
    static let appHighlight = Color(red: 0.15, green: 0.39, blue: 0.92)

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Font {
    /// 見出し用の丸みのある書体
    static func appRounded(_ style: Font.TextStyle, weight: Font.Weight = .heavy) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}

/// 画面の下に置く、いちばん大事なボタン
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 12)
            .background(Color.appBrand.opacity(isEnabled ? 1 : 0.4), in: .rect(cornerRadius: 18))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// 白地にオレンジの枠の、控えめなボタン
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.bold())
            .foregroundStyle(Color.appBrandText)
            .frame(minWidth: 56, minHeight: 56)
            .padding(.horizontal, 4)
            .background(Color.appCard, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.appBrandLine, lineWidth: 1.5))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var appPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var appSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension View {
    /// 白いカードに載せる（角丸はカードだけ。中の絵の角は切らない）
    func appCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(Color.appCard, in: .rect(cornerRadius: 20))
    }
}

/// 撮る → 合わせる → 答え のどこにいるかを示す
struct StepIndicator: View {
    enum Step: Int, CaseIterable {
        case capture = 1, align, answer

        var title: LocalizedStringResource {
            switch self {
            case .capture: "撮る"
            case .align: "合わせる"
            case .answer: "答え"
            }
        }
    }

    let current: Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { step in
                Text("\(step.rawValue) \(Text(step.title))")
                    .font(.caption.bold())
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(foreground(step))
                    .background(background(step), in: .capsule)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("ステップ \(current.rawValue) / 3：\(Text(current.title))"))
    }

    private func foreground(_ step: Step) -> Color {
        if step == current { return .white }
        return step.rawValue < current.rawValue ? .appBrandText : .appSubtext
    }

    private func background(_ step: Step) -> Color {
        if step == current { return .appBrand }
        return step.rawValue < current.rawValue ? .appBrandSoft : Color.appSubtext.opacity(0.12)
    }
}
