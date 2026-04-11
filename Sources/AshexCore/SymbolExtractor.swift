import Foundation
import SwiftParser
import SwiftSyntax

public struct SymbolNode: Sendable, Equatable {
    public let name: String
    public let kind: String
    public let filePath: String
    public let lineStart: Int
    public let lineEnd: Int
    public let containerName: String?

    public init(
        name: String,
        kind: String,
        filePath: String,
        lineStart: Int,
        lineEnd: Int,
        containerName: String?
    ) {
        self.name = name
        self.kind = kind
        self.filePath = filePath
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.containerName = containerName
    }
}

public struct SymbolExtractionResult: Sendable, Equatable {
    public let imports: [String]
    public let symbols: [SymbolNode]

    public init(imports: [String], symbols: [SymbolNode]) {
        self.imports = imports
        self.symbols = symbols
    }
}

public struct SymbolExtractor: Sendable {
    public init() {}

    public func extractSymbols(
        from content: String,
        relativePath: String,
        language: String?
    ) -> SymbolExtractionResult {
        switch language {
        case "swift":
            return extractSwift(content: content, relativePath: relativePath)
        default:
            return .init(imports: [], symbols: [])
        }
    }

    private func extractSwift(content: String, relativePath: String) -> SymbolExtractionResult {
        let sourceFile = Parser.parse(source: content)
        let visitor = SwiftSymbolVisitor(sourceFile: sourceFile, relativePath: relativePath)
        visitor.walk(sourceFile)
        return .init(imports: visitor.imports, symbols: visitor.symbols)
    }
}

private final class SwiftSymbolVisitor: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private let relativePath: String
    private var containerStack: [String] = []

    var imports: [String] = []
    var symbols: [SymbolNode] = []

    init(sourceFile: SourceFileSyntax, relativePath: String) {
        self.converter = SourceLocationConverter(fileName: relativePath, tree: sourceFile)
        self.relativePath = relativePath
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        imports.append(node.path.trimmedDescription)
        return .skipChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        recordSymbol(name: node.name.text, kind: "struct", node: node, container: containerStack.last)
        containerStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) {
        popContainer(named: node.name.text)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        recordSymbol(name: node.name.text, kind: "class", node: node, container: containerStack.last)
        containerStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) {
        popContainer(named: node.name.text)
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        recordSymbol(name: node.name.text, kind: "enum", node: node, container: containerStack.last)
        containerStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) {
        popContainer(named: node.name.text)
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        recordSymbol(name: node.name.text, kind: "protocol", node: node, container: containerStack.last)
        containerStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ProtocolDeclSyntax) {
        popContainer(named: node.name.text)
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        recordSymbol(name: node.name.text, kind: "actor", node: node, container: containerStack.last)
        containerStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) {
        popContainer(named: node.name.text)
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.extendedType.trimmedDescription
        recordSymbol(name: name, kind: "extension", node: node, container: containerStack.last)
        containerStack.append(name)
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) {
        popContainer(named: node.extendedType.trimmedDescription)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let qualifiedName = containerStack.last.map { "\($0).\(name)" } ?? name
        recordSymbol(name: qualifiedName, kind: "func", node: node, container: containerStack.last)
        return .skipChildren
    }

    private func recordSymbol(name: String, kind: String, node: some SyntaxProtocol, container: String?) {
        let start = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        let end = converter.location(for: node.endPositionBeforeTrailingTrivia)
        symbols.append(
            SymbolNode(
                name: name,
                kind: kind,
                filePath: relativePath,
                lineStart: max(start.line, 1),
                lineEnd: max(end.line, start.line),
                containerName: container
            )
        )
    }

    private func popContainer(named name: String) {
        if containerStack.last == name {
            containerStack.removeLast()
        } else if let index = containerStack.lastIndex(of: name) {
            containerStack.removeSubrange(index...)
        }
    }
}
