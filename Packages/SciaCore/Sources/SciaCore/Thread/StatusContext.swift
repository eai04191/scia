/// 投稿の前後の会話。
/// https://docs.joinmastodon.org/entities/Context/
public struct StatusContext: Decodable, Sendable {
    /// 返信先をたどった投稿。古い順。
    public let ancestors: [Status]
    /// この投稿への返信と、その返信への返信。
    public let descendants: [Status]

    public init(ancestors: [Status], descendants: [Status]) {
        self.ancestors = ancestors
        self.descendants = descendants
    }

    /// 読めない投稿があっても、読めた投稿だけで会話を出す。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ancestors = try container.decode(ElementList<Status>.self, forKey: .ancestors).elements
        descendants = try container.decode(ElementList<Status>.self, forKey: .descendants).elements
    }

    private enum CodingKeys: String, CodingKey {
        case ancestors, descendants
    }
}
