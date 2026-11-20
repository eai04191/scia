import Foundation

public struct UserDisplayRule: Codable, Equatable, Sendable {
    public var name: String?
    public var avatarFile: String?
    public var stopsAnimation: Bool

    public init(name: String? = nil, avatarFile: String? = nil, stopsAnimation: Bool = false) {
        self.name = name
        self.avatarFile = avatarFile
        self.stopsAnimation = stopsAnimation
    }

    public var isEmpty: Bool { name == nil && avatarFile == nil && !stopsAnimation }
}

extension AppSettings {
    public var userDisplayDomain: String? {
        emojiLocalServer.flatMap { store.userDisplayDomains[$0.lowercased()] }
    }

    public func setUserDisplayDomain(_ domain: String) {
        guard let server = emojiLocalServer else { return }
        store.userDisplayDomains[server.lowercased()] = domain.lowercased()
        userDisplays.reconcileDomains()
    }

    public func userDisplayKey(acct: String) -> String? {
        if acct.contains("@") { return acct.lowercased() }
        guard let server = userDisplayDomain else { return nil }
        return UserHandle(acct: acct, localServer: server).fullAcct.lowercased()
    }

}

public enum UserDisplayError: Error { case missingServer }

public enum UserDisplayTexts {
    public static let empty = "表示を変更したユーザーはいません"
    public static let title = "表示のカスタマイズ"
    public static let edit = "表示をカスタマイズ"
    public static func edit(acct: String) -> String { "@\(acct)の表示をカスタマイズ" }
    public static func customizationWarning(for rule: UserDisplayRule) -> String? {
        let identity: String? = switch (rule.name != nil, rule.avatarFile != nil) {
        case (true, true): "表示名とアイコンを変更しています"
        case (true, false): "表示名を変更しています"
        case (false, true): "アイコンの表示を変更しています"
        case (false, false): nil
        }
        let animation = rule.stopsAnimation ? "アイコンのアニメーションを停止しています" : nil
        let messages = [identity, animation].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    public static let original = "元のプロフィール"
    public static let name = "表示名"
    public static let avatar = "アイコン"
    public static let chooseSymbol = "シンボルを選択"
    public static let symbol = "シンボル"
    public static let backgroundColor = "背景色"
    public static let imageCreationFailure = "アイコンを作成できませんでした"
    public static let chooseImage = "画像を選択"
    public static let resetName = "元の表示名を使用"
    public static let resetAvatar = "元のアイコンを使用"
    public static let scope = "変更はこのデバイスのSciaにのみ適用されます。"
    public static let stopsAnimation = "アイコンのアニメーションを停止"
    public static let save = "保存"
    public static let saveFailure = "変更を保存できませんでした"
}
