import SwiftSyntax

extension Rule {
    // .swiftlint.ymlの`server_value_without_check`は、`decode(Int.self`や`decode(URL.self`と書いた呼び出しだけを見つける。
    // `init(from:)`を書かずにコンパイラーに作らせた型は、その呼び出しがソースにないまま整数やURLを直接読むので、構文木で見つける。
    // 手書きの`init(from:)`がある型は、中の読み方を`server_value_without_check`が調べる
    static let synthesizedServerValueDecoding = Rule(
        id: "synthesized_server_value_decoding",
        message: "サーバーから来る整数とURLを、コンパイラーが作るDecodableで直接読まない。init(from:)を書き、件数ならdecodeCount、上限ならServerLimit、URLならdecodeURLかdecodeRequiredURLで読む",
        appliesTo: { path in
            guard path.hasPrefix(serverValueRoot) else { return false }
            let folder = path.dropFirst(serverValueRoot.count).prefix { $0 != "/" }
            return serverValueFolders.contains(String(folder))
        },
        find: { tree in
            let extensions = tree.all(ExtensionDeclSyntax.self)
            let types = tree.all(StructDeclSyntax.self).map(DecodedType.init)
                + tree.all(ClassDeclSyntax.self).map(DecodedType.init)
                + tree.all(ActorDeclSyntax.self).map(DecodedType.init)
            return types.flatMap { $0.uncheckedProperties(extensions: extensions) }
        }
    )
}

private let serverValueRoot = "Packages/SciaCore/Sources/SciaCore/"
private let serverValueFolders: Set<String> = ["Models", "Networking", "Streaming", "XPosts"]
private let uncheckedTypeNames: Set<String> = ["Int", "URL"]

/// 保存プロパティを持てる型の宣言。enumは、コンパイラーが作る読み方では整数やURLのプロパティを読まないので見ない
private struct DecodedType {
    let node: Syntax
    let inheritance: InheritanceClauseSyntax?
    let members: MemberBlockSyntax

    init(_ decl: StructDeclSyntax) {
        node = Syntax(decl)
        inheritance = decl.inheritanceClause
        members = decl.memberBlock
    }

    init(_ decl: ClassDeclSyntax) {
        node = Syntax(decl)
        inheritance = decl.inheritanceClause
        members = decl.memberBlock
    }

    init(_ decl: ActorDeclSyntax) {
        node = Syntax(decl)
        inheritance = decl.inheritanceClause
        members = decl.memberBlock
    }

    /// コンパイラーが作る`init(from:)`で読まれる、整数かURLの保存プロパティの位置
    func uncheckedProperties(extensions: [ExtensionDeclSyntax]) -> [AbsolutePosition] {
        let name = node.qualifiedTypeName
        let own = extensions.filter { $0.extendedType.trimmedDescription == name }
        let isDecodable = inheritance.isDecodable || own.contains { $0.inheritanceClause.isDecodable }
        let hasDecoderInit = members.hasDecoderInit || own.contains { $0.memberBlock.hasDecoderInit }
        guard isDecodable, !hasDecoderInit else { return [] }
        let keys = members.codingKeys
        return members.members.compactMap { $0.decl.as(VariableDeclSyntax.self) }
            .filter { !$0.isStatic }
            .flatMap { variable in
                variable.bindings.filter { binding in
                    guard binding.accessorBlock.isStored, let type = binding.typeAnnotation?.type,
                          // 初期値のある`let`は、コンパイラーが作る読み方では読まれない
                          !(variable.bindingSpecifier.tokenKind == .keyword(.let) && binding.initializer != nil),
                          let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                    else { return false }
                    return (keys?.contains(name) ?? true) && type.mentionsUncheckedType
                }
            }
            .map(\.positionAfterSkippingLeadingTrivia)
    }
}

private extension Optional<InheritanceClauseSyntax> {
    var isDecodable: Bool {
        guard let self else { return false }
        return self.inheritedTypes.contains { inherited in
            guard let name = inherited.type.identifierNames.last else { return false }
            return name == "Decodable" || name == "Codable"
        }
    }
}

private extension Optional<AccessorBlockSyntax> {
    /// 保存プロパティか。`willSet`と`didSet`だけなら保存プロパティのまま
    var isStored: Bool {
        guard let self else { return true }
        guard case .accessors(let accessors) = self.accessors else { return false }
        return accessors.allSatisfy { ["willSet", "didSet"].contains($0.accessorSpecifier.text) }
    }
}

private extension MemberBlockSyntax {
    var hasDecoderInit: Bool {
        members.contains { member in
            guard let initializer = member.decl.as(InitializerDeclSyntax.self) else { return false }
            let parameters = initializer.signature.parameterClause.parameters
            return parameters.count == 1 && parameters.first?.firstName.text == "from"
        }
    }

    /// `CodingKeys`を書いてあれば、そのcaseの名前。書いた名前のプロパティだけが読まれる
    var codingKeys: Set<String>? {
        let keys = members.compactMap { $0.decl.as(EnumDeclSyntax.self) }.first { $0.name.text == "CodingKeys" }
        guard let keys else { return nil }
        return Set(keys.all(EnumCaseElementSyntax.self).map(\.name.text))
    }
}

private extension VariableDeclSyntax {
    var isStatic: Bool {
        modifiers.contains { ["static", "class"].contains($0.name.text) }
    }
}

private extension TypeSyntax {
    /// `Int`、`URL?`、`[Int]`、`[String: URL]`、`Foundation.URL`のように、整数かURLを含む型か
    var mentionsUncheckedType: Bool {
        all(IdentifierTypeSyntax.self).contains { uncheckedTypeNames.contains($0.name.text) }
            || all(MemberTypeSyntax.self).contains { uncheckedTypeNames.contains($0.name.text) }
    }
}

private extension Syntax {
    /// `Outer.Inner`のように、入れ子の外の型の名前を付けた名前。同じファイルのextensionと突き合わせる
    var qualifiedTypeName: String {
        ([self] + ancestors).reversed().compactMap { node -> String? in
            if let decl = node.as(StructDeclSyntax.self) { return decl.name.text }
            if let decl = node.as(ClassDeclSyntax.self) { return decl.name.text }
            if let decl = node.as(ActorDeclSyntax.self) { return decl.name.text }
            if let decl = node.as(EnumDeclSyntax.self) { return decl.name.text }
            if let decl = node.as(ExtensionDeclSyntax.self) { return decl.extendedType.trimmedDescription }
            return nil
        }.joined(separator: ".")
    }
}
