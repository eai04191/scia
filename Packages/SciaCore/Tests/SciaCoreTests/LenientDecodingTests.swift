import Foundation
import Testing
@testable import SciaCore

/// 開発者が試していないサーバーが、表示のための項目を空や欠落で返しても、投稿そのものは読めることを確かめる。
struct LenientDecodingTests {
    @Test func emptyOrNullAccountURLsBecomeNil() throws {
        let status = try decodeStatus { json in
            var account = try #require(json["account"] as? [String: Any])
            account["avatar"] = ""
            account["avatar_static"] = NSNull()
            account["header"] = ""
            account.removeValue(forKey: "header_static")
            account["url"] = ""
            json["account"] = account
        }

        #expect(status.account.avatar == nil)
        #expect(status.account.avatarStatic == nil)
        #expect(status.account.header == nil)
        #expect(status.account.headerStatic == nil)
        #expect(status.account.url == nil)
        #expect(status.account.username == "alice")
    }

    @Test func emptyStatusURLBecomesNil() throws {
        let status = try decodeStatus { json in json["url"] = "" }

        #expect(status.url == nil)
    }

    @Test func missingArraysBecomeEmpty() throws {
        let status = try decodeStatus { json in
            for key in ["mentions", "tags", "emojis", "media_attachments"] {
                json.removeValue(forKey: key)
            }
            var account = try #require(json["account"] as? [String: Any])
            account.removeValue(forKey: "emojis")
            account.removeValue(forKey: "fields")
            json["account"] = account
        }

        #expect(status.mentions.isEmpty)
        #expect(status.tags.isEmpty)
        #expect(status.emojis.isEmpty)
        #expect(status.mediaAttachments.isEmpty)
        #expect(status.account.emojis.isEmpty)
        #expect(status.account.fields.isEmpty)
    }

    /// 絵文字の画像が読めなければ、その絵文字だけを外す。本文には`:shortcode:`の文字のまま残る。
    @Test func emojiWithUnreadableImageIsDropped() throws {
        let status = try decodeStatus { json in
            json["emojis"] = [
                ["shortcode": "broken", "url": "", "static_url": "", "visible_in_picker": true],
                ["shortcode": "blobcat", "url": "https://example.social/emoji/blobcat.png", "static_url": "https://example.social/emoji/blobcat.png", "visible_in_picker": true],
            ]
        }

        #expect(status.emojis.map(\.shortcode) == ["blobcat"])
    }

    @Test func mentionAndTagWithoutURLAreKept() throws {
        let status = try decodeStatus { json in
            json["mentions"] = [["id": "2", "username": "bob", "url": "", "acct": "bob@remote.example"]]
            json["tags"] = [["name": "scia", "url": NSNull()]]
        }

        #expect(status.mentions.map(\.acct) == ["bob@remote.example"])
        #expect(status.mentions.first?.url == nil)
        #expect(status.tags.map(\.name) == ["scia"])
        #expect(status.tags.first?.url == nil)
    }

    @Test func attachmentWithEmptyURLsIsKept() throws {
        let status = try decodeStatus { json in
            json["media_attachments"] = [
                ["id": "9", "type": "image", "url": "", "preview_url": "", "remote_url": "", "description": NSNull(), "blurhash": NSNull()],
            ]
        }

        #expect(status.mediaAttachments.map(\.id) == ["9"])
        #expect(status.mediaAttachments.first?.url == nil)
        #expect(status.mediaAttachments.first?.previewUrl == nil)
        #expect(status.mediaAttachments.first?.remoteUrl == nil)
    }

    /// 投稿として欠かせない項目がなければ、投稿そのものを読めないものとして扱う。
    @Test func missingIDStillFails() throws {
        #expect(throws: DecodingError.self) {
            _ = try decodeStatus { json in json.removeValue(forKey: "id") }
        }
    }

    private func decodeStatus(_ modify: (inout [String: Any]) throws -> Void) throws -> Status {
        let url = try #require(Bundle.module.url(forResource: "status", withExtension: "json", subdirectory: "Fixtures"))
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        try modify(&json)
        return try MastodonDecoder.make().decode(Status.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
