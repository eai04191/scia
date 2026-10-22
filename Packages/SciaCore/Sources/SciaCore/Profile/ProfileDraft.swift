public import Foundation

/// 自分のプロフィールの、編集できる元の値。`verify_credentials`と`update_credentials`が返す`source`の平文から作る。
/// 表示用のHTMLではなく平文を編集させ、HTMLはサーバーに作らせる（公式ドキュメントが勧める使い方）。
/// https://docs.joinmastodon.org/entities/Account/#CredentialAccount
public struct ProfileSource: Sendable, Equatable {
    public let account: Account
    /// 自己紹介の平文。
    public let note: String
    /// 補足情報の平文。
    public let fields: [Field]

    /// https://docs.joinmastodon.org/entities/Account/#source-fields
    public struct Field: Sendable, Equatable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public init(account: Account, note: String, fields: [Field]) {
        self.account = account
        self.note = note
        self.fields = fields
    }

    /// アイコンを設定している。Mastodonは、設定していないアカウントにも`missing.png`という既定の画像のURLを返すので、それで見分ける。
    /// 既定の画像のファイル名を変えているサーバーでは、設定していなくても設定していることになり、削除のボタンを出すだけで済む。
    public var hasAvatar: Bool { Self.isSet(account.avatar) }
    public var hasHeader: Bool { Self.isSet(account.header) }

    private static func isSet(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.lastPathComponent != "missing.png"
    }
}

extension ProfileSource: Decodable {
    private struct Source: Decodable {
        let note: String
        let fields: [Field]?
    }

    private enum CodingKeys: String, CodingKey {
        case source
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(Source.self, forKey: .source)
        account = try Account(from: decoder)
        note = source.note
        fields = source.fields ?? []
    }
}

extension ProfileSource.Field: Decodable {}

/// プロフィールの各項目の上限。
public struct ProfileLimits: Sendable, Equatable {
    public let displayName: Int
    public let note: Int
    public let fields: Int
    public let fieldName: Int
    public let fieldValue: Int

    public init(displayName: Int, note: Int, fields: Int, fieldName: Int, fieldValue: Int) {
        self.displayName = displayName
        self.note = note
        self.fields = fields
        self.fieldName = fieldName
        self.fieldValue = fieldValue
    }

    /// 上限は4.6.0から`api/v2/instance`で返る。それより前のMastodonは、決まったこの値で検証している。
    public static let beforeMastodon46 = ProfileLimits(displayName: 30, note: 500, fields: 4, fieldName: 255, fieldValue: 255)
}

/// 補足情報の1行。並べ替えても行を見分けられるよう、IDを持たせる。
public struct ProfileFieldDraft: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }

    /// 名前も値も空の行は、サーバーが捨てる。
    var isBlank: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// アイコンかヘッダー画像をどう変えるか。
public enum ProfileImageChange: Sendable, Equatable {
    case keep
    /// 切り抜いた画像に替える。
    case replace(MediaUpload)
    /// 消して、サーバーの既定の画像に戻す。
    case remove
}

/// 保存の前に見つけた、サーバーに拒まれる書き方。
public enum ProfileDraftProblem: Sendable, Equatable {
    case displayNameTooLong
    case noteTooLong
    case tooManyFields
    case fieldNameTooLong(ProfileFieldDraft.ID)
    case fieldValueTooLong(ProfileFieldDraft.ID)
    /// 値があるのに名前が空。サーバーは名前の空の行を拒む。
    case fieldNameMissing(ProfileFieldDraft.ID)
}

/// 編集中のプロフィール。
public struct ProfileDraft: Sendable, Equatable {
    public var displayName: String
    public var note: String
    public var fields: [ProfileFieldDraft]
    public var locked: Bool
    public var bot: Bool
    public var avatar: ProfileImageChange = .keep
    public var header: ProfileImageChange = .keep

    public init(source: ProfileSource) {
        displayName = source.account.displayName
        note = source.note
        fields = source.fields.map { ProfileFieldDraft(name: $0.name, value: $0.value) }
        locked = source.account.locked
        bot = source.account.bot
    }

    /// 元の値から変えたか。補足情報は、空の行を除いて名前と値の並びで比べる。行を足しただけでは変えたことにしない。
    public func hasChanges(from source: ProfileSource) -> Bool {
        displayName != source.account.displayName
            || note != source.note
            || sentFields != source.fields
            || locked != source.account.locked
            || bot != source.account.bot
            || avatar != .keep
            || header != .keep
    }

    /// サーバーに送る補足情報。空の行はサーバーが捨てるので、送る前に除く。
    var sentFields: [ProfileSource.Field] {
        fields.filter { !$0.isBlank }.map { ProfileSource.Field(name: $0.name, value: $0.value) }
    }

    /// 表示名の長さ。Mastodonは文字列の長さ（Unicodeのコードポイントの数）で検証する。
    public var displayNameLength: Int { displayName.unicodeScalars.count }

    /// 自己紹介の長さ。Mastodonは投稿の本文と同じく、URLを決まった長さ、メンションを`@ユーザー名`として、書記素の数で検証する。
    public func noteLength(charactersReservedPerURL: Int) -> Int {
        StatusLength.count(text: note, spoilerText: "", charactersReservedPerURL: charactersReservedPerURL)
    }

    public func problems(limits: ProfileLimits, charactersReservedPerURL: Int) -> [ProfileDraftProblem] {
        var problems: [ProfileDraftProblem] = []
        if displayNameLength > limits.displayName {
            problems.append(.displayNameTooLong)
        }
        if noteLength(charactersReservedPerURL: charactersReservedPerURL) > limits.note {
            problems.append(.noteTooLong)
        }
        let sent = fields.filter { !$0.isBlank }
        if sent.count > limits.fields {
            problems.append(.tooManyFields)
        }
        for field in sent {
            if field.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append(.fieldNameMissing(field.id))
            }
            // Mastodonは補足情報を、拒まずに上限のコードポイントの数で切り詰めて保存する（`Account::Field#sanitize`）。黙って欠けないよう、同じ数え方で止める。
            if field.name.unicodeScalars.count > limits.fieldName {
                problems.append(.fieldNameTooLong(field.id))
            }
            if field.value.unicodeScalars.count > limits.fieldValue {
                problems.append(.fieldValueTooLong(field.id))
            }
        }
        return problems
    }
}
