import SciaCore
import SwiftUI
import UIKit

/// 「通知の見た目」。上にプレビューを固定し、下に通知のために足す部品ごとの分類を、通知の行の上から下への並びで置く。
/// 分類を押すと、その分類の画面（`NotificationAppearanceGroupEditorView`）を重ねる。
/// メンションなどの投稿の部品は「投稿の見た目」で決めるので、ここには置かない。プレビューの決まりは「投稿の見た目」と同じで、docs/appearance.mdにある。
struct NotificationAppearanceEditorView: View {
    @Bindable var settings: AppSettings
    @State private var samples: NotificationAppearanceSamples
    /// 開いたときに重ねておく分類の画面。
    @State private var opened: AppearanceGroup.ID?
    @State private var confirmsReset = false
    /// すべて既定に戻した回数。戻すと値がまとめて変わるので、プレビューの高さを合わせ直す。
    @State private var resets = 0

    /// - Parameter group: 開いたときに重ねておく分類の画面。
    init(settings: AppSettings, opening group: AppearanceGroup.ID? = nil, tuning: TuningStore = AppDependencies.tuning, now: () -> Date = AppDependencies.now) {
        self.settings = settings
        _samples = State(initialValue: NotificationAppearanceSamples(settings: settings, tuning: tuning, now: now()))
        _opened = State(initialValue: group)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                FittedAppearancePreview(
                    timeline: samples.timeline,
                    entries: samples.entries(groups: []),
                    heightLimit: geometry.size.height * AppearanceGroupEditorView.previewHeightLimit,
                    fitRevision: resets
                )
                Divider()
                Form {
                    Section {
                        ForEach(groups) { group in
                            NavigationLink {
                                NotificationAppearanceGroupEditorView(group: group, settings: settings)
                            } label: {
                                GroupLabel(title: group.title, isModified: group.values.contains(where: settings.isModified))
                            }
                        }
                    }
                    Section {
                        Button("すべてデフォルトに戻す", role: .destructive) { confirmsReset = true }
                            .disabled(!settings.isNotificationAppearanceModified)
                    } footer: {
                        Text("メンションなどの投稿の見た目と行の余白やアイコンの列の幅は、「表示」の「投稿」に従います。文字の大きさは投稿の本文との差を保ちます。")
                    }
                }
            }
        }
        .navigationDestination(item: $opened) { id in
            if let group = groups.first(where: { $0.id == id }) {
                NotificationAppearanceGroupEditorView(group: group, settings: settings)
            }
        }
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("通知の見た目をすべてデフォルトに戻しますか？", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("デフォルトに戻す", role: .destructive) {
                settings.resetNotificationAppearance()
                resets += 1
            }
        }
    }

    private var groups: [AppearanceGroup] {
        NotificationAppearanceCatalog.groups
    }
}

/// 「通知の見た目」の、1つの分類の画面。上にその分類の見本を固定し、下にその分類の項目を置く。
/// 最後に触った項目にしか要らない見本は、触っている間だけプレビューに足す。
struct NotificationAppearanceGroupEditorView: View {
    let group: AppearanceGroup
    @Bindable var settings: AppSettings
    @State private var samples: NotificationAppearanceSamples
    /// 最後に触った項目。
    @State private var focused: AppearanceValue?

