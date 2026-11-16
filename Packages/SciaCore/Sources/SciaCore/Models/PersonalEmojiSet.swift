import Foundation

/// 自分で選んだ絵文字を並べた、Fedibirdの個人セット（docs/personal-emoji-set.md）。`api/v1/emoji_sets/personal/stock`の応答。
/// 使えなくなった絵文字は、サーバーが除いて返す。
/// fedibird/mastodonの`app/lib/personal_emoji_sets/stock.rb`
public struct PersonalEmojiSet: Decodable, Equatable, Sendable {
    /// カテゴリーの見出し。Fedibirdの設定で、先頭の絵文字、名前の先頭の1文字、カテゴリーの中の絵文字の1つから選ぶ。サーバーが選んだ結果を返す。
    public enum Heading: Equatable, Sendable {
        case emoji(PaletteEmoji)
        /// 名前の先頭の1文字。絵文字を使う設定でも、その絵文字が使えなくなっていればこれになる。
        case text(String)
    }

    public struct Category: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let heading: Heading
        public let entries: [Entry]

        /// - Parameter heading: 省くと、名前の先頭の1文字。
        public init(id: String, name: String, heading: Heading? = nil, entries: [Entry]) {
            self.id = id
            self.name = name
            self.heading = heading ?? .text(String(name.prefix(1)))
            self.entries = entries
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, heading, items
        }

        private enum HeadingKeys: String, CodingKey {
            case text, image
        }

        private enum HeadingImageKeys: String, CodingKey {
            case alt
        }

        /// 同じ絵文字は、先に来た1件だけを残す。絵文字のパレットは、1つのまとまりに同じ絵文字を2つ並べられないため。
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            var seen: Set<String> = []
            let entries = try container.decodeLossyArray(Entry.self, forKey: .items).filter { seen.insert($0.emoji.recentKey).inserted }
            self.entries = entries
            heading = Self.heading(in: container, entries: entries) ?? .text(String(name.prefix(1)))
        }

        /// 見出しの絵文字は、応答の`image.alt`（カスタム絵文字は`:shortcode:`、Unicodeの絵文字はその文字）で、カテゴリーの中の絵文字から探す。
        /// サーバーは、見出しをカテゴリーの中の使える絵文字からだけ選ぶ。見つからなければ文字にする。読めなければnil。
        private static func heading(in container: KeyedDecodingContainer<CodingKeys>, entries: [Entry]) -> Heading? {
            guard let heading = try? container.nestedContainer(keyedBy: HeadingKeys.self, forKey: .heading) else { return nil }
            if let image = try? heading.nestedContainer(keyedBy: HeadingImageKeys.self, forKey: .image), let alt = try? image.decode(String.self, forKey: .alt) {
                let key = alt.count > 2 && alt.hasPrefix(":") && alt.hasSuffix(":") ? String(alt.dropFirst().dropLast()) : alt
                if let entry = entries.first(where: { $0.emoji.recentKey == key }) {
                    return .emoji(entry.emoji)
                }
            }
            guard let text = try? heading.decode(String.self, forKey: .text), !text.isEmpty else { return nil }
            return .text(text)
        }
    }

    public struct Entry: Decodable, Equatable, Sendable {
        public let emoji: PaletteEmoji
        /// 検索で比べる語。カスタム絵文字ではショートコード、別名、読み。
        public let searchTerms: [String]

        public init(emoji: PaletteEmoji, searchTerms: [String] = []) {
            self.emoji = emoji
            self.searchTerms = searchTerms
        }

        private enum CodingKeys: String, CodingKey {
            case label, image, search, selection
        }

        private enum ImageKeys: String, CodingKey {
            case src, animatedSrc, width, height
        }

        private enum SelectionKeys: String, CodingKey {
            case id, custom, native
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let selection = try container.nestedContainer(keyedBy: SelectionKeys.self, forKey: .selection)
            let terms = (try? container.decodeIfPresent([String].self, forKey: .search)) ?? []
            searchTerms = terms
            if try selection.decode(Bool.self, forKey: .custom) {
                let image = try container.nestedContainer(keyedBy: ImageKeys.self, forKey: .image)
                let staticURL = try image.decodeRequiredURL(.media, forKey: .src)
                let width = (try? image.decodeCountIfPresent(forKey: .width)) ?? nil
                let height = (try? image.decodeCountIfPresent(forKey: .height)) ?? nil
                let aspectRatio: Double? = if let width, let height, width > 0, height > 0 { Double(width) / Double(height) } else { nil }
                emoji = .custom(ServerEmoji(
                    shortcode: try selection.decode(String.self, forKey: .id),
                    url: image.decodeURL(.media, forKey: .animatedSrc) ?? staticURL,
                    staticUrl: staticURL,
                    aspectRatio: aspectRatio
                ))
            } else {
                let native = try selection.decode(String.self, forKey: .native)
                guard !native.isEmpty else {
                    throw DecodingError.dataCorruptedError(forKey: .native, in: selection, debugDescription: "絵文字が空です")
                }
                let label = (try? container.decodeIfPresent(String.self, forKey: .label)) ?? nil
                emoji = .standard(StandardEmoji(emoji: native, name: label ?? native, keywords: terms, version: ""))
            }
        }
    }

    public let categories: [Category]

    public init(categories: [Category]) {
        self.categories = categories
    }

    private enum CodingKeys: String, CodingKey {
        case stock
    }

    private enum StockKeys: String, CodingKey {
        case categories
    }

    public init(from decoder: any Decoder) throws {
        let stock = try decoder.container(keyedBy: CodingKeys.self).nestedContainer(keyedBy: StockKeys.self, forKey: .stock)
        categories = try stock.decodeLossyArray(Category.self, forKey: .categories)
    }
}
