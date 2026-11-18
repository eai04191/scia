public import Foundation

/// 作者が用意するプリセット。使う人は値を変えられない（docs/preset.md）。
public enum BuiltInPreset: String, CaseIterable, Codable, Sendable {
    /// アプリの既定値そのまま。
    case standard
    /// 余白と名前の行の文字を詰め、メディアを本文の右に小さく傾けずに並べ、アクションバーを常には出さずにタップで開く。
    case compact

    public var title: String {
        switch self {
        case .standard: "標準"
        case .compact: "コンパクト"
        }
    }

    /// アプリの既定値から変える値。キーは`AppSettings`がプリセットに持つ値のキー（`AppSettings+Modified.swift`の行と画面からたどれることを、テストで確かめる）。
    /// すき間の項目は個々に並べず、段の単位（`spacingUnit`）から決める。設定を読むたびに引くので、組み立てた辞書を持っておく。
    public var values: [String: PresetValue] {
        switch self {
        case .standard: Self.standardValues
        case .compact: Self.compactValues
        }
    }

    /// すき間の段の単位。nilなら既定の単位（`SpacingScale.unit`）のまま。
    public var spacingUnit: Double? {
        switch self {
        case .standard: nil
        case .compact: 2
        }
    }

    private static let standardValues: [String: PresetValue] = [:]

    private static let compactValues = BuiltInPreset.compact.withSpacing([
        "appearanceValue.timeline.avatarSize": .number(32),
        "appearanceValue.text.namePrimary": .number(1),
        "appearanceValue.text.nameSecondary": .number(-1),
        "appearanceValue.timeline.mediaTallestAspectRatio": .number(1),
        "appearanceChoice.mediaArrangement": .text("besideBody"),
        "appearanceChoice.tiltsStackedPhotos": .bool(false),
        "appearanceChoice.showsActionBar": .bool(false),
        "objectActions.status.tap": .text("actionBar"),
        "objectActions.status.longPress": .text("item:openThread"),
    ])

    /// `values`に、すき間の項目を段の単位から求めた値を足す。
    private func withSpacing(_ values: [String: PresetValue]) -> [String: PresetValue] {
        guard let unit = spacingUnit else { return values }
        var result = values
        for item in AppearanceCatalog.values + NotificationAppearanceCatalog.values {
            guard case .spacing(let level) = item.role else { continue }
            precondition(result[item.presetKey] == nil, "\(item.id)はすき間の段で決めるので、個々に並べない")
            result[item.presetKey] = .number(level.value(unit: unit))
        }
        return result
    }
}

/// プリセットに持つ1つの値。設定の画面の1つの値を、保存できる形にしたもの。
public enum PresetValue: Codable, Hashable, Sendable {
    case bool(Bool)
    case number(Double)
    case text(String)
    case list([String])
    /// 値がないことを選んだもの。「アカウント設定に従う」のように、ないことが選択肢の1つになる項目で使う。
    /// 項目を持たない（親に従う）こととは別。
    case null

    /// 保存の形に書ける値か。数でない値（NaNや無限）は`JSONEncoder`が書けず、ライブラリ全体を保存できなくなる。
    var isStorable: Bool {
        guard case .number(let number) = self else { return true }
        return number.isFinite
    }
}

/// プリセットを指す。
public enum PresetID: Codable, Hashable, Sendable {
    case builtIn(BuiltInPreset)
    /// 使う人のプリセット。番号は`PresetLibrary`が作った順に振り、使い回さない。
    case user(Int)

    /// ショートカットなどの外に残す、文字列の指し方。
    public var token: String {
        switch self {
        case .builtIn(let preset): "builtIn:\(preset.rawValue)"
        case .user(let number): "user:\(number)"
        }
    }

    public init?(token: String) {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "builtIn":
            guard let preset = BuiltInPreset(rawValue: parts[1]) else { return nil }
            self = .builtIn(preset)
        case "user":
            guard let number = Int(parts[1]) else { return nil }
            self = .user(number)
        default:
            return nil
        }
    }
}

/// 使う人のプリセット。親から変えた項目だけを持つ。
public struct UserPreset: Codable, Hashable, Sendable {
    public let id: Int
    public var name: String
    public var parent: PresetID
    /// 変えた項目。値が親と同じでも、変えたものとして残す（docs/preset.md）。
    public var values: [String: PresetValue]
}

/// プリセットのどれを変えるか、どれを使うかを決める側。アプリと、プリセットを割り当てたアカウント。
public enum PresetScope: Hashable, Sendable {
    case app
    /// `Credential.handle`。
    case account(String)
}

public enum PresetError: Error, Equatable {
    /// 指したプリセットが削除されている。
    case presetNotFound
    /// 組み込みのプリセットは変えられない。
    case builtInIsReadOnly
    /// 数でない値（NaNや無限）。保存の形に書けない。
    case invalidValue
    /// 指したアカウントがログアウトしている。
    case accountNotFound
    /// ほかの使う人のプリセットが使っている名前。
    case nameTaken
}

