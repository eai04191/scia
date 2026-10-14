import SciaCore
import UIKit

/// 投稿と通知のセルの中身。標準のリストの見た目の下に、添付ファイルのサムネイルを並べる。
struct StatusContentConfiguration: UIContentConfiguration {
    var list: UIListContentConfiguration
    /// 添付ファイルがなければnil。
    var media: MediaGridView.Content?
    let mediaImages: MediaImageStore
    /// サムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var onSelectMedia: ((Int, MediaGridView) -> Void)?
    var onRevealMedia: (() -> Void)?

    func makeContentView() -> any UIView & UIContentView {
        StatusContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> StatusContentConfiguration {
        var configuration = self
        configuration.list = list.updated(for: state)
        return configuration
    }
}

final class StatusContentView: UIView, UIContentView {
    /// 本文とサムネイルのあいだの余白。
    private static let mediaSpacing: CGFloat = 8

    private let listView: UIListContentView
    private let mediaView: MediaGridView
    private var current: StatusContentConfiguration
    /// サムネイルを出していないときの制約。
    private var listBottom: NSLayoutConstraint?
    /// サムネイルを出しているときの制約。並べ方と本文の位置で変わるため、適用のたびに作り直す。
    private var mediaConstraints: [NSLayoutConstraint] = []

    var configuration: any UIContentConfiguration {
        get { current }
        set {
            guard let configuration = newValue as? StatusContentConfiguration else { return }
            apply(configuration)
        }
    }

    /// 表示中のサムネイル。ビューアの拡大と縮小の起点を探すときに使う。
    var mediaGrid: MediaGridView? {
        mediaView.isHidden ? nil : mediaView
    }

    init(configuration: StatusContentConfiguration) {
        current = configuration
        listView = UIListContentView(configuration: configuration.list)
        mediaView = MediaGridView(store: configuration.mediaImages)
        super.init(frame: .zero)
        for view in [listView, mediaView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: topAnchor),
            listView.leadingAnchor.constraint(equalTo: leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        mediaView.onSelect = { [weak self] index in
            guard let self else { return }
            self.current.onSelectMedia?(index, self.mediaView)
        }
        mediaView.onReveal = { [weak self] in self?.current.onRevealMedia?() }
        apply(configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 本文の左端の、余白の内側からの距離。通知では左に種類のアイコンがあるため、その分だけ下げる。
    ///
    /// `UIListContentView`の`secondaryTextLayoutGuide`に制約を張れば同じ位置に揃うが、そうすると最初の高さの見積もりで本文が
    /// 狭い幅で折り返され、表示した後に行の高さが変わる。そのため、アイコンに確保する幅と余白から計算する。
    private static func textIndent(of list: UIListContentConfiguration) -> CGFloat {
        guard let image = list.image else { return 0 }
        let reserved = list.imageProperties.reservedLayoutSize.width
        return (reserved > 0 ? reserved : image.size.width) + list.imageToTextPadding
    }

    private func apply(_ configuration: StatusContentConfiguration) {
        current = configuration
        NSLayoutConstraint.deactivate(mediaConstraints)
        mediaConstraints = []
        listBottom?.isActive = false
        guard let media = configuration.media, let aspectRatio = media.aspectRatio else {
            listView.configuration = configuration.list
            mediaView.isHidden = true
            listBottom = listView.bottomAnchor.constraint(equalTo: bottomAnchor)
            listBottom?.isActive = true
            return
        }
        // 本文の下の余白を、サムネイルの下へ移す。
        var list = configuration.list
        let bottomMargin = list.directionalLayoutMargins.bottom
        list.directionalLayoutMargins.bottom = 0
        listView.configuration = list
        mediaView.isHidden = false
        mediaView.apply(media)
        mediaConstraints = [
            mediaView.topAnchor.constraint(equalTo: listView.bottomAnchor, constant: Self.mediaSpacing),
            mediaView.leadingAnchor.constraint(equalTo: listView.layoutMarginsGuide.leadingAnchor, constant: Self.textIndent(of: list)),
            // リストの右の余白は左より狭く、本文の折り返しに合わせると区切り線より右へはみ出すため、左と同じ幅を空ける。
            mediaView.trailingAnchor.constraint(equalTo: listView.trailingAnchor, constant: -list.directionalLayoutMargins.leading),
            mediaView.heightAnchor.constraint(equalTo: mediaView.widthAnchor, multiplier: 1 / aspectRatio),
            bottomAnchor.constraint(equalTo: mediaView.bottomAnchor, constant: bottomMargin),
        ]
        NSLayoutConstraint.activate(mediaConstraints)
    }
}
