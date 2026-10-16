#if DEBUG
import UIKit

/// 知らせのチップ（`NoticeStackView`）の状態。ガラスの効果を見られるよう、ビューアのように画像の上に置く。
/// 本物の数秒で消えるチップはすぐ消えるため、カタログでは1時間出したままにする。押しても何も起きない。
enum NoticeCatalog {
    private static let url = URL(string: "https://x.example/video.mp4") ?? URL(filePath: "/")

    @MainActor
    static func states() -> [CatalogState] {
        let disclosure = Notice.Action.disclosure(hint: "続きを見られます。") {}
        return [
            CatalogState(title: "写真に保存しました（数秒で消える）") { stack(transient: .savedToPhotos) },
            CatalogState(title: "ダウンロード中（大きさが分かる前）") { stack(persistent: .download(of: url, fraction: 0) {}) },
            CatalogState(title: "ダウンロード中（押すと止めるかの確認）") { stack(persistent: .download(of: url, fraction: 0.42) {}) },
            CatalogState(title: "ダウンロードを終えて保存している間（押せない）") { stack(persistent: .download(of: url, fraction: 1, onStop: nil)) },
            CatalogState(title: "アップロード中") { stack(persistent: draft(.uploading)) },
            CatalogState(title: "サーバーで処理中") { stack(persistent: draft(.processing)) },
            CatalogState(title: "代替テキストを送信中") { stack(persistent: draft(.sendingDescription)) },
            CatalogState(title: "アップロードできませんでした（押すと理由）") { stack(persistent: draft(.failed)) },
            CatalogState(title: "代替テキストを送信できませんでした（押すと理由）") { stack(persistent: draft(.descriptionFailed)) },
            CatalogState(title: "出たままの知らせが2件") {
                var notice = Notice.download(of: url, fraction: 0.42) {}
                notice.additionalCount = 1
                return stack(persistent: notice)
            },
            CatalogState(title: "長い文言") {
                stack(transient: Notice(id: "long", kind: .success, title: "長い文言のときに幅がどこまで広がるかを確かめるための文"))
            },
            CatalogState(title: "長い文言でも件数と「›」を残す") {
                stack(persistent: Notice(id: "long", kind: .failure, title: "長い文言のときに件数と印が残るかを確かめるための文", additionalCount: 12, action: disclosure))
            },
            CatalogState(title: "出たままと数秒で消えるものを並べる") {
                stack(persistent: .download(of: url, fraction: 0.42) {}, transient: .savedToPhotos)
            },
            CatalogState(title: "画面をタップしてボタン類を隠したとき（失敗は場所を空けて薄くする）") {
                stack(persistent: draft(.failed), transient: .savedToPhotos, chromeHidden: true)
            },
        ]
    }

    @MainActor
    private static func draft(_ status: ComposeAttachmentStatus) -> Notice? {
        Notice.draftStatus(status) {}
    }

    @MainActor
    private static func stack(persistent: Notice? = nil, transient: Notice? = nil, chromeHidden: Bool = false) -> UIView {
        let stack = NoticeStackView()
        stack.animationDuration = 0
        stack.setPersistent(persistent)
        if let transient {
            stack.showTransient(transient, duration: 3600)
        }
        stack.setChromeHidden(chromeHidden, animated: false)
        return CatalogBackdrop.image(stack) { backdrop, stack in
            [
                stack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 24),
                stack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -24),
                // ビューアと同じく、左右に16ずつ空ける。
                stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -16),
            ]
        }
    }
}
#endif
