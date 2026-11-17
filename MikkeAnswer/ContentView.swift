//
//  ContentView.swift
//  MikkeAnswer
//
//  Created by harumi.sagawa on 2026/10/13.
//

import PhotosUI
import SwiftData
import SwiftUI

/// 初期画面。撮影するか写真を選ぶと結果画面に進み、戻るとまたここから選び直せる
struct ContentView: View {
    /// 広告を表示するか（トラッキングの許可を確認し終えてから表示する）
    var showsAd = false

    @State private var model = PuzzleSolverModel()
    @State private var photoItem: PhotosPickerItem?
    @State private var isShowingCamera = false
    @State private var isShowingPhotoPicker = false
    @State private var isShowingResult = false
    @State private var isShowingSavedList = false
    /// 保存した間違い探しがあるか調べるだけなので 1 件だけ取得する
    @Query(Self.anySavedPuzzle) private var savedPuzzles: [SavedPuzzle]

    private static var anySavedPuzzle: FetchDescriptor<SavedPuzzle> {
        var descriptor = FetchDescriptor<SavedPuzzle>()
        descriptor.fetchLimit = 1
        return descriptor
    }
    /// 最後に写真を読み込んだ方法（範囲調整画面から撮り直す・選び直すときに使う）
    @State private var lastSource: InputSource?
    /// 間違いを表示する前に挟むインタースティシャル広告
    @State private var interstitialAd = InterstitialAdController()
    /// 範囲調整画面を閉じたあとに開き直す入力
    @State private var pendingRetake: InputSource?
    /// 選んだ写真を読み込めなかったか（iCloud から取得できないときなど）
    @State private var isShowingLoadError = false

    private enum InputSource {
        case camera, library
    }

