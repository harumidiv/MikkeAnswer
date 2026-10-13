//
//  RegionEditorView.swift
//  MikkeAnswer
//

import SwiftUI

/// 2 つの絵の範囲を、四隅のつまみをドラッグして指定する画面
struct RegionEditorView: View {
    let request: RegionEditorRequest
    let onDone: (_ quadA: [CGPoint], _ quadB: [CGPoint]) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 四隅（画像のピクセル座標：左上・右上・右下・左下）。[0] が左の絵、[1] が右の絵
    @State private var quads: [[CGPoint]]
    @State private var activeHandle: Handle?
    @State private var dragStart: CGPoint?

    private struct Handle: Equatable {
        let quad: Int
        let corner: Int
    }

    private let colors: [Color] = [.blue, .orange]
    private let titles = ["左の絵", "右の絵"]
    private let handleSize: CGFloat = 30
    private let loupeSize: CGFloat = 120
    private let loupeZoom: CGFloat = 3

    init(request: RegionEditorRequest, onDone: @escaping (_ quadA: [CGPoint], _ quadB: [CGPoint]) -> Void) {
        self.request = request
        self.onDone = onDone
        _quads = State(initialValue: [request.quadA, request.quadB])
    }

    private var imageSize: CGSize {
        CGSize(width: request.image.width, height: request.image.height)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("●をドラッグして、2 つの絵それぞれの四隅に合わせてください")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                GeometryReader { proxy in
                    editor(in: fitRect(for: proxy.size))
                }
            }
            .padding()
            .navigationTitle("絵の範囲を調整")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        onDone(quads[0], quads[1])
                        dismiss()
                    }
                    .bold()
                }
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

            ForEach(quads.indices, id: \.self) { q in
                let points = quads[q].map(viewPoint)
                Path { path in
                    path.addLines(points)
                    path.closeSubpath()
                }
                .fill(colors[q].opacity(0.12))
                Path { path in
                    path.addLines(points)
                    path.closeSubpath()
                }
                .stroke(colors[q], lineWidth: 2)

                Text(titles[q])
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(colors[q], in: .capsule)
                    .position(centroid(of: points))
                    .allowsHitTesting(false)

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

            if let activeHandle {
                loupe(around: quads[activeHandle.quad][activeHandle.corner], frame: frame, scale: scale,
                      color: colors[activeHandle.quad])
            }
        }
    }

    private func drag(quad: Int, corner: Int, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? quads[quad][corner]
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

    /// 指の下が隠れて見えないので、つまみの周辺を拡大して表示する（指と反対側の上隅に出す）
    private func loupe(around point: CGPoint, frame: CGRect, scale: CGFloat, color: Color) -> some View {
        let zoomedScale = scale * loupeZoom
        let onLeft = frame.minX + point.x * scale > frame.midX
        return Image(uiImage: UIImage(cgImage: request.image))
            .resizable()
            .frame(width: imageSize.width * zoomedScale, height: imageSize.height * zoomedScale)
            .offset(x: loupeSize / 2 - point.x * zoomedScale, y: loupeSize / 2 - point.y * zoomedScale)
            .frame(width: loupeSize, height: loupeSize, alignment: .topLeading)
            .clipShape(.circle)
            .overlay {
                // 十字線：この中心がつまみの位置
                ZStack {
                    Rectangle().fill(color).frame(width: 1.5, height: 24)
                    Rectangle().fill(color).frame(width: 24, height: 1.5)
                }
            }
            .overlay(Circle().stroke(.white, lineWidth: 3))
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
