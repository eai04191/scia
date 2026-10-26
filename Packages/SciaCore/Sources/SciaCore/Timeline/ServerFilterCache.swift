import os

/// 読んだ自分のフィルターの一覧を覚えておく。ログインしている間だけ持つ。
/// ハッシュタグのメニューの「ミュート」を、覚えている一覧でその場で組むために使う。読み込み中の行を出してから中身を差し替えると、開く途中のサブメニューの動きが崩れるため。
/// 一覧は1回のリクエストで全部読めるので、読み直しも1回で済む。
@MainActor
public final class ServerFilterCache {
    public typealias Fetch = @Sendable () async throws -> [ServerFilter]

    private let fetch: Fetch
    /// 覚えている一覧。まだ読めていなければnil。
    public private(set) var filters: [ServerFilter]?
    /// いちばん新しく始めた読み直し。読み終えたら外す。
    private var task: Task<Void, Never>?
    /// 読み直しを始めた回数。後から始めた読み直しがあれば、先に始めた読み直しの応答で古い一覧に戻さない。
    private var generation = 0
    /// いちばん新しく始めた読み直しの結果。待っている側は、自分より後に始めた読み直しの結果を受け取る。
    private var latestResult: (generation: Int, result: Result<[ServerFilter], any Error>)?
    private var isClosed = false
    private let logger = SciaLog.logger(category: "serverFilterCache")

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// 読み直していなければ読み直す。メニューを開いたときに呼び、別の端末やwebで変えたフィルターを次に開いたときから反映する。
    public func refresh() {
        guard task == nil else { return }
        reload()
    }

    /// 読み直している途中でも、新しく読み直す。フィルターを変えたあとに呼び、変える前に始めた読み直しの応答で古い一覧に戻さない。
    /// 読めなかったら、覚えている一覧を残してログに残す。
    public func reload() {
        guard !isClosed else { return }
        generation += 1
        let started = generation
        task = Task {
            let result = await Result { try await fetch() }
            guard generation == started else { return }
            switch result {
            case .success(let loaded): filters = loaded
            case .failure(let error): logger.error("filters load failed: \(SciaLog.describe(error), privacy: .public)")
            }
            latestResult = (started, result)
            task = nil
        }
    }

    /// いちばん新しい読み直しで読んだ一覧。読み直している途中なら、待っている間に始めた読み直しも含めて、いちばん新しいものを待つ。
    /// まだ一度も読み直していなければ読む。いちばん新しい読み直しに失敗していたら、覚えている一覧があっても投げる。
    public func latest() async throws -> [ServerFilter] {
        if task == nil, latestResult == nil {
            reload()
        }
        while let task {
            await task.value
        }
        guard let latestResult else { throw CancellationError() }
        return try latestResult.result.get()
    }

    /// 走っている読み直しを止め、以後は読まない。ログアウトやアカウントの切り替えのあとに、前のアカウントのトークンで通信し続けないため。
    public func close() {
        isClosed = true
        task?.cancel()
    }
}
