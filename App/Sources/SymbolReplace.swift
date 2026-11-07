import Symbols
import UIKit

extension UIButton {
    /// 部品の状態を表すアイコンを、状態に合わせてその場で替える（押したときの操作を表すアイコンには使わない。docs/vision.mdの「画面の中のものの振る舞い」）。前後のアイコンが共通の形を持てば（スラッシュや塗りの有無など）その形を残して変形し、
    /// 持たなければ前のアイコンを縮めて新しいアイコンを育てる。一コマで差し替えると、同じボタンが別のものに替わったように見えるため。
    ///
    /// 押している間に替えると、押した見た目から戻るときの描き直しで、前のアイコンが縮まずに一コマで消え、何もない間ができる（録画で確かめた）。
    /// そこで押した見た目が戻ってから替える。戻るのは指を離したときに限らない。メニューを出すボタンは、メニューを開いている間押した見た目のままで、
    /// 閉じても指を離したイベントは届かない（メニューから絞り込みを選んで確かめた）。そのため、状態が変わるたびに呼ばれる`configurationUpdateHandler`で戻るのを待つ。
    /// 待つ間に替える先が変わったら、最後のものだけを替える。押していないときに替えたら、待っていたものは捨てる。
    /// ほかの用途で`configurationUpdateHandler`を持つボタンには使えない。
    func replaceSymbol(with image: UIImage?) {
        guard isHighlighted else {
            if configurationUpdateHandler != nil { configurationUpdateHandler = nil }
            applySymbol(image)
            return
        }
        configurationUpdateHandler = { button in
            guard !button.isHighlighted else { return }
            button.configurationUpdateHandler = nil
            button.applySymbol(image)
        }
    }

    private func applySymbol(_ image: UIImage?) {
        var configuration = configuration
        configuration?.symbolContentTransition = UISymbolContentTransition(.replace.magic(fallback: .replace))
        configuration?.image = image
        self.configuration = configuration
    }
}
