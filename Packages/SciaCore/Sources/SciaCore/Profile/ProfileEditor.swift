import Foundation
public import Observation

/// 自分のプロフィールの編集画面の状態。元の値を読み、編集を受け、保存する。
@MainActor
@Observable
public final class ProfileEditor {
    /// 通信の口。テストとカタログでは差し替える。
    public struct API: Sendable {
        public var source: @Sendable () async throws -> ProfileSource
        public var save: @Sendable (ProfileDraft) async throws -> ProfileSource
        /// 自分の注目のハッシュタグ。
        public var featuredTags: @Sendable () async throws -> [FeaturedTag]
        public var featureTag: @Sendable (String) async throws -> FeaturedTag
        /// `FeaturedTag`のIDで外す。
        public var unfeatureTag: @Sendable (String) async throws -> Void
        /// 自分が紹介しているアカウント。最後まで読んだもの。
        public var endorsements: @Sendable () async throws -> [Account]
        public var endorse: @Sendable (String) async throws -> Void
        public var unendorse: @Sendable (String) async throws -> Void

        public init(
            source: @escaping @Sendable () async throws -> ProfileSource,
            save: @escaping @Sendable (ProfileDraft) async throws -> ProfileSource,
            featuredTags: @escaping @Sendable () async throws -> [FeaturedTag] = { [] },
            featureTag: @escaping @Sendable (String) async throws -> FeaturedTag = { _ in throw CancellationError() },
            unfeatureTag: @escaping @Sendable (String) async throws -> Void = { _ in throw CancellationError() },
            endorsements: @escaping @Sendable () async throws -> [Account] = { [] },
            endorse: @escaping @Sendable (String) async throws -> Void = { _ in throw CancellationError() },
            unendorse: @escaping @Sendable (String) async throws -> Void = { _ in throw CancellationError() }
        ) {
            self.source = source
            self.save = save
            self.featuredTags = featuredTags
            self.featureTag = featureTag
            self.unfeatureTag = unfeatureTag
            self.endorsements = endorsements
            self.endorse = endorse
            self.unendorse = unendorse
        }

        public init(client: MastodonClient) {
            self.init(
                source: { try await client.profileSource() },
                save: { try await client.updateProfile($0) },
                featuredTags: { try await client.featuredTags() },
                featureTag: { try await client.featureTag($0) },
                unfeatureTag: { try await client.unfeatureTag($0) },
                endorsements: { try await client.endorsements() },
                endorse: { _ = try await client.endorse($0) },
                unendorse: { _ = try await client.unendorse($0) }
            )
        }
    }

    /// 注目のハッシュタグと紹介しているユーザーの節の、元の値の読み込み。読めるまで、その節は変えられない。
    public enum SectionSource<Value> {
        case loading
        case loaded(Value)
        case failed(any Error)

        public var value: Value? {
            if case .loaded(let value) = self { value } else { nil }
        }
    }

    /// 元の値の読み込み。
    public enum Source {
        case loading
        case loaded(ProfileSource)
        case failed(any Error)
    }

    public private(set) var source: Source = .loading
    /// 読み込むまでは空のまま。読み込んだら、元の値から始める。
    public var draft: ProfileDraft?
    public private(set) var isSaving = false
    /// 自分の注目のハッシュタグの元の値。保存で送れたものは、そのつど取り込む。
    public private(set) var featuredTagsSource: SectionSource<[FeaturedTag]> = .loading
    /// 編集中の注目のハッシュタグの名前。`#`を除く。読み込むまでは空。
    public private(set) var featuredTagNames: [String] = []
    /// 自分が紹介しているアカウントの元の値。保存で送れたものは、そのつど取り込む。
    public private(set) var endorsementsSource: SectionSource<[Account]> = .loading
    /// 編集中の紹介しているアカウント。読み込むまでは空。
    public private(set) var endorsedAccounts: [Account] = []
    /// 保存で、注目のハッシュタグか紹介しているアカウントを1つでも送れたときに呼ぶ。途中で送れなくなったときも呼ぶ。
    /// 開いている自分のプロフィールの棚と、覚えている自分のタグを読み直すのに使う。
    @ObservationIgnored public var onFeaturedChange: (@MainActor () -> Void)?
    /// 保存で、プロフィールの項目を送れたときに呼ぶ。そのあとに注目のハッシュタグや紹介しているアカウントを送れなくても呼ぶ。
    /// サーバーにはもう保存されているので、開いている自分のプロフィールに反映するのに使う。
    @ObservationIgnored public var onProfileSaved: (@MainActor (ProfileSource) -> Void)?
    /// 上限。サーバーの設定を読めなければ、4.6.0より前のMastodonの値のまま使う。超えた分はサーバーが422で拒む。
    public var limits: ProfileLimits
    public var charactersReservedPerURL: Int
    private let api: API

