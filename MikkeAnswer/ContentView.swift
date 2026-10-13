//
//  ContentView.swift
//  MikkeAnswer
//
//  Created by harumi.sagawa on 2026/10/13.
//

import PhotosUI
import SwiftUI

struct ContentView: View {
    @State private var model = PuzzleSolverModel()
    @State private var photoItem: PhotosPickerItem?
    @State private var isShowingCamera = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                imageArea
                statusView
                if model.hasImage {
                    controls
                }
                inputButtons
            }
            .padding()
            .navigationTitle("みっけアンサー")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { image in model.load(image) }
                .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    model.load(image)
                }
                photoItem = nil
            }
        }
    }

    @ViewBuilder
    private var imageArea: some View {
        if let image = model.displayImage {
            ZoomableImage(image: image)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                .clipShape(.rect(cornerRadius: 12))
        } else {
            ContentUnavailableView {
                Label("間違い探しを撮影", systemImage: "viewfinder")
            } description: {
                Text("2 つの絵が並んだ間違い探しを、2 枚とも全体が写るように撮影するか、写真から選んでください。")
            }
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
                Text(result.differences.isEmpty
                     ? "間違いが見つかりませんでした。感度を上げてみてください。"
                     : "間違いを \(result.differences.count) 箇所 見つけました（\(Int(result.elapsed * 1000)) ms）")
                    .font(.headline)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.subheadline)
        }
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
            Toggle("絵の範囲を表示", isOn: $model.showsRegions)
                .font(.subheadline)
        }
        .disabled(model.phase == .processing)
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

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("写真から選ぶ", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }
}

/// ピンチで拡大・ドラッグで移動・ダブルタップで元に戻せる画像
private struct ZoomableImage: View {
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