    var body: some View {
        // 広告は画面の中身と重ならないよう、NavigationStack の下に別の領域として並べる
        VStack(spacing: 0) {
            navigationContent
            if showsAd {
                AdBannerView()
            }
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { image in
                lastSource = .camera
                start(with: image)
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $isShowingPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    lastSource = .library
                    start(with: image)
                } else {
                    // 何も起きないように見えないよう、読み込めなかったことを伝える
                    isShowingLoadError = true
                }
                photoItem = nil
            }
        }
        .alert("画像を読み込めませんでした。", isPresented: $isShowingLoadError) {
            Button("OK") {}
        }
        .onChange(of: isShowingResult) { _, isShowing in
            if !isShowing { model.reset() }
        }
        // トラッキングの確認と SDK の初期化が終わってから、最初の広告を読み込んでおく
        .onChange(of: showsAd, initial: true) { _, showsAd in
            if showsAd { interstitialAd.load() }
        }
    }

    /// 重ね方の画面で「間違いを探す」を押して閉じたあと、間違いを表示する前に広告を挟む（裏で解析は進む）
    private func presentInterstitialAd() {
        guard showsAd else { return }
        interstitialAd.present()
    }

    private var navigationContent: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 小さい画面や文字を大きくしたときは、案内の部分だけスクロールさせる
                ScrollView {
                    homeGuide
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }
                .scrollBounceBehavior(.basedOnSize)

                inputButtons
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .background(Color.appGround.ignoresSafeArea())
            .navigationTitle("みっけアンサー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // アイコンと見出しで名前がわかるので、上のバーにはタイトルを出さない
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1)
                }
                // 保存した履歴があるときだけ出す
                if !savedPuzzles.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存した間違い探し", systemImage: "clock.arrow.circlepath") {
                            isShowingSavedList = true
                        }
                    }
                }
            }
            // 一覧で全件削除してボタンが消えても、一覧の画面は閉じないようボタンとは切り離して開く
            .navigationDestination(isPresented: $isShowingSavedList) {
                SavedPuzzleListView()
            }
            .navigationDestination(isPresented: $isShowingResult) {
                ResultView(model: model,
                           retakeOption: retakeOption(for:),
                           onRegionEditorDismiss: openPendingRetake,
                           onFindDifferences: presentInterstitialAd)
            }
        }
    }

    private func start(with image: UIImage) {
        model.load(image)
        isShowingResult = true
    }

    /// 範囲調整画面が閉じきってから、初期画面に戻ってカメラ・写真の選択を開き直す（閉じる途中に別の画面は出せないため）
    /// - Returns: 撮り直す・選び直すために結果画面を閉じたか
    private func openPendingRetake() -> Bool {
        guard let source = pendingRetake else { return false }
        pendingRetake = nil
        isShowingResult = false
        switch source {
        case .camera: isShowingCamera = true
        case .library: isShowingPhotoPicker = true
        }
        return true
    }

    /// 写真を読み込んだ直後の範囲調整画面にだけ、同じ方法で撮り直す・選び直すボタンを出す
    private func retakeOption(for request: RegionEditorRequest) -> RetakeOption? {
        guard request.isNewPhoto, let source = lastSource else { return nil }
        switch source {
        case .camera:
            let title: LocalizedStringResource = "撮り直す"
            return (title, "camera", { pendingRetake = .camera })
        case .library:
            let title: LocalizedStringResource = "写真を選び直す"
            return (title, "photo.on.rectangle", { pendingRetake = .library })
        }
    }

    /// アイコン・見出しと、撮る → 合わせる → 答え の 3 ステップの説明
    private var homeGuide: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image("AppIconImage")
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(.rect(cornerRadius: 26))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
                    .accessibilityHidden(true)
                Text("どこが違うか\nいっしょに見つけよう")
                    .font(.appRounded(.title2))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
            }

            VStack(spacing: 10) {
                HomeStepRow(number: 1, isFirst: true, title: "撮る",
                            detail: "2 つの絵が両方写るように撮影してください")
                HomeStepRow(number: 2, isFirst: false, title: "合わせる",
                            detail: "左右の絵の 4 すみを指で合わせます")
                HomeStepRow(number: 3, isFirst: false, title: "答えを見る",
                            detail: "間違いを 1 つずつ見比べられます")
            }
        }
    }

    private var inputButtons: some View {
        VStack(spacing: 4) {
            Button {
                isShowingCamera = true
            } label: {
                Label("撮影してはじめる", systemImage: "camera")
            }
            .buttonStyle(.appPrimary)
            .disabled(!CameraPicker.isAvailable)

            Button {
                isShowingPhotoPicker = true
            } label: {
                Label("写真から選ぶ", systemImage: "photo.on.rectangle")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.appBrandText)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

/// ホーム画面の、1 ステップぶんの説明
private struct HomeStepRow: View {
    let number: Int
    /// 最初のステップだけ番号を濃い色にする（ここから始める、と伝える）
    let isFirst: Bool
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    var body: some View {
        HStack(spacing: 14) {
            Text(verbatim: "\(number)")
                .font(.appRounded(.headline))
                .foregroundStyle(isFirst ? .white : Color.appBrandText)
                .frame(width: 40, height: 40)
                .background(isFirst ? Color.appBrand : Color.appBrandSoft, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.appSubtext)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.appCard, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

/// 範囲調整画面の、撮り直す・選び直すボタン
typealias RetakeOption = (title: LocalizedStringResource, systemImage: String, action: () -> Void)

/// 結果画面（間違いを 1 つずつ見比べる・全体を見る・感度などの調整）
private struct ResultView: View {
    @Bindable var model: PuzzleSolverModel
    let retakeOption: (RegionEditorRequest) -> RetakeOption?
    /// 範囲調整画面が閉じきったとき（撮り直す・選び直すために結果画面を閉じたら true を返す）
    let onRegionEditorDismiss: () -> Bool
    /// 「間違いを探す」で範囲調整画面が閉じきったとき
    let onFindDifferences: () -> Void

    private enum DisplayMode: CaseIterable, Identifiable {
        /// 間違いを 1 つずつ、左右の絵で拡大して見比べる
        case oneByOne
        /// 答えの画像全体を見る
        case all
        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .oneByOne: "1 つずつ"
            case .all: "全部"
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var displayMode = DisplayMode.oneByOne
    /// 1 つずつ見るときに表示している間違い（thumbnails の添字）
    @State private var selectedIndex = 0
    @State private var isShowingSettings = false
    @State private var isConfirmingLeave = false
    /// 「間違いを探す」で範囲調整画面を閉じたか（閉じきってから広告を表示する）
    @State private var didFindDifferences = false
    /// 結果の左右の絵を交互に表示する（間違いがちらついて見える）
    @State private var isBlinking = false
    /// 点滅中に左の絵を表示しているか
    @State private var showsAInBlink = false
    /// 答えを保存できなかったか
    @State private var isShowingSaveError = false
    /// 感度のスライダーを指で動かしている最中か（指を離すまで解析し直さない）
    @State private var isEditingSensitivity = false
    /// 見比べる部分の幅（切り抜きの高さを決めるのに使う）
    @State private var pagerWidth: CGFloat = 0

    private let blinkInterval: Duration = .milliseconds(500)

    /// 点滅できるのは、答えの画像を表示しているときだけ
    private var canBlink: Bool {
        model.answerImageA != nil && !model.showsRegions
    }

    private var blinksNow: Bool {
        isBlinking && canBlink
    }

    /// 戻ると結果は消えるので、保存していない答えがあるときは確認する
    private var needsLeaveConfirmation: Bool {
        model.answerImageB != nil && !model.isAnswerSaved
    }

    /// 感度を変えて間違いの数が減っても、範囲外を指さないようにする
    private var currentIndex: Int {
        min(selectedIndex, max(model.thumbnails.count - 1, 0))
    }

    var body: some View {
        Group {
            // 写真を読み込んだ直後は、範囲を調整し終えるまで結果を出さない（結果が先に見えて順番が逆にならないように）
            if model.isAwaitingFirstRegionEdit {
                ProgressView("解析中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultContent
            }
        }
        .background(Color.appGround.ignoresSafeArea())
        .task(id: blinksNow) {
            showsAInBlink = false
            guard blinksNow else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: blinkInterval)
                showsAInBlink.toggle()
            }
        }
        // 解析し直すと間違いが変わるので、最初の間違いから見直す
        .onChange(of: model.thumbnails.count) { selectedIndex = 0 }
        // スワイプで見ている間違いが変わったら、その⭕️だけ色を変えた答えを用意する
        .onChange(of: highlightedDifferenceIndex, initial: true) { _, index in
            model.highlight(differenceIndex: index)
        }
        .navigationBarTitleDisplayMode(.inline)
        // 標準の戻るボタン・スワイプでは確認できないため、独自の戻るボタンにする
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("戻る", systemImage: "chevron.backward") {
                    if needsLeaveConfirmation {
                        isConfirmingLeave = true
                    } else {
                        dismiss()
                    }
                }
            }
            if let answer = model.answerImageB, model.phase != .processing, !model.isAwaitingFirstRegionEdit {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(model.isAnswerSaved ? "保存済み" : "保存",
                           systemImage: model.isAnswerSaved ? "checkmark" : "tray.and.arrow.down") {
                        saveAnswer()
                    }
                    .disabled(model.isAnswerSaved)
                    // 答えの画像を共有する（共有シートから写真への保存もできる）
                    AnswerShareLink(answer: answer)
                }
            }
        }
        .fullScreenCover(item: $model.regionEditor, onDismiss: regionEditorDidDismiss) { request in
            RegionEditorView(request: request,
                             prepare: { quadA, quadB in
                                 try await model.prepareAlignment(image: request.image, quadA: quadA, quadB: quadB)
                             },
                             onFinish: { alignment, overlay in
                                 didFindDifferences = true
                                 model.applyOverlay(alignment: alignment, overlay: overlay)
                             },
                             retake: retakeOption(request))
            .presentationBackground(Color.appGround)
        }
        .sheet(isPresented: $isShowingSettings) {
            settingsSheet
                .presentationDetents([.medium])
        }
        .alert("保存せずに戻りますか？", isPresented: $isConfirmingLeave) {
            Button("保存して戻る") {
                // 保存できなかったときは、結果が消えないよう戻らずにエラーを伝える
                if saveAnswer() { dismiss() }
            }
            Button("保存せずに戻る", role: .destructive) { dismiss() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("保存していない結果は消えます。")
        }
        .alert("保存できませんでした", isPresented: $isShowingSaveError) {
            Button("OK") {}
        } message: {
            Text("時間をおいて、もう一度お試しください。")
        }
    }

    private var resultContent: some View {
        VStack(spacing: 12) {
            StepIndicator(current: .answer)
            switch model.phase {
            case .idle:
                Spacer()
            case .processing:
                ProgressView("解析中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                settingsButton
            case .finished:
                if model.thumbnails.isEmpty {
                    if model.result?.differences.isEmpty == true {
                        Text("間違いが見つかりませんでした。感度を上げてみてください。")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                    }
                    overviewImage
                    settingsButton
                } else {
                    header
                    if displayMode == .oneByOne {
                        comparisonPager
                        overviewImage
                    } else {
                        overviewImage
                        differenceList
                    }
                }
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 「間違い 4 / 15」と、1 つずつ・全部の切り替え
    private var header: some View {
        HStack {
            Group {
                if displayMode == .oneByOne {
                    Text("間違い \(Text(verbatim: "\(currentIndex + 1)").foregroundStyle(Color.appHighlight)) / \(model.thumbnails.count)")
                } else {
                    Text("間違いを \(model.thumbnails.count) 箇所 見つけました")
                }
            }
            .font(.appRounded(.title3))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            Picker("表示", selection: $displayMode) {
                ForEach(DisplayMode.allCases) { Text($0.title) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.bold())
                    .foregroundStyle(Color.appBrandText)
                    .frame(width: 44, height: 44)
                    .background(Color.appCard, in: .circle)
                    .overlay(Circle().stroke(Color.appBrandLine, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(model.phase == .processing)
            .accessibilityLabel("感度・範囲の調整")
        }
    }

    /// 左右にスワイプして、間違いを 1 つずつ見比べる
    private var comparisonPager: some View {
        TabView(selection: $selectedIndex) {
            ForEach(Array(model.thumbnails.enumerated()), id: \.element.id) { index, thumbnail in
                comparison(thumbnail)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(maxWidth: 560)
        .frame(height: pagerHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pagerWidth = $0 }
        // VoiceOver では上下スワイプで前後の間違いに移れるようにする
        .accessibilityElement(children: .combine)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: selectedIndex = min(currentIndex + 1, model.thumbnails.count - 1)
            case .decrement: selectedIndex = max(currentIndex - 1, 0)
            @unknown default: break
            }
        }
    }

    /// 切り抜き 2 枚を横に並べたときの高さ（切り抜きの縦横比と、下の「左の絵」などの文字の分）
    private var pagerHeight: CGFloat {
        guard let first = model.thumbnails.first, first.imageA.size.width > 0, pagerWidth > 0 else { return 200 }
        let panelWidth = (pagerWidth - 10) / 2
        return panelWidth * first.imageA.size.height / first.imageA.size.width + 28
    }

    /// 1 箇所の間違いを、左右の絵で大きく見比べる（間違いが角にあることもあるので、絵の角は丸めない）
    private func comparison(_ thumbnail: DifferenceThumbnail) -> some View {
        HStack(alignment: .top, spacing: 10) {
            comparisonPanel("左の絵", image: thumbnail.imageA, marker: nil, thumbnail: thumbnail)
            comparisonPanel("右の絵", image: thumbnail.imageB, marker: thumbnail.markerCenterB, thumbnail: thumbnail)
        }
        .frame(maxWidth: 560)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("間違い \(thumbnail.number) の左の絵と右の絵"))
    }

    private func comparisonPanel(_ title: LocalizedStringResource, image: UIImage, marker: CGPoint?,
                                 thumbnail: DifferenceThumbnail) -> some View {
        VStack(spacing: 6) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .overlay {
                    if let marker {
                        // 全体の画像で色を変えた⭕️と対応がわかるよう、同じ色にする
                        MarkerCircle(center: marker, fraction: thumbnail.markerFraction, lineWidth: 4,
                                     color: .appHighlight)
                    }
                }
                // 円が切り抜きからはみ出して下の文字に重ならないよう、絵の範囲で切る（角は丸めない）
                .clipped()
                .frame(maxWidth: .infinity)
                .background(Color.appCard)
                .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(Color.appSubtext)
        }
    }

    /// 1 つずつ見ているときは、今の間違い（result.differences の添字）の⭕️だけ色を変える
    private var highlightedDifferenceIndex: Int? {
        guard displayMode == .oneByOne, !model.showsRegions, model.thumbnails.indices.contains(currentIndex) else {
            return nil
        }
        return model.thumbnails[currentIndex].number - 1
    }

    /// 全体の画像に出す絵（色を変えた答えが用意できるまでは、すべて赤の答えを出す）
    private var overviewSource: (b: UIImage, a: UIImage?)? {
        if let index = highlightedDifferenceIndex, let highlighted = model.highlightedAnswer,
           highlighted.differenceIndex == index {
            return (highlighted.imageB, highlighted.imageA)
        }
        return model.displayImage.map { ($0, model.answerImageA) }
    }

    /// 答えの画像全体（拡大・移動できる。点滅中は左右の絵を交互に出す）
    @ViewBuilder
    private var overviewImage: some View {
        if let source = overviewSource {
            ZoomableImage(image: blinksNow && showsAInBlink ? source.a ?? source.b : source.b)
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                .clipped()
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 間違いが見つからなかったときなどに出す、感度・範囲の調整ボタン
    private var settingsButton: some View {
        Button {
            isShowingSettings = true
        } label: {
            Label("感度・範囲の調整", systemImage: "slider.horizontal.3")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.appSecondary)
        .disabled(model.phase == .processing || !model.hasImage)
    }

    /// 見つけた間違いの一覧（押すと、その間違いを 1 つずつ見る表示にする）
    private var differenceList: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(Array(model.thumbnails.enumerated()), id: \.element.id) { index, thumbnail in
                    Button {
                        selectedIndex = index
                        displayMode = .oneByOne
                    } label: {
                        DifferenceCard(thumbnail: thumbnail)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .frame(height: 104)
    }

    /// 感度・点滅・範囲の確認と調整
    private var settingsSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("感度")
                        .font(.headline)
                    HStack {
                        Text("控えめ").font(.caption)
                        Slider(value: $model.sensitivity, in: 0...1) { editing in
                            isEditingSensitivity = editing
                            if !editing { model.analyze() }
                        }
                        .accessibilityLabel("感度")
                        Text("敏感").font(.caption)
                    }
                    // VoiceOver のスワイプなど、指でドラッグせずに値が変わったときも解析し直す
                    .onChange(of: model.sensitivity) {
                        if !isEditingSensitivity { model.analyze() }
                    }
                    .foregroundStyle(Color.appSubtext)
                }
                if canBlink {
                    Toggle("左右の絵を交互に点滅", isOn: $isBlinking)
                }
                Toggle("元の写真で絵の範囲を確認", isOn: $model.showsRegions)
                Button {
                    isShowingSettings = false
                    model.beginRegionEditing()
                } label: {
                    Label("範囲・重ね方を調整", systemImage: "crop")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.appSecondary)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .padding(20)
            .disabled(model.phase == .processing)
            .navigationTitle("調整")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { isShowingSettings = false }
                }
            }
        }
    }

    /// 範囲調整画面が閉じきったとき（閉じる途中には別の画面を出せないため、ここで広告や撮り直しの画面を出す）
    private func regionEditorDidDismiss() {
        // 撮り直す・選び直すときは結果を出さずに、そのまま初期画面へ戻る
        if onRegionEditorDismiss() { return }
        model.endFirstRegionEdit()
        if didFindDifferences {
            didFindDifferences = false
            selectedIndex = 0
            onFindDifferences()
        }
    }

    /// 今の答えを端末内に保存する。保存できなかったときはエラーを表示して false を返す
    @discardableResult
    private func saveAnswer() -> Bool {
        if model.isAnswerSaved { return true }
        guard let puzzle = model.makeSavedPuzzle() else {
            isShowingSaveError = true
            return false
        }
        modelContext.insert(puzzle)
        do {
            // 自動保存を待たずにここで書き込み、失敗を検知できるようにする
            try modelContext.save()
        } catch {
            modelContext.delete(puzzle)
            isShowingSaveError = true
            return false
        }
        model.markAnswerSaved()
        return true
    }
}

/// 一覧に並べる、間違い 1 箇所ぶんの左右の切り抜き（間違いが角にあることもあるので、絵の角は丸めない）
private struct DifferenceCard: View {
    let thumbnail: DifferenceThumbnail

    var body: some View {
        HStack(spacing: 4) {
            thumbnailImage(thumbnail.imageA)
            thumbnailImage(thumbnail.imageB)
                .overlay {
                    MarkerCircle(center: thumbnail.markerCenterB, fraction: thumbnail.markerFraction, lineWidth: 2)
                }
                .clipped()
        }
        .padding(6)
        .background(Color.appCard, in: .rect(cornerRadius: 12))
        .overlay(alignment: .topLeading) {
            NumberBadge(number: thumbnail.number)
                .offset(x: -4, y: -4)
        }
        .padding(.top, 4)
        .padding(.leading, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("間違い \(thumbnail.number)")
    }

    private func thumbnailImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 80, height: 80)
            .clipped()
    }
}

/// 切り抜き画像の上に重ねる、間違いを囲む円
private struct MarkerCircle: View {
    let center: CGPoint
    let fraction: CGFloat
    let lineWidth: CGFloat
    var color: Color = .red

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height) * fraction
            Circle()
                .stroke(color, lineWidth: lineWidth)
                .background(Circle().stroke(.white, lineWidth: lineWidth * 2.5))
                .frame(width: diameter, height: diameter)
                .position(x: proxy.size.width * center.x, y: proxy.size.height * center.y)
        }
        .allowsHitTesting(false)
    }
}

private struct NumberBadge: View {
    let number: Int

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(minWidth: 24, minHeight: 24)
            .background(Color.red, in: .circle)
            .overlay(Circle().stroke(.white, lineWidth: 2))
    }
}

/// ピンチで拡大・ドラッグで移動・ダブルタップで元に戻せる画像
struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(magnify.simultaneously(with: drag))
            .onTapGesture(count: 2) {
                withAnimation(.snappy) { reset() }
            }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(6, max(1, lastScale * value.magnification))
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 { withAnimation(.snappy) { reset() } }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}

#Preview {
    ContentView()
}
