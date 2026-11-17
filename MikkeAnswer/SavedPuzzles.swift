//
//  SavedPuzzles.swift
//  MikkeAnswer
//

import SwiftData
import SwiftUI

/// 端末内に保存した、判定済みの間違い探し
@Model
final class SavedPuzzle {
    var createdAt: Date
    var differenceCount: Int
    /// ⭕️と番号を付けた左の絵・右の絵（同じ大きさ。透明な余白を保つため HEIC か PNG）
    @Attribute(.externalStorage) var answerA: Data
    @Attribute(.externalStorage) var answerB: Data

    init(createdAt: Date = .now, differenceCount: Int, answerA: Data, answerB: Data) {
        self.createdAt = createdAt
        self.differenceCount = differenceCount
        self.answerA = answerA
        self.answerB = answerB
    }

    /// 答えの画像から作る（エンコードできなければ nil）
    convenience init?(differenceCount: Int, answerA: UIImage, answerB: UIImage) {
        guard let a = Self.encode(answerA), let b = Self.encode(answerB) else { return nil }
        self.init(differenceCount: differenceCount, answerA: a, answerB: b)
    }

    private static func encode(_ image: UIImage) -> Data? {
        image.heicData() ?? image.pngData()
    }
}

/// 保存した間違い探しの一覧
struct SavedPuzzleListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedPuzzle.createdAt, order: .reverse) private var puzzles: [SavedPuzzle]

    var body: some View {
        Group {
            if puzzles.isEmpty {
                ContentUnavailableView {
                    Label("保存した間違い探しはありません", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("結果画面の「保存」で、判定した間違い探しをこの端末に保存できます")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("保存した答えは、この端末だけに残ります。長押しで削除できます。")
                            .font(.footnote)
                            .foregroundStyle(Color.appSubtext)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                            ForEach(puzzles) { puzzle in
                                NavigationLink {
                                    SavedPuzzleDetailView(puzzle: puzzle)
                                } label: {
                                    SavedPuzzleCard(puzzle: puzzle)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("削除", systemImage: "trash", role: .destructive) {
                                        modelContext.delete(puzzle)
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(Color.appGround.ignoresSafeArea())
        .navigationTitle("保存した間違い探し")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 一覧の 1 件（答えの絵の角は、間違いがあるかもしれないので丸めない）
private struct SavedPuzzleCard: View {
    let puzzle: SavedPuzzle
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.appGround
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 170)

            VStack(alignment: .leading, spacing: 2) {
                Text(puzzle.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.subheadline.bold())
                Text("見つかった間違い：\(puzzle.differenceCount)")
                    .font(.footnote.bold())
                    .foregroundStyle(Color.appAnswer)
            }
            .padding(.horizontal, 2)
        }
        .padding(10)
        .background(Color.appCard, in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
        .accessibilityElement(children: .combine)
        .task(id: puzzle.persistentModelID) {
            // 一覧ではフルサイズを持たず、縮小した画像だけを表示する
            thumbnail = await UIImage(data: puzzle.answerB)?.byPreparingThumbnail(ofSize: CGSize(width: 480, height: 480))
        }
    }
}

/// 保存した間違い探しの答え（結果画面と同じく、拡大・左右の絵の点滅・共有ができる）
private struct SavedPuzzleDetailView: View {
    let puzzle: SavedPuzzle
    @State private var imageA: UIImage?
    @State private var imageB: UIImage?
    @State private var isBlinking = false
    @State private var showsAInBlink = false

    private let blinkInterval: Duration = .milliseconds(500)

    var body: some View {
        VStack(spacing: 16) {
            if let imageB {
                ZoomableImage(image: isBlinking && showsAInBlink ? imageA ?? imageB : imageB)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.appCard)
                    .clipped()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("見つかった間違い：\(puzzle.differenceCount)")
                .font(.appRounded(.headline))
                .foregroundStyle(Color.appAnswer)
            if imageA != nil {
                Toggle("左右の絵を交互に点滅", isOn: $isBlinking)
                    .font(.subheadline)
                    .appCard(padding: 14)
            }
        }
        .padding()
        .background(Color.appGround.ignoresSafeArea())
        .navigationTitle(Text(puzzle.createdAt, format: .dateTime.year().month().day().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let imageB {
                    AnswerShareLink(answer: imageB)
                }
            }
        }
        .task {
            imageA = UIImage(data: puzzle.answerA)
            imageB = UIImage(data: puzzle.answerB)
        }
        .task(id: isBlinking) {
            showsAInBlink = false
            guard isBlinking else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: blinkInterval)
                showsAInBlink.toggle()
            }
        }
    }
}
