#if DEBUG
import UIKit

/// 操作が済んだことを知らせる表示（`StatusChip`）の状態。ガラスの効果を見られるよう、画像の上に置く。
/// 本物は数秒で消えるため、カタログでは1時間出したままにする。
enum StatusChipCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            CatalogState(title: "写真に保存した") { chip("写真に保存しました") },
            CatalogState(title: "長い文言") { chip("長い文言のときに幅がどこまで広がるかを確かめるための文") },
        ]
    }

    @MainActor
    private static func chip(_ text: String) -> UIView {
        let chip = StatusChip()
        chip.show(text, systemImage: "checkmark.circle.fill", duration: 3600)
        return CatalogBackdrop.image(chip) { backdrop, chip in
            [
                chip.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 24),
                chip.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -24),
                chip.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
                chip.widthAnchor.constraint(lessThanOrEqualTo: backdrop.widthAnchor, constant: -32),
            ]
        }
    }
}
#endif
