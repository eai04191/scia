// アップロードしたビルドを、App Store Connect APIでTestFlightの外部テストのグループに足し、TestFlight App Reviewに出す。
// 画面の設定でビルドを自動で配れるのは内部グループだけなので、外部グループへはAPIで足す。
// ビルドの処理が終わるのを待ってから、What to Testを入れ、承認されたらテスターに知らせる設定にして、グループに足して審査に出す。
// 同じバージョンのほかのビルドが審査を待っているか審査中なら、Appleはそのバージョンの次のビルドを審査に出させないため、外部には出さずに終える。
// 使い方: swift Tools/testflight-external.swift <アーカイブ>
// 環境変数: TESTFLIGHT_EXTERNAL_GROUP（外部グループの名前）、WHAT_TO_TEST_PATH（What to Testを書いたファイル）、
// APP_STORE_CONNECT_KEY_PATH（.p8のパス）、APP_STORE_CONNECT_KEY_ID、APP_STORE_CONNECT_ISSUER_ID
// グループの名前は、makeの変数やシェルの引数で渡すと$や'が解釈されるため、環境変数で受け取る

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("testflight-external: \(message)\n".utf8))
    exit(1)
}

func log(_ message: String) {
    print("testflight-external: \(message)")
}

func environment(_ name: String) -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        fail("環境変数\(name)がない")
    }
    return value
}

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 1, let archivePath = arguments.first else {
    fail("使い方: swift Tools/testflight-external.swift <アーカイブ>")
}

// アーカイブのInfo.plistから、上げたビルドのbundle IDとビルド番号を読む
func archivedApplication() -> (bundleID: String, buildNumber: String) {
    let url = URL(fileURLWithPath: archivePath).appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let properties = plist["ApplicationProperties"] as? [String: Any],
          let bundleID = properties["CFBundleIdentifier"] as? String,
          let buildNumber = properties["CFBundleVersion"] as? String
    else {
        fail("\(url.path)からbundle IDとビルド番号を読めない")
    }
    return (bundleID, buildNumber)
}

// App Store Connect APIのトークン。ES256で署名し、有効期限はAPIが受け付ける上限の20分より短くする
struct TokenSigner {
    let key: P256.Signing.PrivateKey
    let keyID: String
    let issuerID: String

    func token() -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let payload: [String: Any] = ["iss": issuerID, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"]
        let signingInput = "\(base64URL(json(header))).\(base64URL(json(payload)))"
        guard let signature = try? key.signature(for: Data(signingInput.utf8)) else {
            fail("トークンに署名できない")
        }
        return "\(signingInput).\(base64URL(signature.rawRepresentation))"
    }

    private func json(_ object: [String: Any]) -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            fail("トークンをJSONにできない")
        }
        return data
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct API {
    let signer: TokenSigner
    let base = "https://api.appstoreconnect.apple.com"

    func get(_ path: String, query: [String: String] = [:]) async -> [String: Any] {
        guard var components = URLComponents(string: base + path) else { fail("URLを作れない: \(path)") }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { fail("URLを作れない: \(path)") }
        return await send("GET", url, body: nil)
    }

    @discardableResult
    func send(_ method: String, _ path: String, body: [String: Any]) async -> [String: Any] {
        guard let url = URL(string: base + path) else { fail("URLを作れない: \(path)") }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { fail("本文をJSONにできない: \(path)") }
        return await send(method, url, body: data)
    }

    private func send(_ method: String, _ url: URL, body: Data?) async -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(signer.token())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            fail("\(method) \(url.path)に失敗: \(error)")
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { fail("\(method) \(url.path)の応答がHTTPでない") }
        guard (200..<300).contains(status) else {
            fail("\(method) \(url.path)が\(status)を返した: \(String(decoding: data, as: UTF8.self))")
        }
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fail("\(method) \(url.path)の応答を読めない")
        }
        return object
    }
}

func resources(_ response: [String: Any], _ key: String = "data") -> [[String: Any]] {
    response[key] as? [[String: Any]] ?? []
}

func onlyResource(_ response: [String: Any], _ description: String) -> [String: Any] {
    let items = resources(response)
    guard items.count == 1 else { fail("\(description)が\(items.count)件ある（1件のはず）") }
    return items[0]
}

func id(_ resource: [String: Any]) -> String {
    guard let id = resource["id"] as? String else { fail("IDのない応答: \(resource)") }
    return id
}

func attribute(_ resource: [String: Any], _ name: String) -> String? {
    (resource["attributes"] as? [String: Any])?[name] as? String
}

let application = archivedApplication()
let groupName = environment("TESTFLIGHT_EXTERNAL_GROUP")
let whatToTestPath = environment("WHAT_TO_TEST_PATH")
guard let whatToTest = try? String(contentsOfFile: whatToTestPath, encoding: .utf8) else {
    fail("\(whatToTestPath)を読めない")
}
let keyPath = environment("APP_STORE_CONNECT_KEY_PATH")
guard let keyPEM = try? String(contentsOfFile: keyPath, encoding: .utf8),
      let key = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM)
