//
//  OverlayEditorView.swift
//  MikkeAnswer
//

import SwiftUI

/// 範囲を切り出した 2 枚を、ユーザーが重ね合わせる画面。
/// 左の絵の上に右の絵を重ね、ドラッグで移動・ピンチで拡大縮小・2 本指で回転して位置を合わせる
struct OverlayEditorView: View {
    let alignment: ManualAlignment
    /// 決まった重ね方（pictureB の座標 → pictureA の座標）
    let onDone: (CGAffineTransform) -> Void

    private enum Mode: CaseIterable, Identifiable {
        case translucent
        case difference
        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .translucent: "半透明"
            case .difference: "差分"
            }
        }
    }

    @State private var mode = Mode.translucent
    @State private var opacity = 0.5
    /// 左右の絵を交互に表示する（ずれている所や間違いがちらついて見える）
    @State private var isBlinking = false
    /// 点滅中に右の絵を表示しているか
    @State private var showsBInBlink = true
    /// 右の絵の位置（絵の中心まわりに拡大・回転してから、ピクセル単位で平行移動）
    @State private var offset = CGSize.zero
    @State private var scale: CGFloat = 1
    @State private var rotation: Double = 0
    /// 操作中のジェスチャーの変化量
    @GestureState private var dragDelta = CGSize.zero
    @GestureState private var magnifyDelta: CGFloat = 1
    @GestureState private var rotateDelta = Angle.zero

    private let imageA: UIImage
    private let imageB: UIImage
    private let scaleRange: ClosedRange<CGFloat> = 0.5...2
    private let rotationRange: ClosedRange<Double> = -30...30
    private let blinkInterval: Duration = .milliseconds(500)

    init(alignment: ManualAlignment, onDone: @escaping (CGAffineTransform) -> Void) {
        self.alignment = alignment
        self.onDone = onDone
        imageA = UIImage(cgImage: alignment.pictureA)
        imageB = UIImage(cgImage: alignment.pictureB)
    }

    private var pictureSize: CGSize {
        CGSize(width: alignment.pictureA.width, height: alignment.pictureA.height)
    }

    private var currentScale: CGFloat {
        min(max(scale * magnifyDelta, scaleRange.lowerBound), scaleRange.upperBound)
    }

    private var currentRotation: Double {
        min(max(rotation + rotateDelta.degrees, rotationRange.lowerBound), rotationRange.upperBound)
    }

    private func currentOffset(viewScale: CGFloat) -> CGSize {
        CGSize(width: offset.width + dragDelta.width / viewScale, height: offset.height + dragDelta.height / viewScale)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(guide)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            GeometryReader { proxy in
                let frame = fitRect(for: proxy.size)
                canvas(in: frame)
                    .contentShape(.rect)
                    .gesture(transformGesture(viewScale: frame.width / pictureSize.width))
            }
            controls
        }
        .padding()
        // 後ろの画面（前回の結果）が透けて見えないよう、背景を塗りつぶす
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .task(id: blinksNow) {
            showsBInBlink = true
            guard blinksNow else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: blinkInterval)
                showsBInBlink.toggle()
            }
        }
        .navigationTitle("2 つの絵を重ねる")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("間違いを探す") { onDone(overlayTransform) }
                    .bold()
            }
        }
    }

    private func canvas(in frame: CGRect) -> some View {
        let viewScale = frame.width / pictureSize.width
        let offset = currentOffset(viewScale: viewScale)
        return ZStack {
            Image(uiImage: imageA)
                .resizable()
            Image(uiImage: imageB)
                .resizable()
                .scaleEffect(currentScale)
                .rotationEffect(.degrees(currentRotation))
                .offset(x: offset.width * viewScale, y: offset.height * viewScale)
                .opacity(bOpacity)
                .blendMode(mode == .difference ? .difference : .normal)
        }
        .compositingGroup()
        .frame(width: frame.width, height: frame.height)
        .clipped()
        .position(x: frame.midX, y: frame.midY)
    }

    private func transformGesture(viewScale: CGFloat) -> some Gesture {
        let drag = DragGesture()
            .updating($dragDelta) { value, state, _ in state = value.translation }
            .onEnded { value in
                offset.width += value.translation.width / viewScale
                offset.height += value.translation.height / viewScale
            }
        let magnify = MagnifyGesture()
            .updating($magnifyDelta) { value, state, _ in state = value.magnification }
            .onEnded { value in
                scale = min(max(scale * value.magnification, scaleRange.lowerBound), scaleRange.upperBound)
            }
        let rotate = RotateGesture()
            .updating($rotateDelta) { value, state, _ in state = value.rotation }
            .onEnded { value in
                rotation = min(max(rotation + value.rotation.degrees, rotationRange.lowerBound), rotationRange.upperBound)
            }
        return drag.simultaneously(with: magnify.simultaneously(with: rotate))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("表示", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title) }
            }
            .pickerStyle(.segmented)

            if mode == .translucent {
                Toggle("左右の絵を交互に点滅", isOn: $isBlinking)
                    .font(.subheadline)
            }

            if mode == .translucent && !isBlinking {
                HStack {
                    Text("左の絵").font(.caption)
                    Slider(value: $opacity, in: 0...1)
                    Text("右の絵").font(.caption)
                }
            }
        }
    }

    /// 点滅は半透明モードのときだけ（差分モードでは常に差分を表示する）
    private var blinksNow: Bool {
        isBlinking && mode == .translucent
    }

    private var guide: LocalizedStringResource {
        if blinksNow { return "ずれている所や間違いがちらついて見えます" }
        return mode == .difference
            ? "ぴったり重なった所は黒くなります。色が残る所が間違いの候補です"
            : "右の絵をドラッグ・ピンチ・回転して、左の絵にぴったり重ねてください"
    }

    private var bOpacity: Double {
        if blinksNow { return showsBInBlink ? 1 : 0 }
        return mode == .translucent ? opacity : 1
    }

    /// 画面上の重ね方と同じ変換（pictureB の座標 → pictureA の座標）
    private var overlayTransform: CGAffineTransform {
        let cx = pictureSize.width / 2, cy = pictureSize.height / 2
        return CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: cx + offset.width, y: cy + offset.height))
    }

    /// 画像をアスペクト比を保って size に収めたときの表示位置
    private func fitRect(for size: CGSize) -> CGRect {
        let scale = min(size.width / pictureSize.width, size.height / pictureSize.height)
        let fitted = CGSize(width: pictureSize.width * scale, height: pictureSize.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }
}
