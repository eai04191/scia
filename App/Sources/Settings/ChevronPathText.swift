import SciaCore
import SwiftUI

/// 画面の階層の名前を、シェブロンの記号でつないだ文字。前後に文を添えられる。
struct ChevronPathText: View {
    var before = ""
    let path: [String]
    var after = ""

    init(path: [String]) {
        self.path = path
    }

    init(_ text: PathText) {
        before = text.before
        path = text.path
        after = text.after
    }

    var body: some View {
        // 文字より小さいフォントで描くと、記号がベースラインに寄って文字の中心より下に見えるので、文字の大きさのまま、記号の小さいスケールで描く。
        let chevron = Text(Image(systemName: "chevron.forward"))
        let joined = path.dropFirst().reduce(Text(verbatim: path.first ?? "")) { text, name in
            Text("\(text) \(chevron) \(name)")
        }
        Text("\(before)\(joined)\(after)")
            .imageScale(.small)
    }
}
