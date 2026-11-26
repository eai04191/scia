import os

/// 読んだ自分のフィルターのリスト。ハッシュタグのメニューの「ミュート」を、キャッシュしたリストでその場で組むために使う。
/// フィルターは1回のリクエストで全部読めるので、再読み込みも1回で済む。
public typealias ServerFilterCache = LatestValueCache<[ServerFilter]>

/// サーバーから読んだ自分の設定（フィルターのリストなど）をキャッシュしておく。ログインしている間だけ持つ。
/// メニューを、キャッシュした値でその場で組むために使う。読み込み中の行を出してから中身を差し替えると、開く途中のサブメニューの動きが崩れるため。
@MainActor
public final class LatestValueCache<Value: Sendable> {
    public typealias Fetch = @Sendable () async throws -> Value

    private let fetch: Fetch
    /// 読めなかったときのログに出す、何を読んでいるかの名前。
    private let label: String
    /// キャッシュした値。まだ読めていなければnil。
    public private(set) var value: Value?
    /// 読めて`value`が変わったときに呼ぶ。同じ値を画面にも出しているとき（「フォロー中のハッシュタグ」の画面）に、メニューを開いたときの再読み込みも届けるために使う。
    /// 後から始めた再読み込みに追い越された応答と、読めなかったときは呼ばない。
    public var onValueChange: ((Value) -> Void)?
    /// いちばん新しく始めた再読み込み。読み終えたら外す。
    private var task: Task<Void, Never>?
    /// 再読み込みを始めた回数。後から始めた再読み込みがあれば、先に始めた再読み込みの応答で古い値に戻さない。
    private var generation = 0
    /// いちばん新しく始めた再読み込みの結果。待っている側は、自分より後に始めた再読み込みの結果を受け取る。
    private var latestResult: (generation: Int, result: Result<Value, any Error>)?
    private var isClosed = false
    private let logger = SciaLog.logger(category: "latestValueCache")

    public init(label: String, fetch: @escaping Fetch) {
        self.label = label
        self.fetch = fetch
    }

    /// 再読み込みしていなければ、通信の目的を`purpose`と名乗って再読み込みする。メニューを開いたときに呼び、別の端末やwebで変えたものを次に開いたときから反映する。
    public func refresh(purpose: RequestPurpose) {
        guard task == nil else { return }
        reload(purpose: purpose)
    }

    /// 再読み込みしている途中でも、通信の目的を`purpose`と名乗って新しく再読み込みする。変えたあとに呼び、変える前に始めた再読み込みの応答で古い値に戻さない。
    /// 読めなかったら、キャッシュした値を残してログに残す。
    public func reload(purpose: RequestPurpose) {
        guard !isClosed else { return }
        generation += 1
        let started = generation
        let fetch = fetch
        let label = label
        task = Task {
            let result = await Result { try await RequestPurpose.$current.withValue(purpose) { try await fetch() } }
            guard generation == started else { return }
            switch result {
            case .success(let loaded):
                value = loaded
                onValueChange?(loaded)
            case .failure(let error): logger.error("\(label, privacy: .public) load failed: \(SciaLog.describe(error), privacy: .public)")
            }
            latestResult = (started, result)
            task = nil
        }
    }

    /// いちばん新しい再読み込みで読んだ値。再読み込みしている途中なら、待っている間に始めた再読み込みも含めて、いちばん新しいものを待つ。
    /// まだ一度も再読み込みしていなければ読む。いちばん新しい再読み込みに失敗していたら、キャッシュした値があっても投げる。
    public func latest() async throws -> Value {
        if task == nil, latestResult == nil {
            // 待っている呼び出し側が名乗った目的で読む。
            reload(purpose: try RequestPurpose.declared())
        }
        while let task {
            await task.value
        }
        guard let latestResult else { throw CancellationError() }
        return try latestResult.result.get()
    }

    /// 走っている再読み込みを止め、以後は読まない。ログアウトやアカウントの切り替えのあとに、前のアカウントのトークンで通信し続けないため。
    public func close() {
        isClosed = true
        task?.cancel()
    }
}
