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
