import Network

extension NWEndpoint {
    /// テストで立てるサーバーが待ち受ける場所。127.0.0.1の、空いている番号のポート。
    ///
    /// すべてのアドレスで待ち受けると、iOSのシミュレーターでは、Macのほかのアプリが127.0.0.1で待ち受けている番号が割り当てられることがある。
    /// テストは127.0.0.1のその番号へつなぐので、Macのアプリにつながってしまう（VS CodeやCodexBarの応答を受け取って落ちた）。
    /// 127.0.0.1に絞ると、シミュレーターでも、ほかのアプリの番号は割り当てられなかった。
    static let loopbackWithAnyPort = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
}
