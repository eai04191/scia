import Observation
import SciaCore
import UIKit

/// タブに置いたプロフィールで、記号の代わりに出すその人のアイコン。決まりはdocs/tabs.mdの「プロフィール」にある。
/// 読んだアイコンをアカウントのIDごとに持ち、描くたびに、今のアイコンの形の設定で切り抜く。
@MainActor
@Observable
final class ProfileTabIcons {
    struct Icon {
        /// タブバーと切り替えタブのアイコン。
        let tab: UIImage
        /// 選んでいるときのタブのアイコン。元の色のまま描く画像には選んだ色が付かないため、選んだ色の縁を付ける。
        let selectedTab: UIImage
        /// 見出しのメニューと、設定の並びのアイコン。
        let menu: UIImage
    }

    /// タブバーのアイコンの一辺。タブバーは記号を描く大きさを公開していないため、並ぶ記号と大きさがそろって見える値にした。
    static let tabSide: CGFloat = 28
    /// 選んでいるときの縁の太さ。
    private static let ringWidth: CGFloat = 2

    /// 読むアイコンの一辺。大きいほうに合わせて読み、小さいほうは縮めて描く。
    static var loadSide: CGFloat {
        max(tabSide, AvatarIcon.menuSide)
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var avatars: [String: UIImage] = [:]
    /// アイコンが変わるたびに増える。設定の並びは、これが変わったら行を描き直す。
    private(set) var revision = 0
    /// アイコンが変わったとき。届いたときと、アイコンの形の設定を変えたとき。アクセントカラーで変わる縁は、タブバーが選び直しを見張って描き直させる。
    @ObservationIgnored var onChange: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        observeAppearance()
    }

    func setAvatar(_ avatar: UIImage, forAccountID id: String) {
        avatars[id] = avatar
        changed()
    }

    /// 並びから外したプロフィールのアイコンを捨てる。
    func removeAvatars(except accountIDs: Set<String>) {
        let kept = avatars.filter { accountIDs.contains($0.key) }
        guard kept.count != avatars.count else { return }
        avatars = kept
        changed()
    }

    /// 項目のアイコンを読んであるか。
    func hasAvatar(for item: TabItem) -> Bool {
        guard case .profile(let accountID, _, _) = item else { return false }
        return avatars[accountID] != nil
    }

    private func changed() {
        revision += 1
        onChange?()
    }

    /// 項目に出すアイコン。プロフィールでないか、アイコンをまだ読んでいなければnil。
    func icon(for item: TabItem) -> Icon? {
        guard case .profile(let accountID, _, _) = item, let avatar = avatars[accountID] else { return nil }
        let shape = settings.appearance.avatarShape
        guard let tab = AvatarIcon.image(avatar, side: Self.tabSide, shape: shape),
              let selectedTab = Self.ringed(avatar, shape: shape, color: settings.accentColor.uiColor),
              let menu = AvatarIcon.image(avatar, side: AvatarIcon.menuSide, shape: shape) else { return nil }
        return Icon(tab: tab, selectedTab: selectedTab, menu: menu)
    }

    /// 縁の内側にアイコンを縮めて置き、`color`の縁で囲む。大きさは選んでいないときと同じにし、選んでもタブの中身がずれないようにする。
    /// 画像に描き込むので、ビューのティントカラーを引き継ぐ`UIColor.tintColor`では描けない。アクセントカラーの設定の色を渡す。
    private static func ringed(_ avatar: UIImage, shape: AvatarShape, color: UIColor) -> UIImage? {
        let gap = ringWidth * 2
        guard let inner = AvatarIcon.image(avatar, side: tabSide - gap * 2, shape: shape) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: tabSide, height: tabSide)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            inner.draw(at: CGPoint(x: gap, y: gap))
            let ring = AvatarIcon.path(in: bounds.insetBy(dx: ringWidth / 2, dy: ringWidth / 2), shape: shape)
            ring.lineWidth = ringWidth
            color.setStroke()
            ring.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

    private func observeAppearance() {
        withObservationTracking {
            _ = settings.appearance.avatarShape
        } onChange: { [weak self] in
            Task(.withoutRequests) { @MainActor [weak self] in
                guard let self else { return }
                changed()
                observeAppearance()
            }
        }
    }
}
