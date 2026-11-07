public import Testing

/// `operation`の前後で状態を丸ごと比べ、`change`に書いた変化だけが起きたことを確かめる。
///
/// 前の状態に`change`を当てたものと、`operation`のあとの状態が違えば、違う行を並べて失敗を残す。
/// 確かめたい値だけを`#expect`で見ると、思わぬところの変化（読み込み中のままになる、など）を見逃すため。
/// 何も変わらないことは、`change`を空にして確かめる。
/// `operation`が投げたときも、状態を比べてから投げ直す。失敗する操作が、投げる前に状態を変えたことを見逃さないため。
/// - Parameters:
///   - state: 今の状態を返す。前と後で1回ずつ読む。
///   - change: 前の状態に当てる、起きるはずの変化。
/// - Returns: `operation`の結果。
@MainActor
@discardableResult
public func expectChanges<State: Equatable, Value>(
    of state: () -> State,
    during operation: () async throws -> Value,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ change: (inout State) throws -> Void
) async throws -> Value {
    var expected = state()
    let outcome: Result<Value, any Error>
    do {
        outcome = .success(try await operation())
    } catch {
        outcome = .failure(error)
    }
    try change(&expected)
    let actual = state()
    if actual != expected {
        Issue.record(Comment(rawValue: "書いた変化と違う変化が起きました（-は書いた変化のあとの状態、+は実際の状態）\n" + lineDiff(expected, actual)), sourceLocation: sourceLocation)
    }
    return try outcome.get()
}

/// `dump`で書き出した2つの値の、違う行だけを並べる。
func lineDiff(_ expected: some Any, _ actual: some Any) -> String {
    var expectedText = ""
    var actualText = ""
    dump(expected, to: &expectedText)
    dump(actual, to: &actualText)
    let expectedLines = expectedText.split(separator: "\n", omittingEmptySubsequences: false)
    let actualLines = actualText.split(separator: "\n", omittingEmptySubsequences: false)
    let difference = actualLines.difference(from: expectedLines)
    let lines = difference.map { change in
        switch change {
        case .remove(_, let line, _): "-\(line)"
        case .insert(_, let line, _): "+\(line)"
        }
    }
    // `==`で違っても、`dump`に違いが出ない値がある（`CustomReflectable`で中身を隠した値など）。
    return lines.isEmpty ? "（dumpに違いが出ない値が違う）" : lines.joined(separator: "\n")
}
