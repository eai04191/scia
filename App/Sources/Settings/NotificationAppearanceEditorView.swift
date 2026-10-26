import SciaCore
import SwiftUI
import UIKit

/// 「通知の見た目」。上にプレビューを固定し、下に通知のために足す部品ごとの項目を、通知の行の上から下への並びで置く。
/// 項目を触っている間は、プレビューでその場所を示す。プレビューの部品をタップすると、その部品の項目を開く。
/// メンションなどの投稿の部品は「投稿の見た目」で決めるので、ここには置かない。
struct NotificationAppearanceEditorView: View {
    @Bindable var settings: AppSettings
    @State private var samples: NotificationAppearanceSamples
    /// 画像が届いたら、プレビューを描き直す。名前の前のアイコンとカスタム絵文字は、描いた時点の画像で組むため。
    @State private var emojiArrivals = EmojiArrivals(store: AppDependencies.emojiImages)
    @State private var avatarArrivals = AvatarArrivals(store: AppDependencies.avatarImages)
    /// 最後に触った項目。プレビューでその場所を示す。
    @State private var focused: AppearanceValue?
    @State private var expandedGroups: Set<AppearanceGroup.ID> = []
    /// プレビューでタップした部品の項目。リストをそこまでスクロールする。項目を触ったときは、押している行を動かさないようスクロールしない。
    @State private var scrollTarget: AppearanceGroup.ID?
    @State private var confirmsReset = false
    @Environment(\.colorScheme) private var colorScheme

    init(settings: AppSettings, tuning: TuningStore = AppDependencies.tuning, now: () -> Date = AppDependencies.now) {
        self.settings = settings
        _samples = State(initialValue: NotificationAppearanceSamples(settings: settings, tuning: tuning, now: now()))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                AppearancePreview(
                    configurations: samples.configurations(colorScheme: colorScheme, revision: revision),
                    highlight: focused.flatMap(AppearanceHighlight.init),
                    onSelectPart: select,
                    onTapHighlight: { focused = nil },
                    showsSeparators: settings.showsSeparators
                )
                .frame(height: geometry.size.height * 0.42)
                Divider()
                ScrollViewReader { proxy in
                    Form {
                        // 開いていない部品は1行に縮むので、1つのセクションに並べて全体を見渡せるようにする。
                        Section {
                            ForEach(NotificationAppearanceCatalog.groups) { group in
                                DisclosureGroup(isExpanded: expansion(of: group)) {
                                    ForEach(group.values) { item in
                                        AppearanceValueRow(
                                            item: item,
                                            settings: settings,
                                            isFocused: focused == item,
                                            onFocus: { focused = item },
                                            onToggleFocus: { focused = focused == item ? nil : item }
                                        )
                                    }
                                } label: {
                                    GroupLabel(title: group.title, isModified: group.values.contains(where: settings.isModified))
                                }
                                .id(group.id)
                            }
                        } footer: {
                            Text("プレビューの部品をタップすると、その部品の項目を開きます。項目の名前やプレビューをもう一度タップすると、場所を示すのをやめます。")
                        }
                        Section {
                            Button("すべて既定に戻す", role: .destructive) { confirmsReset = true }
                                .disabled(!settings.isNotificationAppearanceModified)
                        } footer: {
                            Text("メンションなどの投稿の見た目と、行の余白やアイコンの列の幅は「投稿の見た目」に従います。文字の大きさは、投稿の本文との差を保ちます。")
                        }
                    }
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation { proxy.scrollTo(target, anchor: .top) }
                        scrollTarget = nil
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
        .navigationTitle("通知の見た目")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("通知の見た目をすべて既定に戻しますか？", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("既定に戻す", role: .destructive) {
                settings.resetNotificationAppearance()
                focused = nil
            }
        }
    }

    /// プレビューを描き直すきっかけ。見本の組み立ては設定を直接読むので、読んだ値が変わったら描き直すよう、ここで読んでおく。
    /// メンションなどの投稿は「投稿の見た目」の数値でも描くので、数値はまとめて読む。
    private var revision: Int {
        var hasher = Hasher()
        hasher.combine(emojiArrivals.count)
        hasher.combine(avatarArrivals.count)
        hasher.combine(settings.appearanceValues)
        return hasher.finalize()
    }

    private func expansion(of group: AppearanceGroup) -> Binding<Bool> {
        Binding {
            expandedGroups.contains(group.id)
        } set: { isExpanded in
            if isExpanded {
                expandedGroups.insert(group.id)
            } else {
                expandedGroups.remove(group.id)
            }
        }
    }

    /// プレビューでタップした部品のうち、項目のある最も小さい部品の項目を開き、その場所を示す。
    /// 部品のない場所や、いま示している項目の部品をタップしたときは、示すのをやめる。示した帯で、確かめたい見た目が隠れることがあるため。
    private func select(_ parts: [AppearancePreviewPart]) {
        guard let item = parts.lazy.compactMap(AppearanceHighlight.notificationItem(selectedBy:)).first,
              let group = NotificationAppearanceCatalog.groups.first(where: { $0.values.contains(item) }),
              focused != item else {
            focused = nil
            return
        }
        expandedGroups.insert(group.id)
        focused = item
        scrollTarget = group.id
    }
}

/// アイコンの画像が届いた回数。数が変わると、読んだ画面が描き直す。
@MainActor
@Observable
final class AvatarArrivals {
    private(set) var count = 0

