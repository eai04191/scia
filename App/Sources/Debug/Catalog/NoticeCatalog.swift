#if DEBUG
import SciaCore
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
            CatalogState(title: "ダウンロード中（ほかの添付ファイルも落としている。押すと操作の状況の一覧）") {
                var notice = Notice.download(of: url, fraction: 0.42) {}
                notice.additionalCount = 2
                notice.action = disclosure
                return stack(persistent: notice)
            },
            CatalogState(title: "ダウンロード中（見ている添付ファイルにはなく、件数だけ）") { stack(persistent: .downloads(count: 1, action: disclosure)) },
            CatalogState(title: "ダウンロード中（件数が多い）") { stack(persistent: .downloads(count: 12, action: disclosure)) },
            CatalogState(title: "見ている添付ファイルを落とせなかった（数秒で消える、押すと理由）") {
                stack(transient: .transferFailure(title: Notice.currentTransferFailureTitle(.download(URLError(.notConnectedToInternet)))) {})
            },
            CatalogState(title: "見ている添付ファイルを写真に足せなかった") {
                stack(transient: .transferFailure(title: Notice.currentTransferFailureTitle(.save(CocoaError(.fileWriteOutOfSpace)))) {})
            },
            CatalogState(title: "ほかの添付ファイルの失敗（種類で示す）") {
                stack(persistent: .download(of: url, fraction: 0.42) {}, transient: .transferFailure(title: Notice.transferFailureTitle(of: .gifv, purpose: .share)) {})
            },
            CatalogState(title: "共有を止めました（数秒で消える）") { stack(transient: .shareStopped) },
            CatalogState(title: "書き出し中（23%）") { stack(persistent: Notice.draftStatus(.exporting, progress: 0.23) {}) },
            CatalogState(title: "アップロード中") { stack(persistent: draft(.uploading)) },
            CatalogState(title: "アップロード中（67%）") { stack(persistent: Notice.draftStatus(.uploading, progress: 0.67) {}) },
            CatalogState(title: "サーバーの上限に合わせて縮めた（大きさ、容量）") {
                stack(persistent: Notice.draftStatus(.ready, reduction: MediaReduction(
                    fromSize: PixelSize(width: 8064, height: 6048), toSize: PixelSize(width: 6640, height: 4980), fromByteCount: 24_000_000, toByteCount: 15_800_000
                )) {})
            },
            CatalogState(title: "品質だけを下げて縮めた（容量）") {
                stack(persistent: Notice.draftStatus(.ready, reduction: MediaReduction(
                    fromSize: PixelSize(width: 4032, height: 3024), toSize: PixelSize(width: 4032, height: 3024), fromByteCount: 18_200_000, toByteCount: 15_100_000
                )) {})
            },
            CatalogState(title: "画像をサーバーの上限に合わせて縮めました（数秒で消える）") { stack(transient: .mediaReduced(.image)) },
            CatalogState(title: "動画をサーバーの上限に合わせて縮めました（数秒で消える）") { stack(transient: .mediaReduced(.video)) },
            CatalogState(title: "サーバーで処理中") { stack(persistent: draft(.processing)) },
            CatalogState(title: "代替テキストを送信中") { stack(persistent: draft(.sendingDescription)) },
            CatalogState(title: "アップロードできませんでした（押すと理由）") { stack(persistent: draft(.failed)) },
            CatalogState(title: "代替テキストを送信できませんでした（押すと理由）") { stack(persistent: draft(.descriptionFailed)) },
            CatalogState(title: "出たままの知らせが2件（処理の途中、押すと操作の状況の一覧）") {
                var notices = PersistentNotices()
                notices.set(.download(of: url, fraction: 0.42) {}, in: .download)
                notices.set(Notice(id: "other", kind: .progress, title: "アップロード中"), in: .screen)
                return stack(persistent: notices.chipNotice {})
            },
            CatalogState(title: "出たままの知らせが2件（失敗を優先する）") {
                var notices = PersistentNotices()
                notices.set(draft(.failed), in: .screen)
                notices.set(.download(of: url, fraction: 0.42) {}, in: .download)
                return stack(persistent: notices.chipNotice {})
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
