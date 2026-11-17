//
//  RegionEditorView.swift
//  MikkeAnswer
//

import SwiftUI

/// 2 つの絵の範囲を、四隅のつまみをドラッグして指定する画面。
/// 「次へ」で範囲を切り出した 2 枚を、ユーザーが重ね合わせる画面（OverlayEditorView）に進む
struct RegionEditorView: View {
    let request: RegionEditorRequest
    /// 範囲を同じ大きさの 2 枚に切り出す
    let prepare: @MainActor (_ quadA: [CGPoint], _ quadB: [CGPoint]) async throws -> ManualAlignment
    /// 重ね合わせが決まったとき（overlay: pictureB → pictureA の座標）
    let onFinish: (_ alignment: ManualAlignment, _ overlay: CGAffineTransform) -> Void
    /// 撮り直し・選び直し（写真を読み込んだ直後だけ。ボタンの文言とともに渡す）
    let retake: RetakeOption?

    @Environment(\.dismiss) private var dismiss
    /// 視差効果を減らす設定のときは、選んでいる絵の点線を流さない
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 四隅（画像のピクセル座標：左上・右上・右下・左下）。[0] が左の絵、[1] が右の絵
    @State private var quads: [[CGPoint]]
    /// 四隅を動かせる方の絵（隣り合った絵のつまみを掴み間違えないよう、片方ずつ編集する）
    @State private var selectedQuad = 0
    @State private var activeHandle: Handle?
    @State private var dragStart: CGPoint?
    /// 拡大鏡を左上に出すか（ドラッグ開始時に決め、指を離すまで動かさない）
    @State private var loupeOnLeft = false
    @State private var isPreparing = false
    @State private var overlayStep: OverlayStep?
    @State private var errorMessage: String?

    private struct Handle: Equatable {
        let quad: Int
        let corner: Int
    }

    private struct OverlayStep: Identifiable, Hashable {
        let id = UUID()
        let alignment: ManualAlignment

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private let colors: [Color] = [.blue, .orange]
    private let titles: [LocalizedStringResource] = ["左の絵", "右の絵"]
    /// 文の中に絵の名前を差し込むと語順を訳せないため、文ごと用意する
    private let instructions: [LocalizedStringResource] = [
        "●をドラッグして、左の絵の四隅に合わせてください",
        "●をドラッグして、右の絵の四隅に合わせてください",
    ]
    private let handleSize: CGFloat = 30
    private let loupeSize: CGFloat = 120
    private let loupeZoom: CGFloat = 3

    init(request: RegionEditorRequest,
         prepare: @escaping @MainActor (_ quadA: [CGPoint], _ quadB: [CGPoint]) async throws -> ManualAlignment,
         onFinish: @escaping (_ alignment: ManualAlignment, _ overlay: CGAffineTransform) -> Void,
         retake: RetakeOption? = nil) {
        self.request = request
        self.prepare = prepare
        self.onFinish = onFinish
        self.retake = retake
        _quads = State(initialValue: [request.quadA, request.quadB])
    }

    private var imageSize: CGSize {
        CGSize(width: request.image.width, height: request.image.height)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                StepIndicator(current: .align)
                VStack(alignment: .leading, spacing: 4) {
                    Text("絵の 4 すみを合わせよう")
                        .font(.appRounded(.title3))
                        .accessibilityAddTraits(.isHeader)
                    Text(instructions[selectedQuad])
                        .font(.subheadline)
                        .foregroundStyle(Color.appSubtext)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker("動かす絵", selection: $selectedQuad) {
                    ForEach(titles.indices, id: \.self) { Text(titles[$0]) }
                }
                .pickerStyle(.segmented)
                GeometryReader { proxy in
                    editor(in: fitRect(for: proxy.size))
                }
                if let retake {
                    Button {
                        retake.action()
                        dismiss()
                    } label: {
                        Label {
                            Text(retake.title)
                        } icon: {
                            Image(systemName: retake.systemImage)
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.appBrandText)
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(isPreparing)
                }
                bottomBar
            }
            .padding()
            // 後ろの画面（前回の結果）が透けて見えないよう、背景を塗りつぶす
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appGround.ignoresSafeArea())
            .navigationTitle("絵の範囲を調整")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
            .navigationDestination(item: $overlayStep) { step in
                OverlayEditorView(alignment: step.alignment) { overlay in
                    onFinish(step.alignment, overlay)
                    dismiss()
                }
            }
            .alert("絵を切り出せませんでした", isPresented: Binding(get: { errorMessage != nil },
                                                                 set: { if !$0 { errorMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// 最初の位置に戻す・次へ
    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.snappy) {
                    quads = [request.quadA, request.quadB]
                }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.title3.bold())
            }
            .buttonStyle(.appSecondary)
            .disabled(isPreparing || quads == [request.quadA, request.quadB])
            .accessibilityLabel("最初の位置に戻す")

            Button {
                goToOverlay()
            } label: {
                if isPreparing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Label("次へ：絵を重ねる", systemImage: "chevron.forward")
                        .labelStyle(TrailingIconLabelStyle())
                }
            }
            .buttonStyle(.appPrimary)
            .disabled(isPreparing)
        }
    }

