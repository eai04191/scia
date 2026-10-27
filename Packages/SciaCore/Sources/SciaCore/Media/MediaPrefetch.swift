public import Foundation

/// ビューアで開く画像の先読み（docs/image-loading.mdの「ビューアで開く画像の先読み」）。
public enum MediaPrefetch {
    /// ビューアで画像を開いたときに読む元の画像のURL。自分のサーバーが持っていなければ、他のサーバーの元の画像を読む。
    public static func viewerImageURL(of attachment: MediaAttachment) -> URL? {
        attachment.url ?? attachment.remoteUrl
    }

    /// 先読みする画像のURLを、並んでいる順に重ねずに並べる。画像のほかの種類は、ビューアが開いてから少しずつ読むので含めない。
    public static func urls(of attachments: some Sequence<MediaAttachment>) -> [URL] {
        var seen: Set<URL> = []
        return attachments.filter { $0.type == .image }.compactMap(viewerImageURL(of:)).filter { seen.insert($0).inserted }
    }
}

/// 先読みするものを、並べた順に1つずつ読む。並びを差し替えると、並びから外れたものの読み込みを止め、残りを先頭から読む。
/// まとめて読むと、サーバーの制限（Mastodonの`/media_proxy`はIPごと）に当たり、一覧に描く画像まで止まってしまうため、同時には1つしか読まない。
/// 読む処理は持ち主（`TaskScope`）で始め、持ち主を閉じたら、読んでいる途中のものも残りも読まない。
@MainActor
public final class PrefetchQueue<Item: Hashable & Sendable> {
    private let scope: TaskScope
    private let load: @MainActor (Item) async -> Void
    private var pending: [Item] = []
    private var current: (item: Item, token: Int, task: Task<Void, Never>)?
    private var nextToken = 0

    /// - Parameters:
    ///   - scope: 読む処理の持ち主。ログアウトしたら閉じ、そのアカウントで見た画像を読まないようにする。
    ///   - load: 1つを読む。取り消されたら、読むのをやめて戻る。読めなくても投げずに戻る。
    public init(scope: TaskScope, load: @escaping @MainActor (Item) async -> Void) {
        self.scope = scope
        self.load = load
        // 走り出す前に閉じた処理は中身を動かさず、読み終えたことを知らせないため、閉じたときに空にする。
        scope.onClose { [weak self] in
            self?.current = nil
            self?.pending = []
        }
    }

    /// 読んでいる途中のものがあるか。止めたあとに何も残っていないことを、テストが確かめるのに使う。
    public var isLoading: Bool { current != nil }

    /// 読む並びを差し替える。読んでいる途中のものが新しい並びにあれば、止めずに読み終え、そのあとに残りを読む。
    public func replace(with items: [Item]) {
        if let current, !items.contains(current.item) {
            current.task.cancel()
            self.current = nil
        }
        pending = items.filter { $0 != current?.item }
        startNext()
    }

    private func startNext() {
        guard current == nil, !pending.isEmpty else { return }
        let item = pending.removeFirst()
        let token = nextToken
        nextToken += 1
        let load = load
        guard let task = scope.run({ [weak self] in
            await load(item)
            self?.finish(token)
        }) else {
            pending = []
            return
        }
        current = (item, token, task)
    }

    /// 取り消したあとに読み終えた古い処理が、差し替えたあとの読み込みを終わったことにしないよう、始めたときの番号で確かめる。
    private func finish(_ token: Int) {
        guard current?.token == token else { return }
        current = nil
        startNext()
    }
}
