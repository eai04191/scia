import Foundation

/// `multipart/form-data`の本文を組み立てる。
/// https://www.rfc-editor.org/rfc/rfc7578
struct MultipartFormData {
    let boundary: String
    private(set) var body = Data()

    init(boundary: String = "Scia-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func append(name: String, value: String) {
        appendPart(headers: ["Content-Disposition: form-data; name=\"\(Self.escape(name))\""], data: Data(value.utf8))
    }

    mutating func append(name: String, filename: String, mimeType: String, data: Data) {
        appendPart(
            headers: [
                "Content-Disposition: form-data; name=\"\(Self.escape(name))\"; filename=\"\(Self.escape(filename))\"",
                "Content-Type: \(mimeType)",
            ],
            data: data
        )
    }

    /// 最後の区切りを付けた本文。
    func finalized() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }

    private mutating func appendPart(headers: [String], data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        for header in headers {
            body.append(Data("\(header)\r\n".utf8))
        }
        body.append(Data("\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    /// RFC 7578の4.2のとおり、引用符と改行をパーセントエンコードする。
    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }
}