/// プリセットと、アプリとアカウントが使うプリセット。値の重ね方は、アプリの既定値、組み込みのプリセット、使う人のプリセット（親から子へ）の順（docs/preset.md）。
public struct PresetLibrary: Codable, Equatable, Sendable {
    /// 使う人のプリセット。作った順。
    public private(set) var userPresets: [UserPreset] = []
    public private(set) var appPreset: PresetID = .builtIn(.standard)
    /// プリセットを割り当てたアカウント。キーは`Credential.handle`。割り当てていないアカウントは、アプリのプリセットに従う。
    public private(set) var accountPresets: [String: PresetID] = [:]
    private var nextUserID = 1

    public init() {}

    /// 保存した形から読む。読めないときは、何も作っていない状態にする。
    public init(stored data: Data?) {
        guard let data, let library = try? JSONDecoder().decode(Self.self, from: data), library.isConsistent else {
            self.init()
            return
        }
        self = library
    }

    public var storedData: Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    // MARK: 読む

    public func userPreset(_ id: Int) -> UserPreset? {
        userPresets.first { $0.id == id }
    }

    public func contains(_ id: PresetID) -> Bool {
        switch id {
        case .builtIn: true
        case .user(let number): userPreset(number) != nil
        }
    }

    public func name(of id: PresetID) -> String? {
        switch id {
        case .builtIn(let preset): preset.title
        case .user(let number): userPreset(number)?.name
        }
    }

    /// アカウントが使うプリセット。割り当てがなければアプリのプリセット。
    public func preset(forAccount handle: String) -> PresetID {
        accountPresets[handle] ?? appPreset
    }

    /// 割り当てがあるアカウントは、そのプリセット。
    public func preset(for scope: PresetScope) -> PresetID {
        switch scope {
        case .app: appPreset
        case .account(let handle): preset(forAccount: handle)
        }
    }

    /// プリセットが決めている値。どの層も値を持たなければ`nil`で、アプリの既定値を使う。
    public func value(forKey key: String, in id: PresetID) -> PresetValue? {
        var current = id
        while case .user(let number) = current {
            guard let preset = userPreset(number) else { return nil }
            if let value = preset.values[key] { return value }
            current = preset.parent
        }
        guard case .builtIn(let builtIn) = current else { return nil }
        return builtIn.values[key]
    }

    /// そのプリセットが変えた項目か。値が親と同じでも、変えたものとして扱う。
    public func isModified(_ key: String, in id: PresetID) -> Bool {
        guard case .user(let number) = id else { return false }
        return userPreset(number)?.values[key] != nil
    }

    /// `id`の先祖（親から順に、組み込みのプリセットまで）。
    public func ancestors(of id: PresetID) -> [PresetID] {
        var result: [PresetID] = []
        var current = id
        while case .user(let number) = current, let preset = userPreset(number) {
            result.append(preset.parent)
            current = preset.parent
        }
        return result
    }

    // MARK: 選ぶ

    public mutating func select(_ id: PresetID, for scope: PresetScope) throws(PresetError) {
        guard contains(id) else { throw .presetNotFound }
        switch scope {
        case .app: appPreset = id
        case .account(let handle): accountPresets[handle] = id
        }
    }

    /// アカウントの割り当てを外し、アプリのプリセットに従わせる。
    public mutating func unassign(account handle: String) {
        accountPresets[handle] = nil
    }

    /// ログアウトしたアカウントの割り当てを忘れる。
    public mutating func forgetAccount(_ handle: String) {
        accountPresets[handle] = nil
    }

    // MARK: 作る、変える、消す

    /// `parent`を親にしたプリセットを作る。名前を渡さなければ、親の名前に番号を付ける。
    @discardableResult
    public mutating func create(parent: PresetID, name: String? = nil) throws(PresetError) -> PresetID {
        guard let parentName = self.name(of: parent) else { throw .presetNotFound }
        if let name, isTaken(name, except: nil) { throw .nameTaken }
        return add(UserPreset(id: 0, name: name ?? numberedName(from: parentName), parent: parent, values: [:]))
    }

    /// 同じ親と同じ変えた項目を持つ別のプリセットを作る。名前は、元の名前に番号を付ける。
    @discardableResult
    public mutating func duplicate(_ id: PresetID) throws(PresetError) -> PresetID {
        switch id {
        case .builtIn(let builtIn):
            return add(UserPreset(id: 0, name: numberedName(from: builtIn.title), parent: .builtIn(builtIn), values: [:]))
        case .user(let number):
            guard let source = userPreset(number) else { throw .presetNotFound }
            return add(UserPreset(id: 0, name: numberedName(from: source.name), parent: source.parent, values: source.values))
        }
    }

    public mutating func rename(_ id: PresetID, to name: String) throws(PresetError) {
        if isTaken(name, except: id) { throw .nameTaken }
        try update(id) { $0.name = name }
    }

