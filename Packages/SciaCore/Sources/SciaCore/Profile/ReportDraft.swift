public import Observation

/// 通報のシートの状態。決まりはdocs/menus.mdの「ユーザーのメニュー」にある。
@MainActor
@Observable
public final class ReportDraft {
    /// 通信の口。テストとカタログでは差し替える。
    public struct API: Sendable {
        public var rules: @Sendable () async throws -> [InstanceRule]
        public var submit: @Sendable (ReportRequest) async throws -> Void

        public init(rules: @escaping @Sendable () async throws -> [InstanceRule], submit: @escaping @Sendable (ReportRequest) async throws -> Void) {
            self.rules = rules
            self.submit = submit
        }
    }

    /// サーバーのルールの読み込み。
    public enum Rules {
        case loading
        case loaded([InstanceRule])
        case failed(any Error)
    }

    /// コメントの上限。Mastodonは`Report::COMMENT_SIZE_LIMIT`で、Rubyの文字列の長さ（コードポイントの数）で数える。
    public static let commentLimit = 1_000

    public let accountID: String
    public let acct: String
    /// 投稿のメニューから開いたときの、添えられる相手の投稿。
    public let statusID: String?
    /// 添えられる投稿があれば、既定で添える。
    public var includesStatus = true
    /// 選ぶまで送れない。
    public var category: ReportCategory?
    public var selectedRuleIDs: Set<String> = []
    public var comment = ""
    /// ほかのサーバーのアカウントのとき、そのサーバーの管理者にも転送する。サーバーの既定に合わせて、転送しない状態から始める。
    public var forward = false
    public private(set) var rules: Rules = .loading
    public private(set) var isSubmitting = false
    /// 送れなかった理由。書いた内容は残し、もう一度送れるようにする。
    public private(set) var submitError: (any Error)?

    private let api: API

    public init(accountID: String, acct: String, statusID: String?, api: API) {
        self.accountID = accountID
        self.acct = acct
        self.statusID = statusID
        self.api = api
    }

    /// ほかのサーバーのアカウントなら、そのサーバー名。転送を選べるのは、このときだけ。
    public var remoteDomain: String? {
        let parts = acct.split(separator: "@", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    public var commentLength: Int { comment.unicodeScalars.count }

    public var canSubmit: Bool {
        guard !isSubmitting, let category, commentLength <= Self.commentLimit else { return false }
        return category != .violation || !selectedRuleIDs.isEmpty
    }

    /// 送る内容。送れない状態ならnil。
    public var request: ReportRequest? {
        guard canSubmit, let category else { return nil }
        return ReportRequest(
            accountID: accountID,
            statusIDs: includesStatus ? statusID.map { [$0] } ?? [] : [],
            comment: comment,
            forward: remoteDomain != nil && forward,
            category: category,
            // 選んだあとに種類を変えても、ほかの種類ではルールを送らない。
            ruleIDs: category == .violation ? selectedRuleIDs.sorted() : []
        )
    }

    public func toggleRule(_ id: String) {
        if selectedRuleIDs.contains(id) {
            selectedRuleIDs.remove(id)
        } else {
            selectedRuleIDs.insert(id)
        }
    }

    /// サーバーのルールを読む。読み直すときも、読み終えるまで読み込み中にする。
    public func loadRules() async {
        rules = .loading
        do {
            rules = .loaded(try await api.rules())
        } catch {
            rules = .failed(error)
        }
    }

    /// 送れたらtrue。送れなければ、理由を`submitError`に残してfalse。
    public func submit() async -> Bool {
        guard let request else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        submitError = nil
        do {
            try await api.submit(request)
            return true
        } catch {
            submitError = error
            return false
        }
    }
}
