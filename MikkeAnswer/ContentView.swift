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
                }
                photoItem = nil
            }
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
            VStack(spacing: 16) {
                ContentUnavailableView {
                    Label("間違い探しを撮影", systemImage: "viewfinder")
                } description: {
                    Text("2 つの絵が両方写るように撮影してください")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                inputButtons
            }
            .padding()
            .navigationTitle("みっけアンサー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
    private func openPendingRetake() {
        guard let source = pendingRetake else { return }
        pendingRetake = nil
        isShowingResult = false
        switch source {
        case .camera: isShowingCamera = true
        case .library: isShowingPhotoPicker = true
        }
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

    private var inputButtons: some View {
        HStack(spacing: 12) {
            Button {
                isShowingCamera = true
            } label: {
                Label("撮影", systemImage: "camera")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!CameraPicker.isAvailable)

            Button {
                isShowingPhotoPicker = true
            } label: {
                Label("写真から選ぶ", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }
}

/// 範囲調整画面の、撮り直す・選び直すボタン
typealias RetakeOption = (title: LocalizedStringResource, systemImage: String, action: () -> Void)

/// 結果画面（答えの画像・見つけた間違いの一覧・感度などの調整）
private struct ResultView: View {
    @Bindable var model: PuzzleSolverModel
    let retakeOption: (RegionEditorRequest) -> RetakeOption?
    let onRegionEditorDismiss: () -> Void
    /// 「間違いを探す」で範囲調整画面が閉じきったとき
    let onFindDifferences: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var selectedThumbnail: DifferenceThumbnail?
    @State private var isConfirmingLeave = false
    /// 「間違いを探す」で範囲調整画面を閉じたか（閉じきってから広告を表示する）
    @State private var didFindDifferences = false
    /// 結果の左右の絵を交互に表示する（間違いがちらついて見える）
    @State private var isBlinking = false
    /// 点滅中に左の絵を表示しているか
    @State private var showsAInBlink = false

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

    /// 画面の高さが足りなくても、答えの画像はこの高さまでしか縮めない
    private static let minImageHeight: CGFloat = 240
    private static let spacing: CGFloat = 16
    private static let padding: CGFloat = 16

    /// 画面（スクロール領域）の高さ
    @State private var containerHeight: CGFloat = 0
    /// 画像より下の部分（状態・一覧・調整）の高さ
    @State private var lowerSectionHeight: CGFloat = 0

    /// 画面いっぱいに収まるときの画像の高さ。足りないときは最小の高さにして、全体をスクロールさせる
    private var imageHeight: CGFloat {
        max(Self.minImageHeight, containerHeight - lowerSectionHeight - Self.spacing - Self.padding * 2)
    }

    private var overflows: Bool {
        containerHeight - lowerSectionHeight - Self.spacing - Self.padding * 2 < Self.minImageHeight
    }

    var body: some View {
        // iPad でウィンドウを小さくしたときなどに、下の操作部品が画面からはみ出して広告と重ならないようにする
        ScrollView {
            VStack(spacing: Self.spacing) {
                imageArea
                    .frame(height: imageHeight)
                VStack(spacing: Self.spacing) {
                    statusView
                    if !model.thumbnails.isEmpty {
                        differenceList
                    }
                    if model.hasImage {
                        controls
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lowerSectionHeight = $0 }
            }
            .padding(Self.padding)
        }
        // 収まるときはスクロールさせない（画像の拡大・移動の操作とぶつからないように）
        .scrollDisabled(!overflows)
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { containerHeight = $0 }
        .task(id: blinksNow) {
            showsAInBlink = false
            guard blinksNow else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: blinkInterval)
                showsAInBlink.toggle()
            }
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
            if let answer = model.answerImageB, model.phase != .processing {
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
        }
        .sheet(item: $selectedThumbnail) { thumbnail in
            DifferenceDetailView(thumbnail: thumbnail)
                .presentationDetents([.medium, .large])
        }
        .alert("保存せずに戻りますか？", isPresented: $isConfirmingLeave) {
            Button("保存して戻る") {
                saveAnswer()
                dismiss()
            }
            Button("保存せずに戻る", role: .destructive) { dismiss() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("保存していない結果は消えます。")
        }
    }

    /// 範囲調整画面が閉じきったとき（閉じる途中には別の画面を出せないため、ここで広告や撮り直しの画面を出す）
    private func regionEditorDidDismiss() {
        onRegionEditorDismiss()
        if didFindDifferences {
            didFindDifferences = false
            onFindDifferences()
        }
    }

    /// 今の答えを端末内に保存する
    private func saveAnswer() {
        guard let puzzle = model.makeSavedPuzzle() else { return }
        modelContext.insert(puzzle)
        model.markAnswerSaved()
    }

    @ViewBuilder
    private var imageArea: some View {
        if let image = model.displayImage {
            ZoomableImage(image: blinksNow && showsAInBlink ? model.answerImageA ?? image : image)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                .clipShape(.rect(cornerRadius: 12))
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .processing:
            ProgressView("解析中…")
        case .finished:
            if let result = model.result {
                Group {
                    if result.differences.isEmpty {
                        Text("間違いが見つかりませんでした。感度を上げてみてください。")
                    } else {
                        Text("間違いを \(result.differences.count) 箇所 見つけました（\(Int(result.elapsed * 1000)) ms）")
                    }
                }
                .font(.headline)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.subheadline)
        }
    }

    /// 見つけた間違いの一覧（左右の絵の切り抜きを並べたカード）
    private var differenceList: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(model.thumbnails) { thumbnail in
                    Button {
                        selectedThumbnail = thumbnail
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

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("控えめ").font(.caption)
                Slider(value: $model.sensitivity, in: 0...1) { editing in
                    if !editing { model.analyze() }
                }
                Text("敏感").font(.caption)
            }
            if canBlink {
                Toggle("左右の絵を交互に点滅", isOn: $isBlinking)
                    .font(.subheadline)
            }
            HStack {
                Toggle("元の写真で絵の範囲を確認", isOn: $model.showsRegions)
                    .font(.subheadline)
                Button("範囲・重ね方を調整", systemImage: "crop") {
                    model.beginRegionEditing()
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
            }
        }
        .disabled(model.phase == .processing)
    }
}

private struct DifferenceCard: View {
    let thumbnail: DifferenceThumbnail

    var body: some View {
        HStack(spacing: 4) {
            thumbnailImage(thumbnail.imageA)
                .clipShape(.rect(cornerRadius: 8))
            thumbnailImage(thumbnail.imageB)
                .overlay {
                    MarkerCircle(center: thumbnail.markerCenterB, fraction: thumbnail.markerFraction, lineWidth: 2)
                }
                .clipShape(.rect(cornerRadius: 8))
        }
        .padding(6)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
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
    }
}

/// 切り抜き画像の上に重ねる、間違いを囲む円
private struct MarkerCircle: View {
    let center: CGPoint
    let fraction: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height) * fraction
            Circle()
                .stroke(.red, lineWidth: lineWidth)
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

/// 1 箇所の間違いを左右の絵で大きく見比べる画面
private struct DifferenceDetailView: View {
    let thumbnail: DifferenceThumbnail

    var body: some View {
        NavigationStack {
            ScrollView {
                // 見比べやすいよう、画面が狭くても左右に並べる（各パネルは画面幅の半分まで縮める）
                HStack(alignment: .top, spacing: 12) { panels }
                    .padding()
            }
            .navigationTitle("間違い \(thumbnail.number)")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var panels: some View {
        panel("左の絵", image: thumbnail.imageA, marker: nil)
        panel("右の絵", image: thumbnail.imageB, marker: thumbnail.markerCenterB)
    }

    private func panel(_ title: LocalizedStringKey, image: UIImage, marker: CGPoint?) -> some View {
        VStack(spacing: 6) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .overlay {
                    if let marker {
                        MarkerCircle(center: marker, fraction: thumbnail.markerFraction, lineWidth: 4)
                    }
                }
                .frame(maxWidth: 360)
                .clipShape(.rect(cornerRadius: 12))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