    /// 名前が、`except`のほかの使う人のプリセットに使われているか。組み込みのプリセットとは重なってもよい（docs/preset.md）。
    private func isTaken(_ name: String, except: PresetID?) -> Bool {
        userPresets.contains { $0.name == name && PresetID.user($0.id) != except }
    }

    /// `scope`が使うプリセットの値を変える。組み込みのプリセットを使っていたら、それを親にしたプリセットを作り、そのプリセットを使っていた側（割り当てていないアカウントならアプリ）をそちらに切り替えてから変える。
    /// - Returns: 値を変えたプリセット。
    @discardableResult
    public mutating func setValue(_ value: PresetValue, forKey key: String, for scope: PresetScope) throws(PresetError) -> PresetID {
        guard value.isStorable else { throw .invalidValue }
        let target = try editableTarget(for: scope)
        try setValue(value, forKey: key, in: target)
        return target
    }

    /// プリセットを選ぶ画面から開いた、使っていないプリセットの値を変える。
    public mutating func setValue(_ value: PresetValue, forKey key: String, in id: PresetID) throws(PresetError) {
        guard value.isStorable else { throw .invalidValue }
        try update(id) { $0.values[key] = value }
    }

    /// 変えたことを取り消し、親の値に従わせる。
    public mutating func resetValue(forKey key: String, in id: PresetID) throws(PresetError) {
        try update(id) { $0.values[key] = nil }
    }

    /// プリセットを消す。変えた項目は子に引き継ぎ（子も変えていればその値を残す）、子の親を消したプリセットの親に付け替える。
    /// 消したプリセットを使っていたアプリとアカウントは、その親に切り替える。
    public mutating func delete(_ id: PresetID) throws(PresetError) {
        guard case .user(let number) = id else { throw .builtInIsReadOnly }
        guard let index = userPresets.firstIndex(where: { $0.id == number }) else { throw .presetNotFound }
        let removed = userPresets.remove(at: index)
        for childIndex in userPresets.indices where userPresets[childIndex].parent == id {
            userPresets[childIndex].values.merge(removed.values) { child, _ in child }
            userPresets[childIndex].parent = removed.parent
        }
        if appPreset == id { appPreset = removed.parent }
        for (handle, assigned) in accountPresets where assigned == id {
            accountPresets[handle] = removed.parent
        }
    }

    // MARK: 内側

    /// 割り当てていないアカウントは、アプリのプリセットを使っているので、アプリのプリセットを変える。
    private mutating func editableTarget(for scope: PresetScope) throws(PresetError) -> PresetID {
        var owner = scope
        if case .account(let handle) = scope, accountPresets[handle] == nil {
            owner = .app
        }
        let current = preset(for: owner)
        guard case .builtIn = current else { return current }
        let created = try create(parent: current)
        try select(created, for: owner)
        return created
    }

    private mutating func add(_ preset: UserPreset) -> PresetID {
        let preset = UserPreset(id: nextUserID, name: preset.name, parent: preset.parent, values: preset.values)
        nextUserID += 1
        userPresets.append(preset)
        return .user(preset.id)
    }

    private mutating func update(_ id: PresetID, _ change: (inout UserPreset) -> Void) throws(PresetError) {
        guard case .user(let number) = id else { throw .builtInIsReadOnly }
        guard let index = userPresets.firstIndex(where: { $0.id == number }) else { throw .presetNotFound }
        change(&userPresets[index])
    }

    /// 「コンパクト 2」のように、使っていない最小の番号を付ける。
    private func numberedName(from base: String) -> String {
        let names = Set(userPresets.map(\.name))
        var number = 2
        while names.contains(PresetTexts.numberedName(base, number: number)) {
            number += 1
        }
        return PresetTexts.numberedName(base, number: number)
    }

    /// 保存した形が、どのプリセットも組み込みのプリセットへ行き着き、指す先がすべてあり、次の番号を振れるか。
    private var isConsistent: Bool {
        let ids = Set(userPresets.map(\.id))
        guard ids.count == userPresets.count, ids.allSatisfy({ $0 > 0 && $0 < nextUserID }), nextUserID < .max else { return false }
        for preset in userPresets {
            var visited: Set<Int> = [preset.id]
            var current = preset.parent
            while case .user(let number) = current {
                guard ids.contains(number), visited.insert(number).inserted, let next = userPreset(number) else { return false }
                current = next.parent
            }
        }
        return ([appPreset] + Array(accountPresets.values)).allSatisfy(contains)
    }
}

public enum PresetTexts {
    /// ショートカットで、指したプリセットが削除されていたとき。
    public static let presetNotFound = "プリセットが見つかりません"
    /// ショートカットで、指したアカウントがログアウトしていたとき。
    public static let accountNotFound = "アカウントが見つかりません"

    /// 自動で作るプリセットと、複製したプリセットの名前。
    public static func numberedName(_ base: String, number: Int) -> String {
        "\(base) \(number)"
    }
}
