#if DEBUG
import SciaCore
import SwiftUI
import UIKit

/// 設定のストレージの画面。ファイルを測ったり消したりせずに、測っている途中、消している途中、消せなかったとき、測れない項目があるとき、GBの大きさを並べる。消すを押しても何も消さない。
enum StorageCatalog {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "ファイルを消す権限がありません。" }
    }

    @MainActor
    static func states() -> [CatalogState] {
        [
            state("測っている途中", measure: { try? await Task.sleep(for: .seconds(3_600)); return small }),
            state("消している途中（一時ファイル）", removing: .temporaryFiles),
            state("消せなかった", removeError: ErrorPresentation(Failure()).text),
            state("消せるものがない", breakdown: empty),
            state("測れない項目がある（実機のアプリ内のSafari）", breakdown: unmeasured),
            state("GBの大きさ", breakdown: large),
        ]
    }

    private static let small = StorageBreakdown(
        items: [
            .init(category: .mediaFiles, bytes: 8_800_000, removableBytes: 8_800_000),
            .init(category: .mediaPrefetch, bytes: 42_300_000, removableBytes: 42_300_000),
            .init(category: .networkCache, bytes: 1_500_000, removableBytes: 1_500_000),
            .init(category: .temporaryFiles, bytes: 164_200_000, removableBytes: 164_163_000),
            .init(category: .inAppSafari, bytes: 13_600_000, removableBytes: 13_600_000),
            .init(category: .discomfortReports, bytes: 236_000, removableBytes: 236_000),
            .init(category: .settings, bytes: 4_096),
            .init(category: .sharedMedia, bytes: 0),
            .init(category: .other, bytes: 4_400_000),
        ],
        appBytes: 88_200_000
    )

    private static let empty = StorageBreakdown(
        items: StorageBreakdown.Category.allCases.map { .init(category: $0, bytes: 0) },
        appBytes: 88_200_000
    )

    private static let unmeasured = StorageBreakdown(
        items: small.items.map { $0.category == .inAppSafari ? .init(category: .inAppSafari, bytes: nil, removableBytes: nil) : $0 },
        appBytes: small.appBytes
    )

    private static let large = StorageBreakdown(
        items: [
            .init(category: .mediaFiles, bytes: 157_286_400, removableBytes: 157_286_400),
            .init(category: .mediaPrefetch, bytes: 104_857_600, removableBytes: 104_857_600),
            .init(category: .networkCache, bytes: 1_234_567_890, removableBytes: 1_234_567_890),
            .init(category: .temporaryFiles, bytes: 12_345_678_901, removableBytes: 12_000_000_000),
            .init(category: .inAppSafari, bytes: 987_654_321, removableBytes: 987_654_321),
            .init(category: .discomfortReports, bytes: 2_345_678_901, removableBytes: 2_345_678_901),
            .init(category: .settings, bytes: 1_048_576),
            .init(category: .sharedMedia, bytes: 3_456_789_012),
            .init(category: .other, bytes: 456_789_012),
        ],
        appBytes: 1_234_567_890
    )

    /// ストレージのメディアのキャッシュの段（表示済みと先読み）の中身の画面。アプリのキャッシュに触れず、カタログ用の場所に書いた画像を並べる。
    /// 押すと開くが、キャッシュから消えていた失敗はアラートなので、`open`がnilを返す状態で押して確かめる。
    @MainActor
    static func mediaCacheStates() -> [CatalogState] {
        let files = catalogMediaFiles()
        return [
            mediaCacheState("読み込んでいる途中", entries: { try? await Task.sleep(for: .seconds(3_600)); return [] }),
            mediaCacheState("ない（表示済み）", entries: { [] }),
            mediaCacheState("ない（先読み）", category: .mediaPrefetch, entries: { [] }),
            mediaCacheState("並んでいる（縦長、横長、画像でないファイル）", entries: { files }),
            mediaCacheState("並んでいる（先読み）", category: .mediaPrefetch, entries: { files }),
            mediaCacheState("押すとキャッシュから消えていた", entries: { files }, open: { _ in nil }),
        ]
    }

    @MainActor
    private static func mediaCacheState(
        _ title: String,
        category: StorageBreakdown.Category = .mediaFiles,
        entries: @escaping @Sendable () async -> [MediaFileCache.Entry],
        open: (@Sendable (MediaFileCache.Entry.ID) async throws -> URL?)? = nil
    ) -> CatalogState {
        CatalogState(title: title) {
            let controller = UIHostingController(rootView: NavigationStack {
                MediaCacheView(category: category, actions: mediaCacheActions(entries: entries, open: open))
            })
            return CatalogControllerHost(controller, height: 500)
        }
    }

    private static func mediaCacheActions(
        entries: @escaping @Sendable () async -> [MediaFileCache.Entry],
        open: (@Sendable (MediaFileCache.Entry.ID) async throws -> URL?)? = nil
    ) -> MediaCacheView.Actions {
        MediaCacheView.Actions(entries: entries, open: open ?? { id in
            URL.temporaryDirectory.appending(path: "CatalogMediaCache", directoryHint: .isDirectory).appending(fileName: SafeFileName(id))
        })
    }

    /// カタログ用の場所に画像を書き、並べるファイルにする。開くときはコピーを作らず、書いたファイルをそのまま渡す。
    @MainActor
    private static func catalogMediaFiles() -> [MediaFileCache.Entry] {
        let folder = URL.temporaryDirectory.appending(path: "CatalogMediaCache", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let colors: [UIColor] = [.systemRed, .systemBlue, .systemOrange, .systemPurple, .systemGreen, .systemTeal, .systemPink]
        let sizes = [CGSize(width: 1_200, height: 800), CGSize(width: 600, height: 1_400), CGSize(width: 800, height: 800)]
        var entries = colors.enumerated().compactMap { index, color -> MediaFileCache.Entry? in
            let name = "\(index + 1).jpg"
            let file = folder.appending(fileName: SafeFileName(name))
            guard let data = DummyMedia.image(size: sizes[index % sizes.count], color: color, label: "\(index + 1)").jpegData(compressionQuality: 0.8),
                  (try? data.write(to: file)) != nil
            else { return nil }
            return MediaFileCache.Entry(id: name, file: file, size: data.count, lastUsed: Date(timeIntervalSince1970: 0))
        }
        let other = folder.appending(fileName: SafeFileName("notes.bin"))
        if (try? Data(repeating: 0, count: 64).write(to: other)) != nil {
            entries.append(MediaFileCache.Entry(id: "notes.bin", file: other, size: 64, lastUsed: Date(timeIntervalSince1970: 0)))
        }
        return entries
    }

    @MainActor
    private static func state(
        _ title: String,
        breakdown: StorageBreakdown = small,
        measure: (@Sendable () async -> StorageBreakdown)? = nil,
        removing: StorageBreakdown.Category? = nil,
        removeError: String? = nil
    ) -> CatalogState {
        CatalogState(title: title) {
            let actions = StorageView.Actions(measure: measure ?? { breakdown }, remove: { _ in }, mediaFiles: mediaCacheActions(entries: { [] }), mediaPrefetch: mediaCacheActions(entries: { [] }))
            let controller = UIHostingController(rootView: NavigationStack {
                StorageView(actions: actions, removing: removing, removeError: removeError)
            })
            return CatalogControllerHost(controller, height: 1_100)
        }
    }
}
#endif
