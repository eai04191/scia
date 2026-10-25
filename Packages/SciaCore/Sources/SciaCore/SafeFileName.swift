public import Foundation

/// フォルダーの中に置くファイルやフォルダーの、1段分の名前。
///
/// 名前は、サーバーが決めるURLの最後の部分（`%2F`で区切りを入れられる）や、ほかのアプリから受け取ったファイルの名前から作ることが多い。
/// そのままフォルダーにつなげると、`/`や`..`で置く場所がフォルダーの外へ出たり、先頭の`.`で隠しファイルになって、置いたものを見つけられなくなったりする。
/// どんな文字列から作っても、つなげた先がそのフォルダーの直下に収まる名前にする。
public struct SafeFileName: Sendable, Hashable, CustomStringConvertible {
    public let value: String

    /// ファイルシステムが1段の名前に許す長さ（バイト）。APFSでは255。
    static let maxByteCount = 255

    /// 区切りの`/`とNULを外し、先頭の`.`を外す。`..`も`.`だけの名前も残らない。長すぎれば縮める。
    /// - Parameter fallback: 外すと何も残らないときに使う名前。これも同じく確かめ、それでも何も残らなければ`file`にする。
    public init(_ raw: String, fallback: String = "file") {
        value = Self.sanitized(raw) ?? Self.sanitized(fallback) ?? "file"
    }

    public var description: String { value }

    /// 直下に収まる名前。何も残らなければnil。
    private static func sanitized(_ raw: String) -> String? {
        let name = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0 != "/" && $0 != "\0" })).drop { $0 == "." }
        guard !name.isEmpty else { return nil }
        let truncated = truncated(String(name))
        return truncated.isEmpty || truncated.hasPrefix(".") ? nil : truncated
    }

    /// 長すぎる名前は、拡張子を残して前の部分を縮める。拡張子を残すと前の部分が残らないとき（拡張子が長い、1つの書記素が長い）は、名前ごと縮める。
    /// 書記素ではなくUnicodeのスカラー値で縮める。結合文字を重ねた1つの書記素でも長さを超えうるため。
    private static func truncated(_ name: String) -> String {
        guard name.utf8.count > maxByteCount else { return name }
        let pathExtension = (name as NSString).pathExtension
        if !pathExtension.isEmpty {
            let suffix = ".\(pathExtension)"
            let base = prefix(of: String(name.unicodeScalars.dropLast(suffix.unicodeScalars.count)), byteCount: maxByteCount - suffix.utf8.count)
            if !base.isEmpty {
                return base + suffix
            }
        }
        return prefix(of: name, byteCount: maxByteCount)
    }

    /// `byteCount`バイト以内に収まる、先頭からのスカラー値。
    private static func prefix(of string: String, byteCount: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var count = 0
        for scalar in string.unicodeScalars {
            count += String(scalar).utf8.count
            guard count <= byteCount else { break }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}

extension URL {
    /// 直下に`name`を置く場所。
    public func appending(fileName name: SafeFileName, directoryHint: DirectoryHint = .inferFromPath) -> URL {
        appending(path: name.value, directoryHint: directoryHint)
    }
}
