public import CoreGraphics

/// プロフィールのヘッダー画像を置く場所。位置は、ヘッダーの上端（ナビゲーションバーの下端）を0とし、下向きを正とする。
///
/// 画像はバーの高さの分だけ上げ、ナビゲーションバーのボタンを画像の上に浮かせる。Mastodonのヘッダー画像は3:1を想定しているが、
/// サーバーは切り抜かずに保存するため、縦に長い画像も届く。縦に長い画像は、切り抜かずに本当の高さで見せ、上はステータスバーの下まで広げる。
/// それでも届かない画面の上端までの帯は、画像の上をぼかして伸ばして埋める。
public struct ProfileBannerLayout: Equatable, Sendable {
    /// 想定している縦横比（高さ÷幅）。これより横に長い画像は、この比になるよう左右を切る。
    public static let standardAspect = 1.0 / 3
    /// 本当の高さで見せる縦横比の上限。これより縦に長い画像は、ヘッダーが画面を占めすぎないよう、この比になるよう上下を切る。
    public static let maximumAspect = 3.0 / 4

    public let top: Double
    public let height: Double
    public var bottom: Double { top + height }

    public init(top: Double, height: Double) {
        self.top = top
        self.height = height
    }

    /// - Parameters:
    ///   - imageAspect: 画像の縦横比（高さ÷幅）。読み込む前はnilで、想定している比として置く。
    ///   - liftsUnderBars: バーの下まで上げるか。ヘッダー画像がないアカウントでは、灰色の下地をバーの下に入れても見栄えがしないため上げない。
    public init(width: Double, imageAspect: Double?, statusBarHeight: Double, navigationBarHeight: Double, liftsUnderBars: Bool) {
        let standardHeight = width * Self.standardAspect
        guard liftsUnderBars else {
            self.init(top: 0, height: standardHeight)
            return
        }
        let aspect = min(max(imageAspect ?? Self.standardAspect, Self.standardAspect), Self.maximumAspect)
        let height = width * aspect
        // 画面の上端からの位置で決める。3:1の画像は、ステータスバーのすぐ下から置く。
        // それより縦に長い画像は、下端を変えずに上へ広げ、画面の上端に届いたら下へ広げる。
        let bottomFromScreenTop = max(statusBarHeight + standardHeight, height)
        let headerTopFromScreenTop = statusBarHeight + navigationBarHeight
        self.init(top: bottomFromScreenTop - height - headerTopFromScreenTop, height: height)
    }
}

extension ProfileBannerLayout {
    /// 縦横比（高さ÷幅）が`aspect`の枠に、縦横比を保って枠を埋めるように置いたとき、枠に見えている画像の範囲。
    /// 範囲は画像の画素で、左上を原点とする。
    public static func visibleRect(ofImageSized size: CGSize, inFrameWithAspect aspect: Double) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        let imageAspect = size.height / size.width
        if imageAspect > aspect {
            let height = size.width * aspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
        let width = size.height / aspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
    }
}
