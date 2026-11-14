public import Foundation

/// 使う人がログアウトを選んだときの後始末。アカウントの情報を端末から消し、そのアカウントのために残したものを消す。
/// サーバー側のトークンは失効させない。APIの応答（401など）を理由には呼ばない。
/// 呼んだあと、そのアカウントの`AccountSession`を閉じ、残ったアカウント（`AccountRegistry.current`）かログインの画面を出すのはUI。
@MainActor
public enum AccountLogout {
    /// `credential`をアカウントのリストから消し、次を消す。
    /// - そのアカウントのために覚えた設定の値（タブの並びなど）。同じサーバーのアカウントが残っていなければ、サーバーのための値も
    /// - 添付ファイルの元のファイルと、先読みした画像。どのアカウントで見たものかを分けていないので、全部消す
    /// - そのサーバーのカスタム絵文字のリスト。サーバーのものなので、同じサーバーのアカウントが残っていれば残す
    ///
    /// アカウントのリストから消せなければ投げ、何も消さない。アカウントはリストにも端末にも残っているので、UIは今の画面のまま失敗を出す。
    /// - Parameter defaults: アカウントのための値を覚えた場所。`AppSettings`に渡したものと同じ。
    /// - Returns: ファイルを消し終えるまでの処理。待たなくてよい。
    @discardableResult
    public static func logOut<Image>(
        _ credential: Credential,
        from accounts: AccountRegistry,
        defaults: UserDefaults,
        settings: AppSettings,
        images: ImageStores<Image>
    ) throws -> Task<Void, Never> {
        try accounts.remove(credential.id)
        AccountScopedDefaults.removeData(of: credential, remaining: accounts.accounts, defaults: defaults, settings: settings)
        let remainsOnServer = accounts.accounts.contains { $0.instance.host() == credential.instance.host() }
        let mediaFiles = images.mediaFiles
        let mediaPrefetchFiles = images.mediaPrefetchFiles
        let customEmojis = images.customEmojis
        return Task(.withoutRequests) {
            await mediaFiles.removeAll()
            await mediaPrefetchFiles.removeAll()
            if !remainsOnServer {
                await customEmojis.remove(instance: credential.instance)
            }
        }
    }
}
