#if DEBUG
import Foundation
import SciaCore
import UIKit

/// 編集履歴の版。画面と同じく`EditHistoryContentBuilder`を通すので、書体や余白はアプリの設定とチューニングに従う。
/// 実物で出すには、その形の編集を投稿に重ねる必要がある変更（添付ファイルの差し替え、投票の選択肢、書き直し）と、文字の長さで崩れうる形を並べる。
enum EditHistoryCatalog {
    private typealias Fixtures = CatalogFixtures

    private static let author = Fixtures.account(displayName: "カタログのアカウント", acct: "catalog@example.com")

    @MainActor
    static func states() -> [CatalogState] {
        let blue = Fixtures.attachment("blue", width: 1_200, height: 900, color: .systemBlue, description: "会議室")
        let green = Fixtures.attachment("green", width: 900, height: 1_200, color: .systemGreen)
        let video = Fixtures.attachment("video", type: .video, width: 1_280, height: 720, color: .systemPurple)
        let longDescription = String(repeating: "代替テキストが長く、何行にもわたるときの折り返しを確かめる。", count: 3)
        return [
            state("本文の単語の差し替えと追加", [
                revision("<p>明日の勉強会は14時からです。場所は会議室Bです</p>"),
                revision("<p>明日の勉強会は15時からです。場所はいつもの会議室Bです</p>"),
            ]),
            state("注意書きと閲覧注意を付けた（添付は覆う）", [
                revision("<p>写真を撮った</p>", media: [blue]),
                revision("<p>写真を撮った</p>", spoiler: "食べ物", sensitive: true, media: [blue]),
            ]),
            state("閲覧注意の画像を外し、閲覧注意も外した（外した画像は覆ったまま）", [
                revision("<p>写真</p>", sensitive: true, media: [blue, green]),
                revision("<p>写真</p>", media: [green]),
            ]),
            state("添付ファイルの追加、削除、代替テキストの変更、並べ替え", [
                revision("<p>写真</p>", media: [blue, video]),
                revision("<p>写真</p>", media: [green, blue.replacingDescription("会議室Bの入口")]),
            ]),
            state("代替テキストが長い", [
                revision("<p>写真</p>", media: [blue]),
                revision("<p>写真</p>", media: [blue.replacingDescription(longDescription)]),
            ]),
            state("投票を付けて、選択肢を変えた", [
                revision("<p>どれが好き？</p>"),
                revision("<p>どれが好き？</p>", poll: ["猫", "犬"]),
                revision("<p>どれが好き？</p>", poll: ["猫", "鳥"]),
            ]),
            state("大半を書き直した", [
                revision("<p>リリースは来週の水曜日を予定しています</p>"),
                revision("<p>延期します。詳しくは後で</p>"),
            ]),
            state("段落を分けた、引用にした", [
                revision("<p>猫と犬の話。続きは明日</p>"),
                revision("<p>猫と犬の話。</p><p>続きは明日</p>"),
                revision("<blockquote><p>猫と犬の話。</p></blockquote><p>続きは明日</p>"),
            ]),
            state("本文が長い", [
                revision("<p>" + String(repeating: "長い本文が何行にもわたるときの折り返しを確かめるための文。", count: 4) + "</p>"),
                revision("<p>" + String(repeating: "長い本文が何行にもわたるときの折り返しを確かめるための、直した文。", count: 4) + "</p>"),
            ]),
        ]
    }

    @MainActor
    private static func state(_ title: String, _ revisions: [StatusRevision]) -> CatalogState {
        CatalogState(title: title) {
            let tuning = AppDependencies.tuning
            let history = StatusEditHistory(
                revisions: revisions,
                mentions: [],
                tags: [],
                language: "ja",
                minimumUnchangedRatio: tuning.value(of: TuningCatalog.editHistoryMinimumUnchangedRatio)
            )
            let builder = EditHistoryContentBuilder(
                tuning: tuning,
                settings: AppDependencies.settings,
                emojiImages: AppDependencies.emojiImages,
                network: AppDependencies.network
            )
            let column = UIStackView()
            column.axis = .vertical
            for content in builder.contents(for: history, language: "ja", revealedEditNumbers: []) {
                let view = EditHistoryEntryView(mediaImages: AppDependencies.mediaImages)
                view.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
                view.apply(content)
                column.addArrangedSubview(view)
            }
            return CatalogFrame.bordered(column)
        }
    }

    /// 版ごとの日時は、古い版ほど前にする。
    private static func revision(
        _ content: String,
        spoiler: String = "",
        sensitive: Bool = false,
        media: [MediaAttachment] = [],
        poll: [String]? = nil
    ) -> StatusRevision {
        StatusRevision(
            content: content,
            spoilerText: spoiler,
            sensitive: sensitive,
            createdAt: .now.addingTimeInterval(-600),
            account: author,
            mediaAttachments: media,
            pollOptions: poll
        )
    }
}
#endif
