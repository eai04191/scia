import Foundation
import Testing
@testable import SciaCore

struct AltTextFilterTests {
    private func attachment(description: String?) -> MediaAttachment {
        MediaAttachment(id: "1", type: .image, url: nil, previewUrl: nil, description: description)
    }

    @Test(arguments: [nil, "", " ", "\n", " \n\t"])
    func treatsBlankAsMissingEvenWhenNotIgnoringUseless(_ description: String?) {
        #expect(AltTextFilter.meaningful(description, ignoresUseless: false) == nil)
    }

    @Test(arguments: ["undefined", " undefined\n", "Screenshot", "screenshot", "SCREENSHOT", " Screenshot "])
    func ignoresUselessWhenEnabled(_ description: String) {
        #expect(AltTextFilter.meaningful(description, ignoresUseless: true) == nil)
        #expect(AltTextFilter.meaningful(description, ignoresUseless: false) == description)
    }

    /// undefinedは、JavaScriptで未設定の値を文字列にしたものだけを対象にし、大文字・小文字を区別する。
    /// 完全に一致するものだけを対象にし、説明の一部に含むものは残す。
    @Test(arguments: ["Undefined", "UNDEFINED", "Screenshot of the settings", "undefined behavior", "スクリーンショット"])
    func keepsOtherText(_ description: String) {
        #expect(AltTextFilter.meaningful(description, ignoresUseless: true) == description)
    }

    @Test func keepsOriginalTextWithoutTrimming() {
        #expect(AltTextFilter.meaningful(" 夕焼け\n", ignoresUseless: true) == " 夕焼け\n")
    }

    @Test func removesUselessAltTextFromAttachment() {
        #expect(attachment(description: "undefined").filteringAltText(ignoresUseless: true).description == nil)
        #expect(attachment(description: "夕焼け").filteringAltText(ignoresUseless: true) == attachment(description: "夕焼け"))
    }
}
