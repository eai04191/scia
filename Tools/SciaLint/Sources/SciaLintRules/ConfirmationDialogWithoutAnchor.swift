import SwiftSyntax

extension Rule {
    // confirmationDialogは、付けたビューからポップオーバーで出る。画面やFormに付けると、選択したボタンから離れた画面の中央に出る
    static let confirmationDialogWithoutAnchor = Rule(
        id: "confirmation_dialog_without_anchor",
        message: "confirmationDialogは、押すButton、Picker、Menu、Toggleに付け、押したものから出す。画面やFormに付けない",
        appliesTo: { $0.hasPrefix("App/") || $0.hasPrefix("ShareExtension/") },
        find: { tree in
            tree.all(FunctionCallExprSyntax.self)
                .compactMap { call -> AbsolutePosition? in
                    guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                          member.declName.baseName.text == "confirmationDialog",
                          let base = member.base else { return nil }
                    return anchorControls.contains(modifierRoot(of: base) ?? "") ? nil : member.declName.positionAfterSkippingLeadingTrivia
                }
        }
    )
}

private let anchorControls: Set<String> = ["Button", "Picker", "Menu", "Toggle"]

/// `Button { ... }.disabled(...)`のような修飾子の連なりの、ルートで作るビューの名前。ルートが呼び出しでなければnil
private func modifierRoot(of expression: ExprSyntax) -> String? {
    var current = expression
    while let call = current.as(FunctionCallExprSyntax.self) {
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base {
            // `SwiftUI.Button(...)`は修飾子ではなく、モジュールで修飾して作るビュー
            if base.as(DeclReferenceExprSyntax.self)?.baseName.text == "SwiftUI" { return member.declName.baseName.text }
            current = base
        } else {
            return call.calledName
        }
    }
    if let member = current.as(MemberAccessExprSyntax.self), let base = member.base {
        return modifierRoot(of: base)
    }
    return nil
}
