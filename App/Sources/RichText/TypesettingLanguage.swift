import UIKit

extension UIView {
    /// アプリの文言の漢字とかなを、アプリが表示している言語の字形で描かせる。このビューの中のUIKitとSwiftUIの文字に届く。
    /// 文字列に言語がないと、システムは端末の言語の一覧から書体を選び、英語の設定では日本語の文言も中国語の書体で描かれるため。
    /// 投稿の本文や名前のように、文字列に言語を付けた部分は、その言語が優先される。
    ///
    /// UIKitの`typesettingLanguage`は言語の部分（ja、zh、ko）しか保たず、zh-Hantを渡しても簡体字の書体になる。
    /// 今のアプリの文言は日本語だけなので困らないが、繁体字の文言を足すと、UIKitの文言は簡体字の書体で描かれる。そのときは、文言に言語を付けて描く必要がある。
    /// SwiftUIの`typesettingLanguage`は繁体字を区別する。
    func useAppLanguage() {
        traitOverrides.typesettingLanguage = Bundle.main.appTypesettingLanguage
    }
}

extension Bundle {
    /// アプリの文言を表示している言語。文言のある言語のうち、端末の言語の一覧に合うもの。
    var appTypesettingLanguage: Locale.Language? {
        preferredLocalizations.first.map { Locale.Language(identifier: $0) }
    }
}
