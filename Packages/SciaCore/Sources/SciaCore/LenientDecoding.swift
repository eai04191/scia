import Foundation
import os

/// 開発者が試していないサーバーが、表示のための項目を空や欠落で返しても、投稿やアカウントそのものは読めるようにする。
/// 欠かせない項目（IDや本文など）には使わない。読めなければ、それを含むものごと読めないものとして扱う。
extension KeyedDecodingContainer {
    /// 表示のためのURLを読む。項目がない、null、空、URLとして読めない値はnilにする。
    func decodeDisplayURL(forKey key: Key) -> URL? {
        guard let string = try? decodeIfPresent(String.self, forKey: key), !string.isEmpty else { return nil }
        return URL(string: string)
    }

    /// 配列を要素ごとに読み、読めない要素は外して記録する。項目がない、またはnullなら空にする。
    /// 配列でない値が入っていたら投げる。
    func decodeLossyArray<Element: Decodable>(_ type: Element.Type, forKey key: Key) throws -> [Element] {
        guard let elements = try decodeIfPresent([Lossy<Element>].self, forKey: key) else { return [] }
        return elements.compactMap(\.value)
    }
}

/// 一覧を要素ごとに読む。読めない要素は、IDが読めれば`UnreadableItem`として残し、IDも読めなければ外して記録する。
///
/// IDも読めない要素は、一覧に場所を取れず、続きを読む位置にも使えない。1ページの全部がIDも読めない要素だと、空のページと同じに見えて
/// 読み切ったと判断してしまう。それを避けるには`Link`ヘッダーで続きをたどる必要があるが、IDすら返さないサーバーは考えにくいため、そこまではしない。
struct ElementList<Element: Decodable>: Decodable {
    let elements: [Element]
    let unreadable: [UnreadableItem]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var unreadable: [UnreadableItem] = []
        while !container.isAtEnd {
            switch try container.decode(ListElement<Element>.self) {
            case .readable(let element): elements.append(element)
            case .unreadable(let item): unreadable.append(item)
            case .unidentifiable: break
            }
        }
        self.elements = elements
        self.unreadable = unreadable
    }
}

/// 一覧の要素1つ。読めなくても投げず、読めたところまでを返す。投げると、その後ろの要素へ進めないため。
private enum ListElement<Element: Decodable>: Decodable {
    case readable(Element)
    case unreadable(UnreadableItem)
    case unidentifiable

    init(from decoder: any Decoder) {
        do {
            self = .readable(try Element(from: decoder))
        } catch {
            DecodingLog.dropped(Element.self, at: decoder.codingPath, error)
            guard let identity = try? Identity(from: decoder) else {
                self = .unidentifiable
                return
            }
            self = .unreadable(UnreadableItem(id: identity.id, url: identity.url))
        }
    }

    /// 読めなかった要素から、一覧に並べるのに要るものだけを読む。
    private struct Identity: Decodable {
        let id: String
        let url: URL?

        private enum CodingKeys: String, CodingKey {
            case id, url, status
        }

        /// 投稿ならその投稿のURL、通知なら対象の投稿のURLを読む。
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            url = container.decodeDisplayURL(forKey: .url)
                ?? (try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .status))?.decodeDisplayURL(forKey: .url)
        }
    }
}

/// 読めなければnilになる要素。読めなかったことは記録する。
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) {
        do {
            value = try Value(from: decoder)
        } catch {
            DecodingLog.dropped(Value.self, at: decoder.codingPath, error)
            value = nil
        }
    }
}

/// 読めずに外したものの記録。どのサーバーの何が原因だったかを、違和感レポートから追えるようにする。
enum DecodingLog {
    private static let logger = SciaLog.logger(category: "decoding")

    static func dropped(_ type: Any.Type, at path: [any CodingKey], _ error: any Error) {
        logger.error("dropped \(String(describing: type), privacy: .public) at \(describe(path), privacy: .public): \(describe(error), privacy: .public)")
    }

    static func describe(_ path: [any CodingKey]) -> String {
        path.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
    }

    /// 値の中身は残さず、どの項目がどう読めなかったかだけを書く。
    static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return String(describing: type(of: error)) }
        return switch error {
        case .typeMismatch(let type, let context): "typeMismatch(\(type)) at \(describe(context.codingPath))"
        case .valueNotFound(let type, let context): "valueNotFound(\(type)) at \(describe(context.codingPath))"
        case .keyNotFound(let key, let context): "keyNotFound(\(key.stringValue)) at \(describe(context.codingPath))"
        case .dataCorrupted(let context): "dataCorrupted at \(describe(context.codingPath))"
        @unknown default: "unknown"
        }
    }
}
