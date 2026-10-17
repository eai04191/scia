#if DEBUG
import Foundation
import SciaCore
import SwiftUI
import UIKit

/// 「操作の状況」の一覧のシート。失敗を起こさずに、空のとき、件数が多いとき、文言が長いときを並べる。行を押しても何も起きない。
enum OperationStatusCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            state("空") { _ in },
            state("最近の失敗（投稿に結び付いたものと、結び付いていないもの）") { notices in
                notices.recordFailure(title: "ブーストを変更できませんでした", reason: ErrorPresentation(message: "サーバーに接続できませんでした。", code: "URLError -1004"), subject: subject(1))
                notices.recordFailure(title: "プロフィールを開けませんでした", reason: ErrorPresentation(message: "@nobody@example.comが見つかりませんでした。", code: nil))
                notices.recordFailure(title: "お気に入りを変更できませんでした", reason: badGateway, subject: subject(2))
            },
            state("進行中と最近の失敗") { notices in
                notices.update(.init(id: "download", title: "ダウンロード中", value: "42%", fraction: 0.42, subject: subject(3)), onStop: {})
                notices.update(.init(id: "upload", title: "アップロード中"))
                notices.recordFailure(title: "お気に入りを変更できませんでした", reason: badGateway, subject: subject(2))
            },
            state("進行中だけ（最近の失敗はない）") { notices in
                notices.update(.init(id: "download", title: "ダウンロード中", value: "42%", fraction: 0.42, subject: subject(3)), onStop: {})
            },
            state("ダウンロードがいくつも進行中（写真に足している間は止められない）") { notices in
                notices.update(.init(id: "download-1", title: "ダウンロード中", subject: subject(4)), onStop: {})
                notices.update(.init(id: "download-2", title: "ダウンロード中", value: "42%", fraction: 0.42, subject: subject(5)), onStop: {})
                notices.update(.init(id: "download-3", title: "ダウンロード中", value: "100%", fraction: 1, subject: subject(6)))
                notices.recordFailure(title: "動画を保存できませんでした", reason: ErrorPresentation(message: "インターネットに接続されていません。", code: "URLError -1009"), subject: subject(7))
            },
            state("進み具合が動く（10秒で満ちて、写真に足す間は止められない）") { notices in
                advance(notices, subject: subject(8))
            },
            state("進行中の長い文言") { notices in
                notices.update(.init(
                    id: "download",
                    title: "ダウンロード中",
                    value: "100%",
                    fraction: 1,
                    subject: OperationStatus.Subject(statusID: "long", displayedID: "long", url: nil, authorName: "とても長い表示名のアカウントで、名前だけで1行を使い切ってしまうかもしれない人", excerpt: "止めるボタンと並べたときに本文がどこで切れるかを確かめるための長い本文です。")
                ), onStop: {})
            },
            state("上限の\(OperationStatus.failureLimit)件") { notices in
                for index in 1...(OperationStatus.failureLimit + 5) {
                    notices.recordFailure(title: index.isMultiple(of: 2) ? "お気に入りを変更できませんでした" : "ブーストを変更できませんでした", reason: badGateway, subject: subject(index))
                }
            },
            state("長い文言") { notices in
                notices.recordFailure(
                    title: "長い文言のときに見出しがどこで折り返して、どこで切れるかを確かめるための失敗の見出し",
                    reason: ErrorPresentation(message: "長い理由のときに何行まで出して、どこで切るかを確かめるための理由の文です。サーバーが返した文言がとても長いこともあります。さらに続けて、4行を超えるかどうかを確かめます。もう少し続けます。", code: "HTTP 503"),
                    subject: OperationStatus.Subject(
                        statusID: "long",
                        displayedID: "long",
                        url: nil,
                        authorName: "とても長い表示名のアカウントで、名前だけで1行を使い切ってしまうかもしれない人",
                        excerpt: "長い本文の冒頭を2行で切るかを確かめるための本文です。改行を含む投稿も1行にまとめて出します。ここから先は切れて見えないはずの文です。"
                    )
                )
            },
        ]
    }

    /// 10秒で0%から100%まで進め、2秒止められない間をはさんで、また0%から繰り返す。一覧が消えたら止める。
    @MainActor
    private static func advance(_ notices: OperationStatus, subject: OperationStatus.Subject) {
        Task { @MainActor [weak notices] in
            var step = 0
            while let current = notices {
                movingStep(step, on: current, subject: subject)
                step = step >= 120 ? 0 : step + 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    @MainActor
    private static func movingStep(_ step: Int, on notices: OperationStatus, subject: OperationStatus.Subject) {
        let fraction = min(Double(step) / 100, 1)
        let activity = OperationStatus.Activity(id: "moving", title: "ダウンロード中", value: "\(Int(fraction * 100))%", fraction: fraction, subject: subject)
        if fraction < 1 {
            notices.update(activity, onStop: {})
        } else {
            notices.update(activity)
        }
    }

    private static let badGateway = ErrorPresentation(message: "サーバーかその手前で問題が起きています。しばらくしてからやり直してください。", code: "HTTP 502")

    private static func subject(_ index: Int) -> OperationStatus.Subject {
        OperationStatus.Subject(
            statusID: "catalog-\(index)",
            displayedID: "catalog-\(index)",
            url: nil,
            authorName: "カタログのアカウント",
            excerpt: "「操作の状況」の一覧を確かめるための投稿 \(index)。"
        )
    }

    @MainActor
    private static func state(_ title: String, fill: @escaping @MainActor (OperationStatus) -> Void) -> CatalogState {
        CatalogState(title: title) {
            // 時刻がそろうよう、記録した時刻を決めておく。
            let notices = OperationStatus { Date(timeIntervalSince1970: 1_790_000_000) }
            fill(notices)
            let controller = UIHostingController(rootView: OperationStatusView(notices: notices) { _ in })
            return CatalogControllerHost(controller, height: 480)
        }
    }
}
#endif
