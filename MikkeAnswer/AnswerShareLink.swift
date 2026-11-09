//
//  AnswerShareLink.swift
//  MikkeAnswer
//

import SwiftUI

/// 答えの画像を、ひとことと App Store へのリンクを添えて共有するボタン
struct AnswerShareLink: View {
    let answer: UIImage

    var body: some View {
        let image = Image(uiImage: answer)
        ShareLink(item: image,
                  message: Text(verbatim: String(localized: "間違い探し全部わかった？") + "\n" + Self.appStoreURL.absoluteString),
                  preview: SharePreview("みっけアンサー", image: image))
    }

    /// 日本語は日本のストア、それ以外は受け取った人の国のストアが開くよう地域を付けないリンクにする
    private static var appStoreURL: URL {
        let isJapanese = Locale.current.language.languageCode == .japanese
        return URL(string: isJapanese
                   ? "https://apps.apple.com/jp/app/id6825153683"
                   : "https://apps.apple.com/app/id6825153683")!
    }
}
