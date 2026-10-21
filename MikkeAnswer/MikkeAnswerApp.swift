//
//  MikkeAnswerApp.swift
//  MikkeAnswer
//
//  Created by harumi.sagawa on 2026/10/13.
//

import AppTrackingTransparency
import GoogleMobileAds
import SwiftUI

@main
struct MikkeAnswerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// トラッキングの許可を確認し、広告 SDK を初期化し終えたか
    @State private var isAdReady = false
    /// ダイアログの表示中にアプリが非アクティブ → アクティブと切り替わっても、二重に確認しないようにする
    @State private var hasRequestedTracking = false

    var body: some Scene {
        WindowGroup {
            ContentView(showsAd: isAdReady)
        }
        // ATT のダイアログはアプリがアクティブな状態でないと表示されないため、起動直後ではなくアクティブになってから出す
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active, !hasRequestedTracking else { return }
            hasRequestedTracking = true
            Task {
                // 最初の広告リクエストに許可の結果を反映させるため、SDK の初期化はダイアログの後にする
                _ = await ATTrackingManager.requestTrackingAuthorization()
                await MobileAds.shared.start()
                isAdReady = true
            }
        }
    }
}