else {
    fail("\(keyPath)からAPIキーを読めない")
}
let api = API(signer: TokenSigner(
    key: key,
    keyID: environment("APP_STORE_CONNECT_KEY_ID"),
    issuerID: environment("APP_STORE_CONNECT_ISSUER_ID")
))

let appID = id(onlyResource(await api.get("/v1/apps", query: ["filter[bundleId]": application.bundleID]), "bundle ID \(application.bundleID)のアプリ"))
let groupID = id(onlyResource(
    await api.get("/v1/betaGroups", query: ["filter[app]": appID, "filter[name]": groupName, "filter[isInternalGroup]": "false"]),
    "外部グループ「\(groupName)」"
))

// アップロードしてすぐは一覧に出ず、出てからも処理が終わるまでグループに足せない。処理はふつう数分から十数分で終わる
func processedBuild() async -> (id: String, version: String) {
    let deadline = ContinuousClock.now + .seconds(40 * 60)
    while ContinuousClock.now < deadline {
        let response = await api.get("/v1/builds", query: [
            "filter[app]": appID,
            "filter[version]": application.buildNumber,
            "include": "preReleaseVersion",
        ])
        if let build = resources(response).first {
            switch attribute(build, "processingState") {
            case "VALID":
                guard let version = resources(response, "included").first(where: { $0["type"] as? String == "preReleaseVersions" })
                    .flatMap({ attribute($0, "version") })
                else {
                    fail("ビルド\(application.buildNumber)のバージョンを読めない")
                }
                return (id(build), version)
            case "FAILED", "INVALID":
                fail("ビルド\(application.buildNumber)の処理が\(attribute(build, "processingState") ?? "")で終わった")
            default:
                log("ビルド\(application.buildNumber)の処理を待っている（\(attribute(build, "processingState") ?? "一覧に出ていない")）")
            }
        } else {
            log("ビルド\(application.buildNumber)が一覧に出るのを待っている")
        }
        try? await Task.sleep(for: .seconds(30))
    }
    fail("ビルド\(application.buildNumber)の処理が40分で終わらなかった")
}

let build = await processedBuild()

let reviewing = resources(await api.get("/v1/builds", query: [
    "filter[app]": appID,
    "filter[preReleaseVersion.version]": build.version,
    "filter[betaAppReviewSubmission.betaReviewState]": "WAITING_FOR_REVIEW,IN_REVIEW",
]))
if let pending = reviewing.first {
    log("バージョン\(build.version)のビルド\(attribute(pending, "version") ?? id(pending))が審査を待っているか審査中なので、ビルド\(application.buildNumber)は外部に出さない")
    print("::notice::ビルド\(application.buildNumber)は、同じバージョンのほかのビルドが審査中なので外部テストに出していない")
    exit(0)
}

let localizations = resources(await api.get("/v1/builds/\(build.id)/betaBuildLocalizations"))
if let japanese = localizations.first(where: { attribute($0, "locale") == "ja" }) {
    await api.send("PATCH", "/v1/betaBuildLocalizations/\(id(japanese))", body: [
        "data": ["type": "betaBuildLocalizations", "id": id(japanese), "attributes": ["whatsNew": whatToTest]],
    ])
} else {
    await api.send("POST", "/v1/betaBuildLocalizations", body: [
        "data": [
            "type": "betaBuildLocalizations",
            "attributes": ["locale": "ja", "whatsNew": whatToTest],
            "relationships": ["build": ["data": ["type": "builds", "id": build.id]]],
        ],
    ])
}
log("What to Testを入れた")

guard let betaDetail = (await api.get("/v1/builds/\(build.id)/buildBetaDetail"))["data"] as? [String: Any] else {
    fail("ビルド\(application.buildNumber)のベータの設定を読めない")
}
let betaDetailID = id(betaDetail)
await api.send("PATCH", "/v1/buildBetaDetails/\(betaDetailID)", body: [
    "data": ["type": "buildBetaDetails", "id": betaDetailID, "attributes": ["autoNotifyEnabled": true]],
])

await api.send("POST", "/v1/betaGroups/\(groupID)/relationships/builds", body: [
    "data": [["type": "builds", "id": build.id]],
])
log("ビルド\(application.buildNumber)を外部グループ「\(groupName)」に足した")

await api.send("POST", "/v1/betaAppReviewSubmissions", body: [
    "data": [
        "type": "betaAppReviewSubmissions",
        "relationships": ["build": ["data": ["type": "builds", "id": build.id]]],
    ],
])
log("ビルド\(application.buildNumber)をTestFlight App Reviewに出した。承認されると外部のテスターに知らせる")