    init(group: AppearanceGroup, settings: AppSettings, tuning: TuningStore = AppDependencies.tuning, now: () -> Date = AppDependencies.now) {
        self.group = group
        self.settings = settings
        _samples = State(initialValue: NotificationAppearanceSamples(settings: settings, tuning: tuning, now: now()))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                FittedAppearancePreview(
                    timeline: samples.timeline,
                    entries: samples.entries(groups: [group.id], focus: focused),
                    heightLimit: geometry.size.height * AppearanceGroupEditorView.previewHeightLimit
                )
                Divider()
                Form {
                    ForEach(group.values) { item in
                        AppearanceValueRow(
                            item: item,
                            settings: settings,
                            isFocused: focused == item,
                            onFocus: { focused = item },
                            onToggleFocus: { focused = focused == item ? nil : item }
                        )
                    }
                }
            }
        }
        .toolbar {
            // 数字のキーボードには確定のキーがないため、閉じて打った値を確定するボタンを置く。
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 「通知の見た目」のプレビューに並べる見本の通知。調整できる部品がどれかの行に出るように組む。決まりはdocs/appearance.mdの「プレビュー」にある。
/// タイムライン（`TimelineViewController`）に並べて描き、画像は通信しないよう、アプリのアイコンから作ったものと同梱した写真を使う。
@MainActor
struct NotificationAppearanceSamples {
    /// 見本を並べるタイムライン。見本を組むのにも、プレビューに置いて見せるのにも使う。1つの画面に1つずつ置く。
    let timeline: TimelineViewController
    private let notifications: [MastodonNotification]

    init(settings: AppSettings, tuning: TuningStore, now: Date) {
        timeline = .appearancePreview(texts: .notifications, filterContext: .notifications, myAccountID: Self.myAccountID, tuning: tuning, settings: settings)
        notifications = Self.notifications(date: now.addingTimeInterval(-600))
    }

    /// プレビューのタイムラインに並べる見本。
    /// - Parameters:
    ///   - groups: 見本を出す分類。渡すと、その分類の見本（`sampleIDs(for:focus:)`）だけを返す。nilならすべての見本を返す。
    ///   - focus: 触っている項目。`groups`を渡したとき、その項目にしか要らない見本を足す。
    func entries(groups: Set<AppearanceGroup.ID>? = nil, focus: AppearanceValue? = nil) -> [TimelineEntry] {
        let shown = groups.map { Self.sampleIDs(for: $0, focus: focus) }
        return notifications
            .filter { shown?.contains($0.id) ?? true }
            .map { .notification($0) }
    }

    /// 見本の行の中身。テストで、見本の部品の位置を測るのに使う。
    func configurations(groups: Set<AppearanceGroup.ID>? = nil, focus: AppearanceValue? = nil) -> [any UIContentConfiguration] {
        entries(groups: groups, focus: focus).compactMap { entry in
            guard case .notification(let notification) = entry else { return nil }
            return timeline.contentConfiguration(for: notification, base: .cell())
        }
    }

    /// 分類の見本の通知のID。分類ごとの見本に、触っている項目にしか要らない見本を足す。分類が空なら、分類を並べた画面に出す部品の少ない通知を1件だけにする。
    static func sampleIDs(for groups: Set<AppearanceGroup.ID>, focus: AppearanceValue?) -> Set<String> {
        let names = groups.isEmpty ? ["follow"] : groups.flatMap { groupSamples[$0] ?? [] } + focusSamples(focus)
        return Set(names.map { "preview-\($0)" })
    }

    /// 分類ごとに出す見本。その分類の項目が効く部品の出る、なるべく小さい通知を選び、既定の設定では見本の枠に収まるようにする。
    /// 種類の記号の文字の列とのすき間は、メンションなどの名前の上の行の記号にも効くので、メンションも出す。
    private static let groupSamples: [AppearanceGroup.ID: [String]] = [
        "group": ["group"],
        "header": ["follow"],
        "symbol": ["follow", "mention"],
        "account": ["follow"],
        "quoted": ["reblog"],
        "context": ["mention"],
    ]

    /// 分類のうち一部の項目にしか要らない見本。本文と投票のあいだは、添付ファイルと投票を同じ投稿に付けられないので、投票の通知を触っている間だけ出す。
    private static func focusSamples(_ focus: AppearanceValue?) -> [String] {
        switch focus {
        case NotificationAppearanceCatalog.quotedPollSpacing: ["poll"]
        default: []
        }
    }

    private static let myAccountID = "preview-scia"

    private static func notifications(date: Date) -> [MastodonNotification] {
        let avatar = PreviewImages.avatarURL()
        let scia = Account(id: myAccountID, username: "scia", acct: "scia", displayName: "Scia", avatar: avatar)
        let friend = Account(id: "preview-friend", username: "friend", acct: "friend@example.com", displayName: "ともだち", avatar: avatar)
        let others = ["さくら", "もみじ", "つばき"].enumerated().map { index, name in
            Account(id: "preview-other-\(index)", username: "other\(index)", acct: "other\(index)@example.com", displayName: name, avatar: avatar)
        }
        func photo(_ photo: PreviewPhoto) -> MediaAttachment {
            let url = PreviewImages.photoURL(photo)
            return MediaAttachment(id: photo.rawValue, type: .image, url: url, previewUrl: url, meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 800, height: 800)))
        }
        // サムネイル同士のすき間が見えるよう、違う写真を2枚付ける。同じ人の写真にし、クレジットを1行に収める。
        let photos: [PreviewPhoto] = [.gridFirst, .gridSecond]
        let quoted = Status(id: "preview-quoted", createdAt: date, account: friend, content: "<p>引用した投稿です。</p>", spoilerText: "", url: nil)
        // 本文の行数とサムネイルと引用を示す行を見せるため、長い本文に画像を並べ、投稿を引用した自分の投稿にする。
        // 写真のクレジットは、本文を設定した行数で切っても見えるよう、本文の先頭に書く。
        let reshown = Status(
            id: "preview-reshown",
            createdAt: date,
            account: scia,
            content: PreviewPhoto.credit(photos) + "<p>ブーストされた自分の投稿です。本文が長いときは設定した行数で切ります。誰が何をしたかの行を主役にするため、本文は控えめな色で短く出します。添付ファイルは小さなサムネイルを1列に並べます。</p>",
            spoilerText: "",
            url: nil,
            mediaAttachments: photos.map(photo),
            quote: Quote(state: "accepted", quotedStatus: quoted)
        )
        let poll = Poll(
            id: "preview-poll",
            expiresAt: date,
            expired: true,
            multiple: false,
            votesCount: 12,
            options: [Poll.Option(title: "円", votesCount: 7), Poll.Option(title: "角丸の四角", votesCount: 5)]
        )
        let polled = Status(id: "preview-polled", createdAt: date, account: scia, content: "<p>アイコンの形はどちらが好きですか？</p>", spoilerText: "", url: nil, poll: poll)
        let mention = Status(
            id: "preview-mentioning",
            createdAt: date,
            account: friend,
            content: #"<p><span class="h-card"><a href="https://example.com/@scia" class="u-url mention">@<span>scia</span></a></span> メンションです。</p>"#,
            spoilerText: "",
            url: nil,
            mentions: [Mention(id: scia.id, username: scia.username, url: nil, acct: scia.acct)]
        )
        return [
            // 分類を並べた画面に出す、部品の少ない通知。誰が何をしたかの行と、種類の記号と、ハンドルを見せる。
            MastodonNotification(id: "preview-follow", type: .follow, createdAt: date, account: friend),
            // まとめた通知のアイコンを見せる、誰が何をしたかの行だけのまとめた通知。
            MastodonNotification(
                id: "preview-group", type: .follow, createdAt: date, account: others[0],
                groupKey: "follow-preview", notificationsCount: 5, sampleAccounts: others + [friend]
            ),
            MastodonNotification(id: "preview-reblog", type: .reblog, createdAt: date, account: friend, status: reshown),
            MastodonNotification(id: "preview-poll", type: .poll, createdAt: date, account: scia, status: polled),
            MastodonNotification(id: "preview-mention", type: .mention, createdAt: date, account: friend, status: mention),
        ]
    }
}
