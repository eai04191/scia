import QuickLook
import QuickLookThumbnailing
import SciaCore
import SwiftUI

/// メディアのキャッシュの段（表示済みか先読み）に残っているファイルを、最後に使った順に並べる画面。
/// 表示済みは、ビューアで開いた画像と、共有や保存で落としたもの。先読みは、ビューアで開く前に読んでおいた画像。
/// 押すとQuick Lookで開き、そこから共有や保存をする。どの投稿のものかは記録していないので出さない。
struct MediaCacheView: View {
    /// 並べる処理と開く処理。部品カタログでは、アプリのキャッシュに触れずに状態を作るために差し替える。
    struct Actions {
        var entries: @Sendable () async -> [MediaFileCache.Entry]
        /// 共有や保存に渡すコピーを作る。並べたあとにキャッシュから消えていればnil。
        var open: @Sendable (MediaFileCache.Entry.ID) async throws -> URL?
    }

    /// 並べる段。`mediaFiles`（表示済み）か`mediaPrefetch`（先読み）。
    let category: StorageBreakdown.Category
    let actions: Actions
    @State private var entries: [MediaFileCache.Entry]?
    @State private var previewing: URL?
    @State private var openError: String?

    init(category: StorageBreakdown.Category, actions: Actions) {
        self.category = category
        self.actions = actions
    }

    var body: some View {
        Group {
            if let entries, entries.isEmpty {
                ContentUnavailableView("\(StorageView.name(of: category))はありません", systemImage: "photo.on.rectangle")
            } else if let entries {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 2)], spacing: 2) {
                        ForEach(entries) { entry in
                            Button {
                                open(entry)
                            } label: {
                                MediaCacheTile(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(entry.file.lastPathComponent)
                        }
                    }
                    // 写真アプリの一覧の下と同じく、件数だけを出す。
                    Text("\(entries.count)件")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            } else {
                ProgressView("読み込んでいます")
            }
        }
        .navigationTitle(StorageView.name(of: category))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            entries = await actions.entries()
        }
        .quickLookPreview($previewing)
        .alert(
            "開けませんでした",
            isPresented: Binding { openError != nil } set: { if !$0 { openError = nil } },
            presenting: openError
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    private func open(_ entry: MediaFileCache.Entry) {
        Task {
            do {
                if let copy = try await actions.open(entry.id) {
                    previewing = copy
                } else {
                    openError = "キャッシュから消えていました。"
                    entries = await actions.entries()
                }
            } catch {
                openError = ErrorPresentation(error).text
            }
        }
    }
}

/// 並べるファイル1つのサムネイル。画像も動画も、ファイルからQuick Lookで作る。
private struct MediaCacheTile: View {
    let entry: MediaFileCache.Entry
    @State private var thumbnail: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Color(uiColor: .secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
            .contentShape(.rect)
            // LazyVGridは画面外に出たセルの状態も持ち続けるため、出るたびに作り、外れたら手放す。キャッシュの件数だけ展開した画像が溜まらないようにする。
            .task(id: entry.id) {
                let request = QLThumbnailGenerator.Request(fileAt: entry.file, size: CGSize(width: 192, height: 192), scale: displayScale, representationTypes: .thumbnail)
                let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
                guard !Task.isCancelled else { return }
                thumbnail = image
            }
            .onDisappear {
                thumbnail = nil
            }
    }
}

extension MediaCacheView.Actions {
    /// `files`に置いたファイルを並べる。
    static func app(_ files: MediaFileCache) -> Self {
        Self(
            entries: { await files.entries() },
            open: { try await files.copyForSharing(of: $0) }
        )
    }
}
