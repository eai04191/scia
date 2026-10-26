#if DEBUG
import SciaCore
import SwiftUI
import UIKit

/// 設定のストレージの画面。ファイルを測ったり消したりせずに、測っている途中、消している途中、消せなかったとき、GBの大きさを並べる。消すを押しても何も消さない。
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
            state("GBの大きさ", breakdown: large),
        ]
    }

    private static let small = StorageBreakdown(
        items: [
            .init(category: .mediaFiles, bytes: 8_800_000, removableBytes: 8_800_000),
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

    private static let large = StorageBreakdown(
        items: [
            .init(category: .mediaFiles, bytes: 157_286_400, removableBytes: 157_286_400),
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

    @MainActor
    private static func state(
        _ title: String,
        breakdown: StorageBreakdown = small,
        measure: (@Sendable () async -> StorageBreakdown)? = nil,
        removing: StorageBreakdown.Category? = nil,
        removeError: String? = nil
    ) -> CatalogState {
        CatalogState(title: title) {
            let actions = StorageView.Actions(measure: measure ?? { breakdown }, remove: { _ in })
            let controller = UIHostingController(rootView: NavigationStack {
                StorageView(actions: actions, removing: removing, removeError: removeError)
            })
            return CatalogControllerHost(controller, height: 1_100)
        }
    }
}
#endif
