import SciaCore
import UIKit

/// 行を出す前に、その行のアイコンを読み込んでおく。
///
/// アイコンは投稿の文字と違って別のURLから読むため、行を出してから読み始めると、出た時点では灰色で、届いてから画像に変わる。
/// 新着は挿入する前に、スクロールで出てくる行は画面に入る前に読み始め、出た時点で描けているようにする。
extension TimelineViewController {
    /// `entries`の行に描くアイコンの画像。行を描くときと同じ大きさで求める。
    func avatarKeys(for entries: some Sequence<TimelineEntry>) -> Set<AvatarImageStore.Key> {
        var keys = Set<AvatarImageStore.Key>()
        for entry in entries {
            switch entry {
            case .status(let status), .pinned(let status):
                keys.formUnion(avatarKeys(for: status))
            case .notification(let notification):
                keys.formUnion(avatarKeys(for: notification))
            case .account(let account):
                let content = avatarContent(of: account)
                if let url = content.url {
                    keys.insert(AvatarView.key(url: url, animates: content.animates, side: tuning.value(of: TuningCatalog.avatarSize), scale: traitCollection.displayScale))
                }
            case .gap, .unreadable:
                break
            }
        }
        return keys
    }

    /// 投稿した人のアイコンと、ブーストなら名前の上の行に出すブーストした人のアイコン。
    func avatarKeys(for status: Status) -> [AvatarImageStore.Key] {
        let scale = traitCollection.displayScale
        var keys: [AvatarImageStore.Key] = []
        let shown = avatarContent(of: status.displayed.account)
        if let url = shown.url {
            keys.append(AvatarView.key(url: url, animates: shown.animates, side: tuning.value(of: TuningCatalog.avatarSize), scale: scale))
        }
        if status.reblog != nil {
            let booster = avatarContent(of: status.account)
            if let url = booster.url {
                keys.append(AvatarView.key(url: url, animates: booster.animates, side: tuning.value(of: TuningCatalog.boosterAvatarSize), scale: scale))
            }
        }
        return keys
    }

    /// `entries`の行のアイコンを読み始める。待たずに戻る。前に読めなかったアイコンは読まない。
    func prefetchAvatars(for entries: some Sequence<TimelineEntry>) {
        avatarImages.prefetch(avatarKeys(for: entries))
    }

    /// `entries`が返す行のアイコンを読み込み終えるまで待つ。待っている間に`entries`の返す行が増えたら、増えた行のアイコンも待つ。
    /// `deadline`を過ぎたら、読み込み終えていなくても戻る。読めなかったアイコンは、読み直して待つことはしない。
    /// 先読みで前に読めなかったアイコンも待たない。
    func waitForAvatars(of entries: () -> [TimelineEntry], until deadline: ContinuousClock.Instant) async {
        var requested = Set<AvatarImageStore.Key>()
        while ContinuousClock.now < deadline {
            let keys = avatarKeys(for: entries()).subtracting(requested)
            guard !keys.isEmpty else { return }
            requested.formUnion(keys)
            await avatarImages.load(keys, until: deadline)
        }
    }
}
