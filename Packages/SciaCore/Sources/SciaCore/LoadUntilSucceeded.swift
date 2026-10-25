/// 読めるまで、使うたびに読み直す。読めたら、そのあとは読んだものを使う。
/// 端末のロック中にKeychainを読めなかったときのように、一時的な失敗を起動中ずっと持ち続けないため。
@MainActor
public final class LoadUntilSucceeded<Value> {
    private let load: @MainActor () throws -> Value
    private var loaded: Value?

    public init(_ load: @escaping @MainActor () throws -> Value) {
        self.load = load
    }

    public func get() -> Result<Value, any Error> {
        if let loaded { return .success(loaded) }
        let result = Result { try load() }
        if case .success(let value) = result {
            loaded = value
        }
        return result
    }
}
