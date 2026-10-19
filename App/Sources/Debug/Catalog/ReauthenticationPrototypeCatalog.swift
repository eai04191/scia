#if DEBUG
import UIKit

/// ログインし直しを、一覧の部品からアプリ内通知のオーバーレイへ移すときの形の試作。形を決めたら消す。
/// 下にダウンロード中のチップを並べ、チップの列と並んだときの見え方を比べる。
enum ReauthenticationPrototypeCatalog {
    private static let url = URL(string: "https://x.example/video.mp4") ?? URL(filePath: "/")
    private static let handles = [
        ("短いアカウント名", "@eai@stellaria.network"),
        ("長いアカウント名", "@a_rather_long_username_here@social.example-instance.com"),
    ]

    @MainActor
    static func states() -> [CatalogState] {
        handles.flatMap { label, handle in
            [
                CatalogState(title: "A. 今のボタン（\(label)）") { column(currentButton(handle: handle)) },
                CatalogState(title: "B. 1行のチップ（\(label)）") { column(singleLineChip(handle: handle)) },
                CatalogState(title: "C. 2行のガラスのカプセル、オレンジ（\(label)）") { column(glassCapsule(handle: handle, prominent: true)) },
                CatalogState(title: "D. 2行のガラスのカプセル、印だけオレンジ（\(label)）") { column(glassCapsule(handle: handle, prominent: false)) },
            ]
        }
    }

    @MainActor
    private static func currentButton(handle: String) -> UIView {
        var configuration = UIButton.Configuration.borderedProminent()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .systemOrange
        configuration.image = UIImage(systemName: "person.crop.circle.badge.exclamationmark")
        configuration.imagePadding = 8
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.subtitleLineBreakMode = .byTruncatingMiddle
        configuration.title = "ログインし直してください"
        configuration.subtitle = handle
        return UIButton(configuration: configuration)
    }

    @MainActor
    private static func singleLineChip(handle: String) -> UIView {
        let chip = NoticeChip()
        chip.apply(Notice(id: "reauth", kind: .failure, title: "ログインし直してください", value: handle, action: .immediate(hint: "ログインし直します。") {}))
        return chip
    }

    @MainActor
    private static func glassCapsule(handle: String, prominent: Bool) -> UIView {
        var configuration = prominent ? UIButton.Configuration.prominentGlass() : UIButton.Configuration.glass()
        configuration.cornerStyle = .capsule
        if prominent {
            configuration.baseBackgroundColor = .systemOrange
        }
        configuration.image = UIImage(systemName: "person.crop.circle.badge.exclamationmark")
        configuration.imageColorTransformer = prominent ? nil : UIConfigurationColorTransformer { _ in .systemOrange }
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
        configuration.imagePadding = 8
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.subtitleLineBreakMode = .byTruncatingMiddle
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        var title = AttributedString("ログインし直してください")
        title.font = .preferredFont(forTextStyle: .subheadline)
        configuration.attributedTitle = title
        configuration.subtitle = handle
        return UIButton(configuration: configuration)
    }

    /// 一覧の上に重ねたときに近い見え方にするため、行の代わりに灰色の帯を敷き、その上に試作とダウンロード中のチップを縦に並べる。
    @MainActor
    private static func column(_ reauthentication: UIView) -> UIView {
        let backdrop = UIView()
        backdrop.backgroundColor = .systemBackground
        let rows = UIStackView(arrangedSubviews: (0..<4).map { _ in
            let row = UIView()
            row.backgroundColor = .secondarySystemFill
            row.layer.cornerRadius = 6
            row.heightAnchor.constraint(equalToConstant: 28).isActive = true
            return row
        })
        rows.axis = .vertical
        rows.spacing = 12
        let stack = NoticeStackView()
        stack.animationDuration = 0
        stack.setPersistent(.download(of: url, fraction: 0.42) {})
        let column = UIStackView(arrangedSubviews: [reauthentication, stack])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 8
        stack.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        for view in [rows, column] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            backdrop.addSubview(view)
        }
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 16),
            rows.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 16),
            rows.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -8),
            // タイムラインと同じく、余白の内側に収める。
            column.leadingAnchor.constraint(equalTo: backdrop.layoutMarginsGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: backdrop.layoutMarginsGuide.trailingAnchor),
            reauthentication.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
        ])
        return backdrop
    }
}
#endif
