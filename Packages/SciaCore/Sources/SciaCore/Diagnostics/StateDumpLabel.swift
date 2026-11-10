/// 状態ダンプに書く、状態の種類だけの表記。状態ダンプは違和感レポートに入るため、状態が持つ値をそのまま出さない（docs/logging.md）。

extension DraftAttachment.State {
    /// 添付のURLと代替テキストは出さない。失敗は、サーバーが受け付けた後かどうかだけを添える。
    public var dumpLabel: String {
        switch self {
        case .uploading: "uploading"
        case .processing: "processing"
        case .uploaded: "uploaded"
        case .failed(let serverID): serverID == nil ? "failed" : "failed(accepted)"
        }
    }
}

extension TimelineContentState {
    public var dumpLabel: String {
        switch self {
        case .loading: "loading"
        case .loaded: "loaded"
        case .regenerating: "regenerating"
        case .failed(let reason): reason.failedDumpLabel
        case .unavailable: "unavailable"
        }
    }
}

extension TimelineFooterState {
    public var dumpLabel: String {
        switch self {
        case .idle: "idle"
        case .loading: "loading"
        case .failed(let reason): reason.failedDumpLabel
        case .reachedEnd: "reachedEnd"
        }
    }
}

extension ErrorPresentation {
    /// 失敗の種類が分かる補足（「HTTP 503」「URLError -1009」）と、ログアウトされたアカウントがあるかだけを書く。
    /// 文言はサーバーが返した理由やハンドルを含むので出さない。
    fileprivate var failedDumpLabel: String {
        let details = [code, loggedOutAccount == nil ? nil : "loggedOut"].compactMap(\.self)
        return details.isEmpty ? "failed" : "failed(\(details.joined(separator: " ")))"
    }
}