    private func goToOverlay() {
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                overlayStep = OverlayStep(alignment: try await prepare(quads[0], quads[1]))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func editor(in frame: CGRect) -> some View {
        let scale = frame.width / imageSize.width
        func viewPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: frame.minX + p.x * scale, y: frame.minY + p.y * scale)
        }
        return ZStack(alignment: .topLeading) {
            Image(uiImage: UIImage(cgImage: request.image))
                .resizable()
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)

            // 選んでいない絵は点線で薄く表示するだけにし、選んでいる絵を上に重ねる
            ForEach([1 - selectedQuad, selectedQuad], id: \.self) { q in
                let points = quads[q].map(viewPoint)
                let isSelected = q == selectedQuad
                Path { path in
                    path.addLines(points)
                    path.closeSubpath()
                }
                .fill(colors[q].opacity(isSelected ? 0.12 : 0.04))
                .allowsHitTesting(false)
                if isSelected {
                    MarchingOutline(points: points, color: colors[q], animates: !reduceMotion)
                } else {
                    Path { path in
                        path.addLines(points)
                        path.closeSubpath()
                    }
                    .stroke(colors[q].opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .allowsHitTesting(false)
                }

                Text(titles[q])
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(colors[q].opacity(isSelected ? 1 : 0.5), in: .capsule)
                    .position(centroid(of: points))
                    .allowsHitTesting(false)

                if isSelected {
                    ForEach(0..<4, id: \.self) { c in
                        Circle()
                            .fill(colors[q])
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .shadow(radius: 2)
                            .frame(width: handleSize, height: handleSize)
                            .contentShape(.circle.inset(by: -10))   // 指で掴みやすいよう当たり判定を広げる
                            .position(points[c])
                            .gesture(drag(quad: q, corner: c, scale: scale))
                    }
                }
            }

            if let activeHandle {
                loupe(around: quads[activeHandle.quad][activeHandle.corner], frame: frame, scale: scale,
                      onLeft: loupeOnLeft, color: colors[activeHandle.quad])
            }
        }
    }

    private func drag(quad: Int, corner: Int, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? quads[quad][corner]
                if dragStart == nil {
                    // 中央付近で左右を行き来しても拡大鏡が飛び移らないよう、掴んだ時点の位置で決める
                    loupeOnLeft = start.x > imageSize.width / 2
                }
                dragStart = start
                activeHandle = Handle(quad: quad, corner: corner)
                quads[quad][corner] = CGPoint(
                    x: min(max(start.x + value.translation.width / scale, 0), imageSize.width),
                    y: min(max(start.y + value.translation.height / scale, 0), imageSize.height))
            }
            .onEnded { _ in
                dragStart = nil
                activeHandle = nil
            }
    }

    /// 指の下が隠れて見えないので、つまみの周辺を拡大して表示する（掴んだときの指と反対側の上隅に出す）
    private func loupe(around point: CGPoint, frame: CGRect, scale: CGFloat, onLeft: Bool,
                       color: Color) -> some View {
        let zoomedScale = scale * loupeZoom
        return Image(uiImage: UIImage(cgImage: request.image))
            .resizable()
            .frame(width: imageSize.width * zoomedScale, height: imageSize.height * zoomedScale)
            .offset(x: loupeSize / 2 - point.x * zoomedScale, y: loupeSize / 2 - point.y * zoomedScale)
            .frame(width: loupeSize, height: loupeSize, alignment: .topLeading)
            // 絵のかどを合わせるための拡大なので、角を丸めて隠さない
            .clipShape(.rect)
            .overlay {
                // 十字線：この中心がつまみの位置
                ZStack {
                    Rectangle().fill(color).frame(width: 1.5, height: 24)
                    Rectangle().fill(color).frame(width: 24, height: 1.5)
                }
            }
            .overlay(Rectangle().stroke(.white, lineWidth: 3))
            .overlay(Rectangle().stroke(color, lineWidth: 1).padding(-1.5))
            .shadow(radius: 4)
            .position(x: onLeft ? frame.minX + loupeSize / 2 + 8 : frame.maxX - loupeSize / 2 - 8,
                      y: frame.minY + loupeSize / 2 + 8)
            .allowsHitTesting(false)
    }

    /// 画像をアスペクト比を保って size に収めたときの表示位置
    private func fitRect(for size: CGSize) -> CGRect {
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    private func centroid(of points: [CGPoint]) -> CGPoint {
        CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }
}

/// 文字のあとにアイコンを置く（「次へ ›」のように進む向きを示す）
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

/// 選んでいる絵の範囲の枠。白い線の上に色の点線を重ね、点線を枠に沿って流し続ける（どちらの絵を動かしているかがひと目でわかる）
private struct MarchingOutline: View {
    let points: [CGPoint]
    let color: Color
    let animates: Bool

    /// 点線 1 周期（線 + すき間）の長さと、それが流れるのにかかる時間
    private static let dash: [CGFloat] = [10, 6]
    private static let cycle: TimeInterval = 0.6

    var body: some View {
        TimelineView(.animation(paused: !animates)) { timeline in
            let period = Self.dash.reduce(0, +)
            let progress = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.cycle) / Self.cycle
            let path = Path { path in
                path.addLines(points)
                path.closeSubpath()
            }
            ZStack {
                path.stroke(.white, lineWidth: 3)
                path.stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: Self.dash,
                                                      dashPhase: animates ? -period * progress : 0))
            }
        }
        .allowsHitTesting(false)
    }
}

