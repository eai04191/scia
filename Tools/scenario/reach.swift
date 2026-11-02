// シミュレーターの中で走らせ、URLにURLSessionで届くかを終了コードで返す。端末の信頼ストアを使うので、Sciaと同じ条件で証明書を確かめられる。
// シミュレーターにはcurlがないため、setup.shがシミュレーター向けにビルドし、`xcrun simctl spawn`で走らせる。
import Foundation

guard CommandLine.arguments.count == 2, let url = URL(string: CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("使い方: reach <URL>\n".utf8))
    exit(2)
}
let done = DispatchSemaphore(value: 0)
var code: Int32 = 1
URLSession.shared.dataTask(with: url) { _, response, error in
    if let error {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    } else if let http = response as? HTTPURLResponse {
        print(http.statusCode)
        code = (200..<300).contains(http.statusCode) ? 0 : 1
    }
    done.signal()
}.resume()
if done.wait(timeout: .now() + 15) == .timedOut {
    FileHandle.standardError.write(Data("15秒で応答がなかった\n".utf8))
}
exit(code)
