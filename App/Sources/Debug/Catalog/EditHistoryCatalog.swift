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
            state("今の投稿を一覧で開いた（今の版だけ外れ、過去の版は閲覧注意で覆う）", choice: .revealed, [
                revision("<p>写真を撮った</p>", sensitive: true, media: [blue]),
                revision("<p>写真を撮った。もう1枚</p>", sensitive: true, media: [blue, green]),
            ]),
            state("今の投稿を一覧で隠した（閲覧注意のない過去の版と外した画像も覆う）", choice: .hidden, [
                revision("<p>写真を撮った</p>", media: [blue, green]),
                revision("<p>写真を撮った。1枚にした</p>", media: [blue]),
            ]),
            state("フィルターに一致した（過去の版と外した画像もフィルターで覆う）", filterTitles: ["ネタバレ"], [
                revision("<p>映画を観た</p>", sensitive: true, media: [blue, green]),
                revision("<p>映画を観た。最後が良かった</p>", media: [blue]),
            ]),
            state("フィルターに一致し、一覧で開いた（今の版だけ外れる）", choice: .revealed, filterTitles: ["ネタバレ"], [
                revision("<p>映画を観た</p>", media: [blue]),
                revision("<p>映画を観た。最後が良かった</p>", media: [blue, green]),
            ]),
            state("フィルターの名前が長い", filterTitles: ["ネタバレになりそうな映画とドラマの話", "食べ物"], [
                revision("<p>写真</p>", media: [blue]),
                revision("<p>写真を足した</p>", media: [blue, green]),
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

    /// 一覧で、今の投稿の添付ファイルを開いたか隠したか。
    private enum Choice {
        case revealed
        case hidden
    }

    @MainActor
    private static func state(_ title: String, choice: Choice? = nil, filterTitles: [String] = [], _ revisions: [StatusRevision]) -> CatalogState {
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
            // 画面と同じく、今の投稿の覆いは一覧の選択で決める。
            var covers = MediaCovers()
            let latest = latestStatus(of: revisions)
            switch choice {
            case .revealed: covers.reveal(latest)
            case .hidden: covers.hide(latest)
            case nil: break
            }
            let column = UIStackView()
            column.axis = .vertical
            for content in builder.contents(for: history, language: "ja", latestCover: covers.cover(for: latest, filterTitles: filterTitles), isHidden: covers.isHidden(statusID: latest.id), filterTitles: filterTitles, revealedEditNumbers: []) {
                let view = EditHistoryEntryView(mediaImages: AppDependencies.mediaImages)
                view.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
                view.apply(content)
                column.addArrangedSubview(view)
            }
            return CatalogFrame.bordered(column)
        }
    }

    /// 今の投稿。覆うかを決めるところだけを、最後の版に合わせる。
    private static func latestStatus(of revisions: [StatusRevision]) -> Status {
        let last = revisions.last
        return Status(
            id: "edit-history",
            createdAt: .now,
            account: author,
            content: last?.content ?? "",
            spoilerText: last?.spoilerText ?? "",
            url: nil,
            mediaAttachments: last?.mediaAttachments ?? [],
            sensitive: last?.sensitive ?? false
        )
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
