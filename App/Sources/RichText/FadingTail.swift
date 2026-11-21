import SwiftUI

extension View {
    /// 1行に入りきらないときに、「…」で切らず、行末を透明へ向けてぼかす。入りきるときは何もかけない。タイムラインの名前（`FadingLabel`）と同じ見え方にする。
    /// 右から左に書く文字列では、行末は左端なので、文字列の頭を右端にそろえて左端をぼかす。画面の向きではなく、文字列の向きで決める。
    func fadingTail(of text: String) -> some View {
        let isRightToLeft = FadingLabel.isRightToLeft(text)
        return ViewThatFits(in: .horizontal) {
            self
            // 大きさは、ふつうに1行で切った見えない文字で決め、全文は重ねて描くだけにする。全文の幅を大きさにすると、候補のリストの幅まで広がるため。
            self
                .hidden()
                .frame(maxWidth: .infinity, alignment: isRightToLeft ? .trailing : .leading)
                .overlay(alignment: isRightToLeft ? .trailing : .leading) {
                    self.fixedSize(horizontal: true, vertical: false)
                }
                .clipped()
                .mask {
                    // FadingLabelの既定と同じく、行末の20ptをぼかす。
                    let fade = LinearGradient(colors: isRightToLeft ? [.clear, .black] : [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 20)
                    HStack(spacing: 0) {
                        if isRightToLeft { fade }
                        Color.black
                        if !isRightToLeft { fade }
                    }
                }
        }
    }
}