    init(store: AvatarImageStore) {
        store.addListener(owner: self) { [weak self] _ in
            self?.count += 1
        }
    }
}

/// 「通知の見た目」のプレビューに並べる見本の通知。調整できる部品がどれかの行に出るように組む。
/// 一覧と同じ組み立て（`TimelineViewController`）を通し、画像は通信しないよう、アプリのアイコンから作ったものを使う。
@MainActor
struct NotificationAppearanceSamples {
    private let timeline: TimelineViewController
    private let now: Date

    init(settings: AppSettings, tuning: TuningStore, now: Date) {
        self.now = now
        timeline = TimelineViewController(texts: .notifications, refresh: {}, tuning: tuning, settings: settings)
        timeline.myAccountID = Self.myAccountID
        timeline.filterWarnings = FilterWarnings(filtering: StatusFiltering(context: .notifications, myAccountID: Self.myAccountID))
    }

    /// - Parameter revision: 描き直しのきっかけ。中身は使わない。
    func configurations(colorScheme: ColorScheme, revision _: Int) -> [any AppearancePreviewConfiguration] {
        let image = PreviewImages.cardURL(for: colorScheme == .dark ? .dark : .light)
        return notifications(image: image).compactMap { notification in
            timeline.contentConfiguration(for: notification, base: .cell()) as? any AppearancePreviewConfiguration
        }
    }

    private static let myAccountID = "preview-scia"

    private func notifications(image: URL?) -> [MastodonNotification] {
        let avatar = PreviewImages.avatarURL()
        let scia = Account(id: Self.myAccountID, username: "scia", acct: "scia", displayName: "Scia", avatar: avatar)
        let friend = Account(id: "preview-friend", username: "friend", acct: "friend@example.com", displayName: "ともだち", avatar: avatar)
        let others = ["さくら", "もみじ", "つばき"].enumerated().map { index, name in
            Account(id: "preview-other-\(index)", username: "other\(index)", acct: "other\(index)@example.com", displayName: name, avatar: avatar)
        }
        func attachment(_ id: String) -> MediaAttachment {
            MediaAttachment(id: id, type: .image, url: image, previewUrl: image, meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 1_200, height: 900)))
        }
        let date = now.addingTimeInterval(-600)
        let quoted = Status(id: "preview-quoted", createdAt: date, account: friend, content: "<p>引用した投稿です。</p>", spoilerText: "", url: nil)
        // 本文の行数とサムネイルと引用を示す行を見せるため、長い本文に画像を並べ、投稿を引用した自分の投稿にする。
        let reshown = Status(
            id: "preview-reshown",
            createdAt: date,
            account: scia,
            content: "<p>ブーストされた自分の投稿です。本文が長いときは、設定した行数で切ります。誰が何をしたかの行を主役にするため、本文は控えめな色で短く出します。添付ファイルは小さなサムネイルを1列に並べます。</p>",
            spoilerText: "",
            url: nil,
            mediaAttachments: [attachment("preview-reshown-1"), attachment("preview-reshown-2"), attachment("preview-reshown-3")],
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
        let favourited = Status(id: "preview-favourited", createdAt: date, account: scia, content: "<p>お気に入りに登録された自分の投稿です。</p>", spoilerText: "", url: nil)
        let mention = Status(
            id: "preview-mention",
            createdAt: date,
            account: friend,
            content: #"<p><span class="h-card"><a href="https://example.com/@scia" class="u-url mention">@<span>scia</span></a></span> メンションは投稿と同じ見た目で、名前の上の行だけを通知の項目で変えます。</p>"#,
            spoilerText: "",
            url: nil,
            mentions: [Mention(id: scia.id, username: scia.username, url: nil, acct: scia.acct)]
        )
        return [
            MastodonNotification(
                id: "preview-group", type: .favourite, createdAt: date, account: others[0], status: favourited,
                groupKey: "favourite-preview", notificationsCount: 5, sampleAccounts: others + [friend]
            ),
            MastodonNotification(id: "preview-reblog", type: .reblog, createdAt: date, account: friend, status: reshown),
            MastodonNotification(id: "preview-poll", type: .poll, createdAt: date, account: scia, status: polled),
            MastodonNotification(id: "preview-follow", type: .follow, createdAt: date, account: friend),
            MastodonNotification(id: "preview-mention", type: .mention, createdAt: date, account: friend, status: mention),
        ]
    }
}
