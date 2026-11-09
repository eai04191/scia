import SciaCore
import UIKit
@testable import Scia

/// 「投稿の見た目」と「通知の見た目」の見本の行の中身。
protocol AppearancePreviewConfiguration: UIContentConfiguration {
    /// タイムラインと同じく、この行の下に区切り線を引くか。
    var drawsPreviewSeparatorBelow: Bool { get }
    @MainActor func makePreviewRow() -> any AppearancePreviewRow
}

/// 見本の行のビュー。部品の枠を返す。
@MainActor
protocol AppearancePreviewRow: UIView, UIContentView {
    func previewFrames() -> AppearancePreviewFrames
}

/// 見本の行を、タイムラインと同じ部品で縦に並べるビュー。テストで、見本の部品の位置と見本の高さを測り、行を画像にするのに使う。
/// アプリのプレビューは見本をタイムライン（`AppearanceTimelinePreviewController`）に並べるが、
/// テストでは行ごとの部品の枠を行の座標で読めるよう、行のビューを直接並べる。
final class AppearancePreviewView: UIView {
    private let stack = UIStackView()
    private var rows: [any AppearancePreviewRow] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// - Parameter showsSeparators: タイムラインと同じく、行のあいだに区切り線を引く。引かないときも、行の位置が変わらないよう、線を透明にして残す。
    func apply(_ configurations: [any AppearancePreviewConfiguration], showsSeparators: Bool = true) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = configurations.map { $0.makePreviewRow() }
        for (index, row) in rows.enumerated() {
            stack.addArrangedSubview(row)
            if index < rows.count - 1, configurations[index].drawsPreviewSeparatorBelow {
                let separator = UIView()
                separator.backgroundColor = .separator
                separator.alpha = showsSeparators ? 1 : 0
                separator.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)).isActive = true
                stack.addArrangedSubview(separator)
            }
        }
    }

    /// 並べた見本の高さ。
    var contentHeight: CGFloat {
        stack.frame.height
    }

    /// 見本の行。行を画像にして確かめるときに使う。
    var rowViews: [any AppearancePreviewRow] {
        rows
    }

    /// 見本の行ごとの、部品の枠。
    func rowFrames() -> [AppearancePreviewFrames] {
        rows.map { $0.previewFrames() }
    }
}

// 返信でつながった行は、線が切れて見えないよう区切り線を引かない。
extension PostContentConfiguration: AppearancePreviewConfiguration {
    var drawsPreviewSeparatorBelow: Bool {
        !replyConnection.below
    }

    func makePreviewRow() -> any AppearancePreviewRow {
        PostContentView(configuration: self)
    }
}

extension PostContentView: AppearancePreviewRow {}

extension NotificationContentConfiguration: AppearancePreviewConfiguration {
    var drawsPreviewSeparatorBelow: Bool {
        true
    }

    func makePreviewRow() -> any AppearancePreviewRow {
        NotificationContentView(configuration: self)
    }
}

extension NotificationContentView: AppearancePreviewRow {}
