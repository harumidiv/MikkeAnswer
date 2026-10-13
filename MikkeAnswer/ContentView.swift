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
    @State private var selectedThumbnail: DifferenceThumbnail?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                imageArea
                statusView
                if !model.thumbnails.isEmpty {
                    differenceList
                }
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
        .sheet(item: $selectedThumbnail) { thumbnail in
            DifferenceDetailView(thumbnail: thumbnail)
                .presentationDetents([.medium, .large])
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
        Text("\(number)")
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
                ViewThatFits {
                    HStack(spacing: 12) { panels }
                    VStack(spacing: 12) { panels }
                }
                .padding()
            }
            .navigationTitle("間違い \(thumbnail.number)")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var panels: some View {
        panel("左（上）の絵", image: thumbnail.imageA, marker: nil)
        panel("右（下）の絵", image: thumbnail.imageB, marker: thumbnail.markerCenterB)
    }

    private func panel(_ title: String, image: UIImage, marker: CGPoint?) -> some View {
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
