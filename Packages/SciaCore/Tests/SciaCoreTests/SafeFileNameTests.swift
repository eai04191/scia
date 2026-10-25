import Foundation
import Testing
@testable import SciaCore

/// どんな文字列から作った名前でも、つなげた先がフォルダーの直下に収まることを確かめる。
struct SafeFileNameTests {
    private let folder = URL(filePath: "/tmp/scia/folder/", directoryHint: .isDirectory)

    @Test(arguments: [
        "../../escaped.png", "..", ".", "", "/", "//", "/etc/hosts", "a/../../b", ".hidden", "...", "../", "a\0/../b",
        ".partial-x", "~/x", String(repeating: "あ", count: 300) + ".png", String(repeating: "a", count: 300), "a." + String(repeating: "b", count: 300),
    ])
    func staysDirectlyInsideTheFolder(raw: String) {
        let name = SafeFileName(raw)
        let url = folder.appending(fileName: name)

        #expect(url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL, "\(raw)が\(url.path)になりました")
        #expect(url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path))
        #expect(!name.value.isEmpty)
        #expect(!name.value.hasPrefix("."))
        #expect(!name.value.contains("/"))
        #expect(name.value.utf8.count <= SafeFileName.maxByteCount)
    }

    /// ふつうの名前は、共有先でファイル名として見えるため、そのまま残す。
    @Test(arguments: ["a.mp4", "IMG_0001.HEIC", "写真 1.jpg", "a.b.c", "cropped-1-a.png"])
    func keepsOrdinaryNames(raw: String) {
        #expect(SafeFileName(raw).value == raw)
    }

    @Test func emptyNameUsesFallback() {
        #expect(SafeFileName("..", fallback: "media").value == "media")
    }

    /// 代わりの名前も同じく確かめる。確かめずに使うと、型を通しても外へ出る名前を作れてしまう。
    @Test(arguments: ["../escape", "..", "", ".hidden", "/"])
    func fallbackIsAlsoMadeSafe(fallback: String) {
        let name = SafeFileName("..", fallback: fallback)

        #expect(folder.appending(fileName: name).deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(!name.value.isEmpty)
        #expect(!name.value.hasPrefix("."))
    }

    /// 1つの書記素だけで長さを超える名前でも、縮めた結果が拡張子だけ（隠しファイル）にならない。
    @Test func truncatingASingleLongGraphemeKeepsABaseName() {
        let name = SafeFileName("a" + String(repeating: "\u{301}", count: 128) + ".png")

        #expect(!name.value.hasPrefix("."))
        // 拡張子で画像かどうかを決めるところがあるため、拡張子も残す。
        #expect(name.value.hasSuffix(".png"))
        #expect(name.value.utf8.count <= SafeFileName.maxByteCount)
    }

    /// 長すぎる名前は、拡張子を残して縮める。
    @Test func longNameKeepsItsExtension() {
        let name = SafeFileName(String(repeating: "あ", count: 300) + ".png")

        #expect(name.value.hasSuffix(".png"))
        #expect(name.value.utf8.count <= SafeFileName.maxByteCount)
    }
}
