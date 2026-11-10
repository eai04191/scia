import SwiftSyntax

extension Rule {
    // チューニングの項目は、`TuningCatalog`に`static let`で定義し、`sections`にもう一度並べる。`TuningStore`は`sections`に入った項目しか読まないので、
    // 並べ忘れると、パネルに出ず、保存した値も読まれないまま、ビルドもテストも通る。
    // 別のファイルのextensionに定義した項目は、`sections`と突き合わせられないので、`sections`と同じファイルに書かせる
    static let tuningItemNotInSections = Rule(
        id: "tuning_item_not_in_sections",
        message: "TuningCatalogの項目は、同じファイルのsectionsにも入れる。入れないと、チューニングパネルに出ず、TuningStoreも値を読まない",
        appliesTo: { path in
            path.hasPrefix("Packages/SciaCore/Sources/") || path.hasPrefix("App/Sources/")
        },
        find: { tree in
            let members = tree.all(EnumDeclSyntax.self).filter { $0.name.text == catalogName }.map(\.memberBlock)
                + tree.all(ExtensionDeclSyntax.self).filter { $0.extendedType.trimmedDescription == catalogName }.map(\.memberBlock)
            let bindings = members
                .flatMap { $0.members.compactMap { $0.decl.as(VariableDeclSyntax.self) } }
                .filter { variable in variable.modifiers.contains { $0.name.text == "static" } }
                .flatMap { Array($0.bindings) }
            let listed = Set(bindings.filter { $0.name == "sections" }.flatMap { $0.initializer?.value.all(DeclReferenceExprSyntax.self) ?? [] }.map(\.baseName.text))
            return bindings
                .filter { binding in binding.isTuningItem && !(binding.name.map(listed.contains) ?? false) }
                .map(\.positionAfterSkippingLeadingTrivia)
        }
    )
}

private let catalogName = "TuningCatalog"

private extension PatternBindingSyntax {
    var name: String? { pattern.as(IdentifierPatternSyntax.self)?.identifier.text }

    /// `NumberTuning(...)`や`ToggleTuning(...)`で作るか、型をそう書いた項目か。項目の型を足しても見つけるよう、名前の終わりで見る
    var isTuningItem: Bool {
        let created = initializer?.value.as(FunctionCallExprSyntax.self)?.calledName
        let annotated = typeAnnotation?.type.identifierNames.last
        return [created, annotated].contains { $0?.hasSuffix("Tuning") ?? false }
    }
}
