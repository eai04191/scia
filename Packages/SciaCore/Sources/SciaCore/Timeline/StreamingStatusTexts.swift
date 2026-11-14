/// タイムラインを最上部からさらに引っぱると見える、ストリーミングとRESTでの補完の状態の表示の文言。
public enum StreamingStatusTexts {
    /// 列の見出し。
    public static let streamingColumn = "ストリーミング"
    public static let restColumn = "REST"

    /// ストリーミングの状態。補足のある状態（ポーリング中、ログインが必要）は、補足を出す。
    public static func streaming(_ state: ConnectionDiagnostics.StreamingState?) -> String {
        ConnectionDiagnostics.StreamingState.note(of: state) ?? ConnectionDiagnostics.StreamingState.title(of: state)
    }

    /// つながっている間の、1分あたりに届いた新着の数。
    public static func arrivalRate(perMinute: Int) -> String {
        "\(perMinute)件 / 分"
    }

    /// RESTでの補完の状態。
    public static let notLoaded = "読み込み前"
    public static let upToDate = "最新"
    public static let loading = "読み込み中"
    public static let regenerating = "作り直し待ち"
    public static let paused = "待機中"
    public static let failed = "失敗"

    /// 補完で読んだ件数。
    public static func readCount(_ count: Int) -> String {
        "\(count)件"
    }

    /// 止まっている間に、タイムラインがいつまでの投稿を出しているか。
    public static func loadedUntil(_ time: String) -> String {
        "\(time)まで"
    }

    /// サーバーがホームを作り直しているときの、止まっている理由。
    public static let regeneratingNote = "サーバーがホームを作り直し中のため、時間をおいて読み直します。"

    /// 補完に失敗したときの、止まっている理由。
    /// - Parameter reason: 失敗の理由の文。
    public static func failedNote(reason: String) -> String {
        "\(reason)次につながったときに読み直します。"
    }
}
