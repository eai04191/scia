import UIKit

/// 補完の候補を出している間の、ハードウェアキーボードの操作。
@MainActor
struct CompletionKeys {
    /// 確定できる候補を出している。
    var hasCandidate: () -> Bool = { false }
    /// 候補のリストを出している（候補がなくても、読み込み中や失敗の行を出している）。
    var isShown: () -> Bool = { false }
    var move: (Int) -> Void = { _ in }
    var confirm: () -> Void = {}
    var dismiss: () -> Void = {}

    /// 出している間だけ返す。出していないときは、↑↓・Tab・Return・Escはふだんどおり入力欄が受ける。
    func commands(move: Selector, confirm: Selector, dismiss: Selector) -> [UIKeyCommand] {
        var commands: [UIKeyCommand] = []
        if hasCandidate() {
            commands += [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: move),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: move),
                UIKeyCommand(input: "\t", modifierFlags: [], action: confirm),
                UIKeyCommand(input: "\r", modifierFlags: [], action: confirm),
            ]
        }
        if isShown() {
            commands.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: dismiss))
        }
        // 矢印やTab、Returnは、入力欄の移動や改行より先に受ける。
        for command in commands {
            command.wantsPriorityOverSystemBehavior = true
        }
        return commands
    }
}