    public init(limits: ProfileLimits = .beforeMastodon46, charactersReservedPerURL: Int = 23, api: API) {
        self.limits = limits
        self.charactersReservedPerURL = charactersReservedPerURL
        self.api = api
    }

    /// プロフィールの項目と、注目のハッシュタグと、紹介しているアカウントを並べて読む。どれかが読めなくても、ほかは編集できる。
    public func loadAll() async {
        async let profile: Void = load()
        async let tags: Void = loadFeaturedTags()
        async let endorsements: Void = loadEndorsements()
        _ = await (profile, tags, endorsements)
    }

    /// 注目のハッシュタグの元の値を読む。読めていれば読まない。読めたら、編集中の名前を元の値から始める。
    public func loadFeaturedTags() async {
        if case .loaded = featuredTagsSource { return }
        featuredTagsSource = .loading
        do {
            let tags = try await api.featuredTags()
            featuredTagsSource = .loaded(tags)
            featuredTagNames = tags.map(\.name)
        } catch {
            featuredTagsSource = .failed(error)
        }
    }

    /// 紹介しているアカウントの元の値を読む。読めていれば読まない。読めたら、編集中の並びを元の値から始める。
    public func loadEndorsements() async {
        if case .loaded = endorsementsSource { return }
        endorsementsSource = .loading
        do {
            let accounts = try await api.endorsements()
            endorsementsSource = .loaded(accounts)
            endorsedAccounts = accounts
        } catch {
            endorsementsSource = .failed(error)
        }
    }

    /// 注目のハッシュタグを足す。前の`#`と空白を除き、空の名前と、サーバーと同じ決まりでそろえた名前が同じタグは足さない。足したらtrue。
    @discardableResult
    public func addFeaturedTag(_ raw: String) -> Bool {
        guard featuredTagsSource.value != nil else { return false }
        let name = Self.featuredTagName(raw)
        let normalized = Hashtag.normalizedName(name)
        guard !name.isEmpty, !featuredTagNames.contains(where: { Hashtag.normalizedName($0) == normalized }) else { return false }
        featuredTagNames.append(name)
        return true
    }

    public func removeFeaturedTag(at index: Int) {
        guard featuredTagNames.indices.contains(index) else { return }
        featuredTagNames.remove(at: index)
    }

    /// 紹介するアカウントを足す。すでにあれば足さない。足したらtrue。
    @discardableResult
    public func addEndorsement(_ account: Account) -> Bool {
        guard endorsementsSource.value != nil, !endorsedAccounts.contains(where: { $0.id == account.id }) else { return false }
        endorsedAccounts.append(account)
        return true
    }

    public func removeEndorsement(at index: Int) {
        guard endorsedAccounts.indices.contains(index) else { return }
        endorsedAccounts.remove(at: index)
    }

