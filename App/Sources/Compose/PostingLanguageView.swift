import SciaCore
import SwiftUI
import UIKit

/// 投稿の言語を選ぶシート。いちばん上に既定の言語、その下に最近選んだ言語とすべての言語を並べ、名前で探せる。決まりはdocs/compose.mdの「投稿の言語」にある。
/// 選んだら`onSelect`を呼んでから`close`で閉じさせる。
struct PostingLanguageView: View {
    @Bindable var picker: PostingLanguagePicker
    let onSelect: @MainActor (PostingLanguageRow) -> Void
    let close: @MainActor () -> Void
    @Environment(\.locale) private var locale
    /// 「読み直す」で増やし、読み込みをやり直させる。読み込みはシートの`task`で走らせ、閉じたら止まるようにする。
    @State private var loadGeneration = 0

    var body: some View {
        NavigationStack {
            List {
                ForEach(picker.sections(locale: locale), id: \.kind) { section in
                    Section {
                        if section.kind == .all {
                            allLanguagesStatus
                        }
                        ForEach(section.rows) { row in
                            languageRow(row)
                        }
                    } header: {
                        Text(Self.title(of: section.kind))
                    }
                }
            }
            .searchable(text: $picker.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "言語の名前")
            .topEdgeEffectHiddenOnMac()
            .navigationTitle("投稿の言語")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", role: .cancel) { close() }
                }
            }
            .task(id: loadGeneration) {
                await picker.loadLanguages()
            }
        }
    }

    private static func title(of kind: PostingLanguageSection.Kind) -> String {
        switch kind {
        case .defaultLanguage: "アカウントの既定"
        case .recent: "最近選んだ言語"
        case .all: "すべての言語"
        }
    }

    /// すべての言語のまとまりの、読み込み中と読めなかったときの表示。既定と最近選んだ言語は、読めなくても選べる。
    @ViewBuilder
    private var allLanguagesStatus: some View {
        switch picker.languages {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
        case .failed(let error):
            VStack(alignment: .leading, spacing: 4) {
                Text("言語の一覧を読み込めませんでした")
                Text(ErrorPresentation(error).message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("読み直す") {
                loadGeneration += 1
            }
        case .loaded:
            EmptyView()
        }
    }

    private func languageRow(_ row: PostingLanguageRow) -> some View {
        let isSelected = row.code == picker.selectedCode
        return Button {
            onSelect(row)
            close()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.code == nil ? "サーバーに任せる" : row.name)
                    if row.code == nil {
                        Text("既定の言語を決めていないため、送らずにサーバーが決めます")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let code = row.code {
                    Text(PostingLanguage.badgeText(of: code))
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                if isSelected {
                    // 行の文字を普通の色にするため、ボタンのtintを変えている。チェックマークはアプリのアクセントの色で描く。
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        // Listの中のボタンは文字がすべてtintの色になるため、行は普通の文字の色で出す。
        .tint(.primary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 投稿欄が言語を選ぶシートに渡すもの。
struct PostingLanguageSource {
    /// 選んだ言語を覚える先。覚えないならnil。
    var recent: RecentPostingLanguages?
    /// サーバーが受け付ける言語を読む。
    var load: @Sendable () async throws -> [PostingLanguage]

    /// 言語の一覧を読めない投稿欄。テストで使う。
    static let unavailable = PostingLanguageSource(recent: nil) { throw CancellationError() }
}

/// サーバーが受け付ける言語を、読めたら覚えておく。言語の一覧はサーバーの版でしか変わらないので、シートを開くたびに読み直さない。
/// 読めなかったときは覚えず、次に開いたときに読み直す。
@MainActor
final class PostingLanguageCache {
    private let fetch: @Sendable () async throws -> [PostingLanguage]
    private var loaded: [PostingLanguage]?

    init(fetch: @escaping @Sendable () async throws -> [PostingLanguage]) {
        self.fetch = fetch
    }

    func languages() async throws -> [PostingLanguage] {
        if let loaded { return loaded }
        let languages = try await fetch()
        loaded = languages
        return languages
    }
}

/// 投稿欄の項目「言語」から重ねる、言語を選ぶシート。選んでも、キャンセルしても、下へスワイプしても、出した側から閉じられても、閉じたら`onClose`を1回呼ぶ。
final class PostingLanguageSheet: UIHostingController<PostingLanguageView> {
    private let onClose: () -> Void
    private var hasClosed = false
    /// 自分の`dismiss`で閉じている。`viewDidDisappear`は`dismiss`の完了より先に呼ばれるので、そこで知らせると、決めたことより先に閉じたことを知らせてしまう。
    private var isDismissingItself = false

    init(picker: PostingLanguagePicker, onSelect: @escaping @MainActor (PostingLanguageRow) -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        // 閉じる処理は自分を参照するため、作り終えてから入れ直す。
        super.init(rootView: PostingLanguageView(picker: picker, onSelect: onSelect, close: {}))
        rootView = PostingLanguageView(picker: picker, onSelect: onSelect) { [weak self] in self?.dismiss(animated: true) }
        // 言語は多いので、低い段でも数行見せ、引き上げるか探すと上まで広げる。
        sheetPresentationController?.detents = [.medium(), .large()]
        sheetPresentationController?.prefersGrabberVisible = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        presentationController?.delegate = self
    }

    /// 選んだとき、キャンセルしたとき、コードから閉じたとき。閉じ終わってから知らせる。
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        isDismissingItself = true
        super.dismiss(animated: flag) {
            completion?()
            self.notifyClosed()
        }
    }

    /// 出した側の画面からまとめて閉じられたとき（デバッグのリセットなど）。自分の`dismiss`も下へのスワイプの知らせも通らないので、消えたところで知らせる。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !isDismissingItself, isBeingDismissed || presentingViewController == nil {
            notifyClosed()
        }
    }

    private func notifyClosed() {
        guard !hasClosed else { return }
        hasClosed = true
        onClose()
    }
}

extension PostingLanguageSheet: UIAdaptivePresentationControllerDelegate {
    /// 下へスワイプして閉じたとき。
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        notifyClosed()
    }
}
