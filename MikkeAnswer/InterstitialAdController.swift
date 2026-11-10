//
//  InterstitialAdController.swift
//  MikkeAnswer
//

import GoogleMobileAds

/// 間違いを表示する前に挟む AdMob のインタースティシャル広告。次に表示する分を先に読み込んでおく
final class InterstitialAdController: NSObject, FullScreenContentDelegate {
    #if DEBUG
    /// 開発中は Google のテスト用広告を出す（自分で本番の広告を表示・タップすると AdMob のポリシー違反になるため）
    private static let adUnitID = "ca-app-pub-3940256099942544/4411468910"
    #else
    private static let adUnitID = "ca-app-pub-8522231452310619/4166298999"
    #endif

    private var ad: InterstitialAd?
    private var isLoading = false

    /// 次に表示する広告を読み込む（読み込み済み・読み込み中なら何もしない）
    func load() {
        guard ad == nil, !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let ad = try await InterstitialAd.load(with: Self.adUnitID, request: Request())
                ad.fullScreenContentDelegate = self
                self.ad = ad
            } catch {
                // 読み込めなかったときは広告を挟まずに進める（次に表示しようとしたときに読み込み直す）
                self.ad = nil
            }
        }
    }

    /// 読み込み済みの広告があれば表示する。なければ何もせず、次の分を読み込んでおく
    func present() {
        guard let ad else {
            load()
            return
        }
        self.ad = nil
        ad.present(from: nil)
    }

    func adDidDismissFullScreenContent(_ ad: any FullScreenPresentingAd) {
        load()
    }

    func ad(_ ad: any FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: any Error) {
        load()
    }
}
