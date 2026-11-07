import SwiftSyntax

extension Rule {
    // TimelineStoreのテストは、操作の前後で状態を丸ごと比べ、書いていない変化を見逃さない。中のストアに起きる変化と一緒にしか触れない
    // TimelineStoreTesterを通させ、変化を書かずに操作するテストを書けないようにする。
    // 作り方（`TimelineStore(`、`.init(`、型を書いて`.init`）を並べると漏れるので、名前を書くこと自体を止める。
    // ストアを持たない、入れ子の型や静的な関数（`TimelineStore.State`、`TimelineStore.updatingQuoted`など）を指すときだけ許す
    static let timelineStoreWithoutTester = Rule(
        id: "timeline_store_without_tester",
        message: "テストではTimelineStoreを直接作ったり持ったりせず、TimelineStoreTesterを通し、操作をexpectChangesで起きる変化と一緒に渡す。操作が乱数で決まり、変化を前もって書けないテストだけ、理由を書いてこの規則を外す",
        appliesTo: { path in
            path.hasPrefix("Packages/SciaCore/Tests/") && path != "Packages/SciaCore/Tests/SciaCoreTests/TimelineStoreTester.swift"
        },
        find: { tree in
            // 式の位置。`SciaCore.TimelineStore`のようにモジュールで修飾したものは、名前の部分も参照として見つかるので、修飾した式全体で見る
            let expressions = tree.all(DeclReferenceExprSyntax.self)
                .filter { $0.baseName.isStoreName && !$0.qualifiedExpression.isBaseOfMemberOtherThanInit }
                .map(\.positionAfterSkippingLeadingTrivia)
            let types = tree.all(IdentifierTypeSyntax.self)
                .filter { $0.name.isStoreName && !$0.isBaseOfMemberType }
                .map(\.positionAfterSkippingLeadingTrivia)
            // 型の位置で、モジュールで修飾したもの
            let qualifiedTypes = tree.all(MemberTypeSyntax.self)
                .filter { $0.name.isStoreName && !$0.isBaseOfMemberType }
                .map(\.name.positionAfterSkippingLeadingTrivia)
            return expressions + types + qualifiedTypes
        }
    )
}

private extension TokenSyntax {
    /// `TimelineStore`の名前か。``` `TimelineStore` ```のようにバッククォートで囲んでも同じ名前なので、外してから比べる
    var isStoreName: Bool { identifier?.name == "TimelineStore" }
}

private extension DeclReferenceExprSyntax {
    /// `A.X`の`X`なら`A.X`の式、そうでなければ自分
    var qualifiedExpression: Syntax {
        if let member = parent?.as(MemberAccessExprSyntax.self), member.declName.id == id { return Syntax(member) }
        return Syntax(self)
    }
}

private extension SyntaxProtocol {
    /// `X.State`や`X.updatingQuoted`の`X`か。`X.init`は作るのと同じなので含めない
    var isBaseOfMemberOtherThanInit: Bool {
        guard let member = parent?.as(MemberAccessExprSyntax.self), member.base?.id == id else { return false }
        return member.declName.baseName.text != "init"
    }

    /// 型の位置の`X.State`の`X`か
    var isBaseOfMemberType: Bool {
        guard let member = parent?.as(MemberTypeSyntax.self) else { return false }
        return member.baseType.id == id
    }
}
