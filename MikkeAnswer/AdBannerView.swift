//
//  AdBannerView.swift
//  MikkeAnswer
//

import GoogleMobileAds
import SwiftUI

/// 画面の下に置く AdMob のアンカー アダプティブ バナー（置いた場所の幅に合わせる）
struct AdBannerView: View {
    #if DEBUG
    /// 開発中は Google のテスト用広告を出す（自分で本番の広告を表示・タップすると AdMob のポリシー違反になるため）
    private static let adUnitID = "ca-app-pub-3940256099942544/2435281174"
    #else
    private static let adUnitID = "ca-app-pub-8522231452310619/8261173866"
    #endif

    @State private var width: CGFloat = 0

    var body: some View {
        let adSize = currentOrientationAnchoredAdaptiveBanner(width: width)
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: width > 0 ? adSize.size.height : 0)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay {
                if width > 0 {
                    BannerContainer(adSize: adSize, adUnitID: Self.adUnitID)
                        .frame(width: adSize.size.width, height: adSize.size.height)
                }
            }
    }
}

private struct BannerContainer: UIViewRepresentable {
    let adSize: AdSize
    let adUnitID: String

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: adSize)
        banner.adUnitID = adUnitID
        banner.load(Request())
        return banner
    }

    /// バナー自身の大きさではなく、指定した広告サイズで配置させる
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: BannerView, context: Context) -> CGSize? {
        adSize.size
    }

    func updateUIView(_ banner: BannerView, context: Context) {
        // 幅が変わったとき（iPad の回転など）はサイズを合わせて読み込み直す
        guard banner.adSize.size != adSize.size else { return }
        banner.adSize = adSize
        banner.load(Request())
    }
}
