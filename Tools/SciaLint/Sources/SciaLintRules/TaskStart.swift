import SwiftSyntax

/// 処理を始める呼び出し（`Task { }`、`Task<Value, Failure>.detached { }`、SwiftUIの`.task { }`など）
struct TaskStart {
    enum Kind: Equatable {
        /// `Task`の初期化と、`Task`の型の関数。名前は`detached`、`immediate`など。`Task { }`と`Task(...) { }`はnil
        case task(String?)
        /// SwiftUIの`.task`
        case modifier
    }

    static let taskFunctions: Set = ["init", "detached", "immediate", "immediateDetached"]
    /// 目的を名乗る入口を用意していない関数
    static let unnamedFunctions: Set = ["init", "detached", "immediateDetached"]

    let kind: Kind
    let call: FunctionCallExprSyntax

    init?(_ call: FunctionCallExprSyntax) {
        let called = call.calledExpression
        if called.isTaskType {
            kind = .task(nil)
        } else if let member = called.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            if let base = member.base, base.isTaskType, Self.taskFunctions.contains(name) {
                kind = .task(name)
            } else if name == "task" {
                kind = .modifier
            } else {
                return nil
            }
        } else {
            return nil
        }
        self.call = call
    }

    /// 最初の引数が、`.action`のように`.`で始まる、ラベルのない値か
    var namesPurpose: Bool {
        guard let first = call.arguments.first, first.label == nil else { return false }
        return first.expression.isLeadingDotMember
    }

    /// 引数が`.withoutRequests`だけか
    var isWithoutRequests: Bool {
        call.arguments.count == 1 && call.arguments.first.map { $0.label == nil && $0.expression.leadingDotMemberName == "withoutRequests" } == true
    }

    /// 引数がなく、閉包が`{ @MainActor in`で始まるか
    var hopsToMainActor: Bool {
        guard call.arguments.isEmpty, let closure = call.trailingClosure else { return false }
        return closure.signature?.attributes.contains { attribute in
            attribute.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "MainActor"
        } ?? false
    }
}

private extension ExprSyntax {
    /// `Task`か`Task<Value, Failure>`か（`_Concurrency.Task`のような修飾も含む）
    var isTaskType: Bool {
        if isStandardType("Task") { return true }
        if let specialized = self.as(GenericSpecializationExprSyntax.self) { return specialized.expression.isTaskType }
        return false
    }
}

extension SourceFileSyntax {
    var taskStarts: [TaskStart] {
        all(FunctionCallExprSyntax.self).compactMap(TaskStart.init)
    }

    /// `Task.detached`のように、目的を名乗る入口のない関数に触れる式。呼び出さずに関数として取り出してから呼ぶ書き方も含む
    var unnamedTaskFunctions: [MemberAccessExprSyntax] {
        all(MemberAccessExprSyntax.self).filter { member in
            guard let base = member.base, base.isTaskType else { return false }
            return TaskStart.unnamedFunctions.contains(member.declName.baseName.text)
        }
    }
}