    /// 入力した語から、サーバーに送るタグの名前を作る。補完で選んでも、打って確定しても、前に`#`が付くことがあるため除く。
    static func featuredTagName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix("#") || name.hasPrefix("＃") {
            name.removeFirst()
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 注目のハッシュタグを、元の値から変えた。サーバーに並べ替えのAPIがないので、並びは比べない。
    public var featuredTagsChanged: Bool {
        guard let original = featuredTagsSource.value else { return false }
        return Set(original.map { Hashtag.normalizedName($0.name) }) != Set(featuredTagNames.map(Hashtag.normalizedName))
    }

    /// 紹介しているアカウントを、元の値から変えた。並びは比べない。
    public var endorsementsChanged: Bool {
        guard let original = endorsementsSource.value else { return false }
        return Set(original.map(\.id)) != Set(endorsedAccounts.map(\.id))
    }

    /// 注目のハッシュタグがサーバーの上限を超えている。上限が分からなければ止めない。
    public var hasTooManyFeaturedTags: Bool {
        guard let limit = limits.featuredTags else { return false }
        return featuredTagNames.count > limit
    }

    /// 元の値を読む。読み込み中なら何もしない。読み直したときも、書きかけの下書きは残す。
    public func load() async {
        if case .loaded = source, draft != nil { return }
        source = .loading
        do {
            let loaded = try await api.source()
            source = .loaded(loaded)
            if draft == nil {
                draft = ProfileDraft(source: loaded)
            }
        } catch {
            source = .failed(error)
        }
    }

    public var hasChanges: Bool {
        profileChanged || featuredTagsChanged || endorsementsChanged
    }

    private var profileChanged: Bool {
        guard case .loaded(let loaded) = source, let draft else { return false }
        return draft.hasChanges(from: loaded)
    }

    public var problems: [ProfileDraftProblem] {
        draft?.problems(limits: limits, charactersReservedPerURL: charactersReservedPerURL) ?? []
    }

    public var canSave: Bool {
        hasChanges && problems.isEmpty && !hasTooManyFeaturedTags && !isSaving
    }

    /// 保存し、保存したあとのプロフィールを返す。決まりはdocs/profile.mdの「注目のハッシュタグと紹介しているユーザーの編集」にある。
    /// プロフィールの項目、ハッシュタグを外す、ハッシュタグを足す、ユーザーを外す、ユーザーを足すの順に1つずつ送る。
    /// 途中で送れなければ、そこで止めて投げる。送れた分は元の値に取り込み、送り直すときは残りだけを送る。書きかけの下書きは残す。
    public func save() async throws -> ProfileSource {
        guard case .loaded(var saved) = source, let draft, !isSaving else { throw CancellationError() }
        isSaving = true
        var changedFeatured = false
        defer {
            isSaving = false
            if changedFeatured { onFeaturedChange?() }
        }
        if draft.hasChanges(from: saved) {
            saved = try await api.save(draft)
            source = .loaded(saved)
            self.draft = ProfileDraft(source: saved)
            onProfileSaved?(saved)
        }
        if featuredTagsChanged {
            try await saveFeaturedTags { changedFeatured = true }
        }
        if endorsementsChanged {
            try await saveEndorsements { changedFeatured = true }
        }
        return saved
    }

    /// 送る前に今の注目のハッシュタグを読み直し、それと比べて外すものと足すものを決める。同じタグを2度足すとサーバーが断り、
    /// 外したタグを2度外すと見つからないと返すので、前の保存が届いたのに応答を失ったときや、別の端末やwebで変えたときに、送り直しが断られ続けないようにするため。
    /// 上限まで載せているときに入れ替えられるよう、先に外す。
    private func saveFeaturedTags(didSend: () -> Void) async throws {
        var current = try await api.featuredTags()
        featuredTagsSource = .loaded(current)
        let wanted = Set(featuredTagNames.map(Hashtag.normalizedName))
        for tag in current where !wanted.contains(Hashtag.normalizedName(tag.name)) {
            try await api.unfeatureTag(tag.id)
            current.removeAll { $0.id == tag.id }
            featuredTagsSource = .loaded(current)
            didSend()
        }
        for name in featuredTagNames where current.first(named: name) == nil {
            current.append(try await api.featureTag(name))
            featuredTagsSource = .loaded(current)
            didSend()
        }
    }

    /// 紹介は何度送っても同じ結果になるので、読み直さずに元の値と比べて送る。
    private func saveEndorsements(didSend: () -> Void) async throws {
        guard var current = endorsementsSource.value else { return }
        let wanted = Set(endorsedAccounts.map(\.id))
        for account in current where !wanted.contains(account.id) {
            try await api.unendorse(account.id)
            current.removeAll { $0.id == account.id }
            endorsementsSource = .loaded(current)
            didSend()
        }
        for account in endorsedAccounts where !current.contains(where: { $0.id == account.id }) {
            try await api.endorse(account.id)
            current.append(account)
            endorsementsSource = .loaded(current)
            didSend()
        }
    }
}
