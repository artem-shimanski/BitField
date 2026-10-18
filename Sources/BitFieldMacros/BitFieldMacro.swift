import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

// MARK: - Type tables

/// Fixed-width integer types that can be stored in a bit field directly,
/// together with the number of bits they can represent.
private let integerTypeWidths: [String: Int] = [
    "Int": 64, "Int8": 8, "Int16": 16, "Int32": 32, "Int64": 64, "Int128": 128,
    "UInt": 64, "UInt8": 8, "UInt16": 16, "UInt32": 32, "UInt64": 64, "UInt128": 128,
]

/// Types that `@BitField` accepts as the underlying storage, ordered by width.
private let storageTypes: [(name: String, width: Int)] = [
    ("UInt8", 8), ("UInt16", 16), ("UInt32", 32), ("UInt64", 64), ("UInt128", 128),
]

private let signedToUnsigned: [String: String] = [
    "Int": "UInt", "Int8": "UInt8", "Int16": "UInt16",
    "Int32": "UInt32", "Int64": "UInt64", "Int128": "UInt128",
]

/// `UInt` is platform dependent; assume the 64-bit layout used by every
/// platform the package supports, so that obviously-out-of-range fields are
/// still caught.
private let storageWidths: [String: Int] = {
    var widths = Dictionary(uniqueKeysWithValues: storageTypes.map { ($0.name, $0.width) })
    widths["UInt"] = 64
    return widths
}()

/// The narrowest storage type that can hold `bitCount` bits.
private func smallestStorage(fitting bitCount: Int) -> String? {
    storageTypes.first { $0.width >= bitCount }?.name
}

/// The narrowest integer type with the same signedness as `type` that can hold
/// `bitCount` bits.
private func widerIntegerType(thanTypeNamed type: String, fitting bitCount: Int) -> String? {
    let isSigned = type.hasPrefix("Int")
    let candidates = ["8", "16", "32", "64", "128"].map { (isSigned ? "Int" : "UInt") + $0 }
    return candidates.first { integerTypeWidths[$0]! >= bitCount }
}

fileprivate let visibilityModifiers: Set<String> = ["public", "private", "fileprivate", "internal", "package"]

// MARK: - Literal parsing

/// Parses an integer literal the way the Swift lexer does, i.e. honouring
/// `0x` / `0o` / `0b` prefixes and `_` digit separators.
private func integerValue(of literal: IntegerLiteralExprSyntax) -> Int? {
    let text = literal.literal.text.replacingOccurrences(of: "_", with: "")
    switch text.prefix(2).lowercased() {
    case "0x": return Int(text.dropFirst(2), radix: 16)
    case "0o": return Int(text.dropFirst(2), radix: 8)
    case "0b": return Int(text.dropFirst(2), radix: 2)
    default: return Int(text)
    }
}

/// Parses an expression that is expected to be a (possibly negated) integer
/// literal. Returns `nil` for anything that cannot be evaluated at compile time.
private func integerValue(of expression: ExprSyntax) -> Int? {
    if let literal = expression.as(IntegerLiteralExprSyntax.self) {
        return integerValue(of: literal)
    }
    if let prefix = expression.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-" {
        return integerValue(of: prefix.expression).map { -$0 }
    }
    if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
       let only = tuple.elements.first, only.label == nil {
        return integerValue(of: only.expression)
    }
    return nil
}

// MARK: - Bit range

/// The bit range of a single field, resolved against the implicit cursor that
/// `@Bit(width)` uses for automatic packing.
struct BitInfo {
    let bits: Range<Int>
    let isReadOnly: Bool

    var mask: String {
        let value = ((UInt128(1) << bits.count) &- 1) << bits.lowerBound
        return "0x\(String(value, radix: 16))"
    }

    var clearMask: String {
        "RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ \(mask))"
    }

    var lowerBits: String {
        let value = (UInt128(1) << bits.lowerBound) - 1
        return "0x\(String(value, radix: 16))"
    }

    var higherBits: String {
        let value = (UInt128(1) << bits.upperBound) - 1
        return "RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x\(String(value, radix: 16)))"
    }

    var lowerBitsInclusive: String {
        let value = (UInt128(1) << bits.upperBound) - 1
        return "0x\(String(value, radix: 16))"
    }

    var higherBitsInclusive: String {
        let value = (UInt128(1) << bits.lowerBound) - 1
        return "RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x\(String(value, radix: 16)))"
    }

    var maxValue: String {
        let value = (UInt128(1) << bits.count) - 1
        return "\(value)"
    }
}

/// Reads the `readOnly:` argument of a `@Bit` attribute.
///
/// - Parameter collector: when `nil` the argument is parsed silently. The
///   `@Bit` accessor macro passes `nil` so that the very same problem is not
///   reported twice — once by `@Bit` and once by the enclosing `@BitField`.
private func parseReadOnly(of node: AttributeSyntax, into collector: DiagnosticCollector?) -> Bool {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
          let argument = arguments.first(where: { $0.label?.text == "readOnly" }) else {
        return false
    }
    guard let literal = argument.expression.as(BooleanLiteralExprSyntax.self) else {
        collector?.add(
            node: argument.expression,
            .nonLiteralReadOnly,
            fixIts: [
                .replacing(
                    argument.expression,
                    with: ExprSyntax(BooleanLiteralExprSyntax(literal: .keyword(.true))),
                    message: .replaceReadOnly(with: "true")
                )
            ]
        )
        return false
    }
    return literal.literal.tokenKind == .keyword(.true)
}

/// Extracts the two operands and the operator of a `a...b` / `a..<b`
/// expression, no matter whether the expression has already been folded.
private func rangeComponents(of expression: ExprSyntax) -> (lower: ExprSyntax, op: String, upper: ExprSyntax)? {
    if let infix = expression.as(InfixOperatorExprSyntax.self) {
        return (infix.leftOperand, infix.operator.trimmedDescription, infix.rightOperand)
    }
    if let sequence = expression.as(SequenceExprSyntax.self) {
        let elements = Array(sequence.elements)
        guard elements.count == 3,
              let op = elements[1].as(BinaryOperatorExprSyntax.self) else { return nil }
        return (elements[0], op.operator.text, elements[2])
    }
    return nil
}

/// Parses the bit range of a `@Bit` attribute, reporting every problem it can
/// describe precisely. Returns `nil` when no usable range could be recovered.
private func parseBitRange(
    of node: AttributeSyntax,
    startBit: Int,
    into collector: DiagnosticCollector
) -> Range<Int>? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
          let rangeArgument = arguments.first, rangeArgument.label == nil else {
        collector.add(node: node, .nonLiteralBitRange(node.arguments?.trimmedDescription ?? ""))
        return nil
    }
    let expression = rangeArgument.expression

    // `@Bit(8)` — a width; the field is packed right after the previous one.
    if let width = integerValue(of: expression), rangeComponents(of: expression) == nil {
        guard width > 0 else {
            collector.add(node: expression, .nonPositiveBitWidth(width))
            return nil
        }
        return startBit..<(startBit + width)
    }

    // `@Bit(0..<8)` / `@Bit(0...7)`.
    if let (lowerExpr, op, upperExpr) = rangeComponents(of: expression) {
        guard op == "..<" || op == "..." else {
            collector.add(node: expression, .unsupportedRangeOperator(op))
            return nil
        }
        guard let lowerBound = integerValue(of: lowerExpr) else {
            collector.add(node: lowerExpr, .nonLiteralBitRange(lowerExpr.trimmedDescription))
            return nil
        }
        guard let upperBound = integerValue(of: upperExpr) else {
            collector.add(node: upperExpr, .nonLiteralBitRange(upperExpr.trimmedDescription))
            return nil
        }
        if lowerBound < 0 {
            collector.add(node: lowerExpr, .negativeBitBound(lowerBound))
            return nil
        }
        if upperBound < 0 {
            collector.add(node: upperExpr, .negativeBitBound(upperBound))
            return nil
        }

        let exclusiveUpperBound = op == "..." ? upperBound + 1 : upperBound
        if lowerBound > exclusiveUpperBound || (op == "..." && lowerBound > upperBound) {
            let swapped = "\(upperBound)\(op)\(lowerBound)"
            collector.add(
                node: expression,
                .reversedBitRange(lowerBound: lowerBound, upperBound: upperBound),
                fixIts: [
                    .replacing(expression, with: ExprSyntax("\(raw: swapped)"), message: .replaceRange(with: swapped))
                ]
            )
            return nil
        }
        if lowerBound == exclusiveUpperBound {
            let suggestion = "\(lowerBound)...\(lowerBound)"
            collector.add(
                node: expression,
                .emptyBitRange(expression.trimmedDescription),
                fixIts: [
                    .replacing(expression, with: ExprSyntax("\(raw: suggestion)"), message: .replaceRange(with: suggestion))
                ]
            )
            return nil
        }
        return lowerBound..<exclusiveUpperBound
    }

    // Partial ranges (`0...`, `...7`) have no well-defined width.
    if expression.is(PostfixOperatorExprSyntax.self)
        || (expression.as(PrefixOperatorExprSyntax.self).map { $0.operator.text == "..." || $0.operator.text == "..<" } ?? false) {
        collector.add(node: expression, .partialBitRange(expression.trimmedDescription))
        return nil
    }

    collector.add(node: expression, .nonLiteralBitRange(expression.trimmedDescription))
    return nil
}

// MARK: - Field description

/// Everything the code generator needs to know about a single `@Bit` property,
/// after the declaration has been validated.
struct FieldInfo {
    enum Kind {
        case integer
        case boolean
        case rawRepresentable
    }

    let name: TokenSyntax
    let typeAnnotation: TypeAnnotationSyntax
    let typeName: String
    let kind: Kind
    let isOptional: Bool
    let isPrivate: Bool
    /// Visibility modifiers copied verbatim onto the generated `$name` mask.
    let visibility: [String]
    let bitInfo: BitInfo

    var bits: Range<Int> { bitInfo.bits }
}

/// Resolves the declared type of a `@Bit` property into something the code
/// generator understands.
private func parseFieldType(
    _ type: TypeSyntax,
    into collector: DiagnosticCollector
) -> (name: String, isOptional: Bool)? {
    if let identifier = type.as(IdentifierTypeSyntax.self) {
        return (identifier.trimmedDescription, false)
    }
    if let member = type.as(MemberTypeSyntax.self) {
        return (member.trimmedDescription, false)
    }
    if let optional = type.as(OptionalTypeSyntax.self) {
        return parseFieldType(optional.wrappedType, into: collector).map { ($0.name, true) }
    }
    if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        return parseFieldType(optional.wrappedType, into: collector).map { ($0.name, true) }
    }
    collector.add(node: type, .unsupportedFieldType(type.trimmedDescription))
    return nil
}

private enum ParsedField {
    case valid(FieldInfo)
    /// The declaration was rejected, but enough is known to emit a placeholder
    /// storage variable so that the accessors synthesized by `@Bit` still
    /// compile and the real diagnostic is not buried under a pile of
    /// "cannot find '_x' in scope" errors.
    case invalid(name: TokenSyntax?, typeAnnotation: TypeAnnotationSyntax?, isPrivate: Bool)
}

/// Validates a single `@Bit` member declaration and, if it is well formed,
/// returns its description. Diagnostics are accumulated in `collector`; the
/// function keeps checking after recoverable problems so that the user sees
/// every mistake at once.
private func parseField(
    varDecl: VariableDeclSyntax,
    attribute: AttributeSyntax,
    startBit: Int,
    storage: StorageType,
    into collector: DiagnosticCollector
) -> ParsedField {
    let declaredPrivate = varDecl.modifiers.contains {
        $0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate)
    }

    // --- Declaration shape -------------------------------------------------
    guard varDecl.bindings.count == 1, let binding = varDecl.bindings.first else {
        collector.add(node: varDecl.bindings, .multipleBindings)
        return .invalid(name: nil, typeAnnotation: nil, isPrivate: declaredPrivate)
    }
    guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier else {
        collector.add(node: binding.pattern, .missingPropertyName)
        return .invalid(name: nil, typeAnnotation: nil, isPrivate: declaredPrivate)
    }

    var isValid = true

    if let staticModifier = varDecl.modifiers.first(where: { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }) {
        let cleaned = varDecl.with(\.modifiers, varDecl.modifiers.filter { $0 != staticModifier })
        collector.add(
            node: staticModifier,
            .staticProperty(name.text),
            fixIts: [.replacing(varDecl, with: cleaned, message: .removeStatic)]
        )
        isValid = false
    }

    if varDecl.bindingSpecifier.tokenKind == .keyword(.let) {
        let asVar = varDecl.bindingSpecifier.with(\.tokenKind, .keyword(.var))
        collector.add(
            node: varDecl.bindingSpecifier,
            .notAVariable(name.text),
            fixIts: [.replacing(varDecl.bindingSpecifier, with: asVar, message: .replaceLetWithVar)]
        )
        isValid = false
    }

    if let initializer = binding.initializer {
        let cleaned = binding
            .with(\.typeAnnotation, binding.typeAnnotation?.with(\.trailingTrivia, []))
            .with(\.initializer, nil)
        collector.add(
            node: initializer,
            .unexpectedInitializer(name.text),
            fixIts: [.replacing(binding, with: cleaned, message: .removeInitializer)]
        )
        isValid = false
    }

    if let accessorBlock = binding.accessorBlock {
        collector.add(node: accessorBlock, .unexpectedAccessors(name.text))
        isValid = false
    }

    guard let typeAnnotation = binding.typeAnnotation else {
        collector.add(node: name, .missingTypeAnnotation(name.text))
        return .invalid(name: name, typeAnnotation: nil, isPrivate: declaredPrivate)
    }

    // --- Bit range ---------------------------------------------------------
    guard let bits = parseBitRange(of: attribute, startBit: startBit, into: collector) else {
        return .invalid(name: name, typeAnnotation: typeAnnotation, isPrivate: declaredPrivate)
    }
    let isReadOnly = parseReadOnly(of: attribute, into: collector)

    if let storageWidth = storage.width, bits.upperBound > storageWidth {
        var fixIts: [FixIt] = []
        if let storageNode = storage.node, let wider = smallestStorage(fitting: bits.upperBound), wider != storage.name {
            fixIts.append(.replacing(storageNode, with: TokenSyntax.identifier(wider), message: .changeStorageType(to: wider)))
        }
        collector.add(
            node: attribute,
            .fieldExceedsStorage(name: name.text, bits: bits, storage: storage.name, storageWidth: storageWidth),
            fixIts: fixIts
        )
        isValid = false
    }

    // --- Type --------------------------------------------------------------
    guard let (typeName, isOptional) = parseFieldType(typeAnnotation.type, into: collector) else {
        return .invalid(name: name, typeAnnotation: typeAnnotation, isPrivate: declaredPrivate)
    }

    // `Bool` and the fixed-width integers use every bit pattern they have, so
    // there is none left over to encode `nil`.
    if isOptional, typeName == "Bool" || integerTypeWidths[typeName] != nil {
        collector.add(
            node: typeAnnotation.type,
            .optionalPrimitive(name: name.text, type: typeName),
            fixIts: [
                .replacing(
                    typeAnnotation.type,
                    with: TypeSyntax("\(raw: typeName)"),
                    message: .changeFieldType(to: typeName)
                )
            ]
        )
        isValid = false
    }

    let kind: FieldInfo.Kind
    if typeName == "Bool" {
        kind = .boolean
        if bits.count != 1 {
            let singleBit = "\(bits.lowerBound)...\(bits.lowerBound)"
            var fixIts: [FixIt] = []
            if let rangeExpr = attribute.arguments?.as(LabeledExprListSyntax.self)?.first?.expression {
                fixIts.append(
                    .replacing(rangeExpr, with: ExprSyntax("\(raw: singleBit)"), message: .replaceRange(with: singleBit))
                )
            }
            collector.add(
                node: attribute,
                .boolMustBeSingleBit(name: name.text, bitCount: bits.count),
                fixIts: fixIts
            )
            isValid = false
        }
    } else if let typeWidth = integerTypeWidths[typeName] {
        kind = .integer
        if bits.count > typeWidth {
            var fixIts: [FixIt] = []
            if let wider = widerIntegerType(thanTypeNamed: typeName, fitting: bits.count) {
                fixIts.append(
                    .replacing(typeAnnotation.type, with: TypeSyntax("\(raw: wider)"), message: .changeFieldType(to: wider))
                )
            }
            collector.add(
                node: typeAnnotation.type,
                .fieldTypeTooNarrow(name: name.text, type: typeName, typeWidth: typeWidth, bitCount: bits.count),
                fixIts: fixIts
            )
            isValid = false
        }
    } else {
        // Any `RawRepresentable` type — its width cannot be checked here.
        kind = .rawRepresentable
    }

    guard isValid else {
        return .invalid(name: name, typeAnnotation: typeAnnotation, isPrivate: declaredPrivate)
    }

    let modifiers = varDecl.modifiers.map { $0.trimmedDescription }
    let visibility = modifiers.filter { visibilityModifiers.contains($0) }

    return .valid(
        FieldInfo(
            name: name,
            typeAnnotation: typeAnnotation,
            typeName: typeName,
            kind: kind,
            isOptional: isOptional,
            isPrivate: visibility.contains("private") || visibility.contains("fileprivate"),
            visibility: visibility,
            bitInfo: BitInfo(bits: bits, isReadOnly: isReadOnly)
        )
    )
}

// MARK: - Code generation

private func accessors(for field: FieldInfo) -> [AccessorDeclSyntax] {
    let bitInfo = field.bitInfo
    let get: DeclSyntax
    let set: DeclSyntax

    switch field.kind {
    case .integer:
        get = "\(raw: field.typeName)(truncatingIfNeeded: (rawValue & \(raw: bitInfo.mask)) >> \(raw: bitInfo.bits.lowerBound))"
        set = "rawValue = (rawValue & \(raw: bitInfo.clearMask)) | ((RawValue(truncatingIfNeeded: newValue) << \(raw: bitInfo.bits.lowerBound)) & \(raw: bitInfo.mask))"
    case .boolean:
        get = "rawValue & \(raw: bitInfo.mask) != 0"
        set = "rawValue = (rawValue & \(raw: bitInfo.clearMask)) | (((newValue ? 1 : 0) << \(raw: bitInfo.bits.lowerBound)))"
    case .rawRepresentable:
        get = "\(raw: field.typeName)(rawValue: \(raw: field.typeName).RawValue(truncatingIfNeeded: (rawValue & \(raw: bitInfo.mask)) >> \(raw: bitInfo.bits.lowerBound)))"
        let newValue = field.isOptional ? "newValue?.rawValue ?? 0" : "newValue.rawValue"
        set = "rawValue = (rawValue & \(raw: bitInfo.clearMask)) | ((RawValue(truncatingIfNeeded: \(raw: newValue)) << \(raw: bitInfo.bits.lowerBound)) & \(raw: bitInfo.mask))"
    }

    var decls: [AccessorDeclSyntax] = [
        """
        \(raw: !field.isPrivate ? "@inlinable " : "") get {
            \(get)
        }
        """
    ]

    if !bitInfo.isReadOnly {
        decls.append(
            """
            \(raw: !field.isPrivate ? "@inlinable " : "") set {
                \(set)
            }
            """
        )
    }
    return decls
}

/// Stand-in storage for a field whose declaration was rejected. It never runs:
/// the build already failed, its only job is to keep the accessors synthesized
/// by `@Bit` well-formed so the actual diagnostic is not drowned out.
private func placeholderStorage(
    name: TokenSyntax,
    typeAnnotation: TypeAnnotationSyntax,
    isPrivate: Bool
) -> DeclSyntax {
    let modifiers = isPrivate ? "private" : "@usableFromInline internal"
    return """
    \(raw: modifiers) var _\(name)\(typeAnnotation.trimmed) {
        get {
            fatalError("'\(name)' is not a valid bit field")
        }
        set {
        }
    }
    """
}

private func masks(for field: FieldInfo) -> DeclSyntax {
    let bitInfo = field.bitInfo
    let isPublic = field.visibility.contains("public") || field.visibility.contains("package")
    let bits = "\(bitInfo.bits.lowerBound)..<\(bitInfo.bits.upperBound)"

    return """
    \(raw: !field.isPrivate && !isPublic ? "@usableFromInline " : "")\(raw: field.visibility.joined(separator: " ")) static let $\(field.name) = BitMask<RawValue>(mask: \(raw: bitInfo.mask),
                              clearMask: \(raw: bitInfo.clearMask),
                              lowerBits: \(raw: bitInfo.lowerBits),
                              higherBits: \(raw: bitInfo.higherBits),
                              lowerBitsInclusive: \(raw: bitInfo.lowerBitsInclusive),
                              higherBitsInclusive: \(raw: bitInfo.higherBitsInclusive),
                              maxValue: \(raw: bitInfo.maxValue),
                              bits: \(raw: bits))
    """
}

// MARK: - Storage type

/// The `RawValue` type a `@BitField` struct is built on.
struct StorageType {
    let name: String
    /// `nil` when the type is not one of the known fixed-width integers, in
    /// which case range checks are skipped instead of guessed.
    let width: Int?
    /// The syntax node spelling the type, used to offer Fix-Its.
    let node: Syntax?
}

/// Reads the storage type out of `@BitField<UInt32>` or `@BitField(UInt32.self)`.
private func parseStorageType(of node: AttributeSyntax, into collector: DiagnosticCollector) -> StorageType? {
    var typeName: String?
    var typeNode: Syntax?

    if let identifier = node.attributeName.as(IdentifierTypeSyntax.self),
       let argument = identifier.genericArgumentClause?.arguments.first?.argument {
        typeName = argument.trimmedDescription
        typeNode = Syntax(argument)
    } else if let expression = node.arguments?.as(LabeledExprListSyntax.self)?.first?.expression,
              let memberAccess = expression.as(MemberAccessExprSyntax.self),
              memberAccess.declName.baseName.tokenKind == .keyword(.self),
              let base = memberAccess.base {
        typeName = base.trimmedDescription
        typeNode = Syntax(base)
    }

    guard let typeName else {
        collector.add(
            node: node,
            .missingStorageType,
            fixIts: [
                .replacing(
                    node.attributeName,
                    with: TypeSyntax("BitField<UInt32>"),
                    message: .specifyStorageType("UInt32")
                )
            ]
        )
        return nil
    }

    if let unsigned = signedToUnsigned[typeName] {
        var fixIts: [FixIt] = []
        if let typeNode {
            fixIts.append(.replacing(typeNode, with: TokenSyntax.identifier(unsigned), message: .changeStorageType(to: unsigned)))
        }
        collector.add(node: typeNode ?? Syntax(node), .signedStorageType(typeName, suggestion: unsigned), fixIts: fixIts)
        return nil
    }

    if typeName == "Bool" || typeName == "Float" || typeName == "Double" || typeName == "String" {
        collector.add(node: typeNode ?? Syntax(node), .unsupportedStorageType(typeName))
        return nil
    }

    return StorageType(name: typeName, width: storageWidths[typeName], node: typeNode)
}

// MARK: - Member checks

/// Names `@BitField` synthesizes itself and that must therefore not be
/// declared by hand.
private func diagnoseReservedMembers(of declaration: some DeclGroupSyntax, into collector: DiagnosticCollector) {
    for member in declaration.memberBlock.members {
        if let typealiasDecl = member.decl.as(TypeAliasDeclSyntax.self), typealiasDecl.name.text == "RawValue" {
            collector.add(node: typealiasDecl.name, .reservedMember("RawValue"))
        } else if let varDecl = member.decl.as(VariableDeclSyntax.self),
                  !varDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }),
                  varDecl.bindings.contains(where: { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "rawValue" }) {
            collector.add(node: varDecl, .reservedMember("rawValue"))
        } else if let initDecl = member.decl.as(InitializerDeclSyntax.self),
                  let parameter = initDecl.signature.parameterClause.parameters.first,
                  initDecl.signature.parameterClause.parameters.count == 1,
                  parameter.firstName.text == "rawValue" {
            collector.add(node: initDecl, .reservedMember("init(rawValue:)"))
        }
    }
}

/// A stored property that is not a bit field silently escapes `rawValue`,
/// which breaks both `RawRepresentable` round-tripping and `BitwiseCopyable`.
private func diagnoseStoredProperty(_ varDecl: VariableDeclSyntax, into collector: DiagnosticCollector) {
    guard !varDecl.modifiers.contains(where: {
        $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
    }) else { return }
    // A property with accessors or with any other attached macro is not
    // necessarily stored, so stay quiet about it.
    guard varDecl.attributes.isEmpty else { return }

    for binding in varDecl.bindings where binding.accessorBlock == nil {
        guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier else { continue }
        // `rawValue` is reported by `diagnoseReservedMembers` already.
        guard name.text != "rawValue" else { continue }
        collector.add(node: binding, .storedPropertyWithoutBit(name.text))
    }
}

private func bitAttributes(of varDecl: VariableDeclSyntax) -> [AttributeSyntax] {
    varDecl.attributes.compactMap { $0.as(AttributeSyntax.self) }
        .filter { $0.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Bit" }
}

/// The keyword and human readable name of a declaration group, used to report
/// `@BitField` being attached to the wrong kind of declaration.
private func declarationKind(of declaration: some DeclGroupSyntax) -> (name: String, keyword: TokenSyntax?) {
    switch DeclSyntax(declaration).as(DeclSyntaxEnum.self) {
    case .classDecl(let decl): return ("class", decl.classKeyword)
    case .actorDecl(let decl): return ("actor", decl.actorKeyword)
    case .enumDecl(let decl): return ("enum", decl.enumKeyword)
    case .protocolDecl(let decl): return ("protocol", decl.protocolKeyword)
    case .extensionDecl: return ("extension", nil)
    default: return ("declaration", nil)
    }
}

// MARK: - `@Bit`

public struct BitMacro: AccessorMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        let collector = DiagnosticCollector()
        defer { collector.emit(into: context) }

        // Everything about the field itself (range, type, layout) is diagnosed
        // by the enclosing `@BitField`, which is the only place with enough
        // context to do it. Here we only check that such a context exists.
        let isInsideBitField = enclosingTypeIsBitField(in: context)
        if isInsideBitField == false {
            collector.add(node: node, .bitOutsideBitField)
            // The `_name` storage this macro normally forwards to is
            // synthesized by `@BitField`, which is missing here. Emit
            // accessors that at least type-check, so the diagnostic above is
            // not buried under "cannot find '_name' in scope".
            return [
                "get { fatalError(\"'@Bit' requires the enclosing type to be annotated with '@BitField'\") }",
                "set { }",
            ]
        }

        guard let varDecl = declaration.as(VariableDeclSyntax.self),
              let binding = varDecl.bindings.first,
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier else {
            return []
        }

        let isReadOnly = parseReadOnly(of: node, into: nil)
        let isPrivate = varDecl.modifiers.contains {
            $0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate)
        }

        var decls: [AccessorDeclSyntax] = [
            """
            \(raw: !isPrivate ? "@inlinable " : "") get {
                _\(name)
            }
            """
        ]
        if !isReadOnly {
            decls.append(
                """
                \(raw: !isPrivate ? "@inlinable " : "") set {
                    _\(name) = newValue
                }
                """
            )
        }
        return decls
    }

    /// - Returns: `nil` when the enclosing context cannot be determined, so
    ///   that no diagnostic is emitted on a guess.
    private static func enclosingTypeIsBitField(in context: some MacroExpansionContext) -> Bool? {
        let lexicalContext = context.lexicalContext
        guard !lexicalContext.isEmpty else { return nil }

        for syntax in lexicalContext {
            guard let decl = syntax.as(DeclSyntax.self) else { continue }
            let attributes: AttributeListSyntax
            switch decl.as(DeclSyntaxEnum.self) {
            case .structDecl(let decl): attributes = decl.attributes
            case .classDecl(let decl): attributes = decl.attributes
            case .actorDecl(let decl): attributes = decl.attributes
            case .enumDecl(let decl): attributes = decl.attributes
            case .extensionDecl(let decl): attributes = decl.attributes
            default: continue
            }
            return attributes.contains {
                $0.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "BitField"
            }
        }
        // No enclosing type at all: a local or top-level `@Bit` property.
        return false
    }
}

// MARK: - `@BitField`

public struct BitFieldMacro: MemberMacro, ExtensionMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let collector = DiagnosticCollector()
        defer { collector.emit(into: context) }

        guard declaration.is(StructDeclSyntax.self) else {
            let kind = declarationKind(of: declaration)
            var fixIts: [FixIt] = []
            if let keyword = kind.keyword, kind.name == "class" || kind.name == "actor" {
                fixIts.append(
                    .replacing(keyword, with: keyword.with(\.tokenKind, .keyword(.struct)), message: .changeDeclarationKeyword(to: "struct"))
                )
            }
            collector.add(node: node, .attachedToNonStruct(kind: kind.name), fixIts: fixIts)
            return []
        }

        guard let storage = parseStorageType(of: node, into: collector) else { return [] }

        diagnoseReservedMembers(of: declaration, into: collector)

        var modifiers = declaration.modifiers.map { $0.trimmedDescription }.filter {
            visibilityModifiers.contains($0)
        }
        let initModifiers: [String]

        if let i = modifiers.firstIndex(of: "private") {
            modifiers.remove(at: i)
            initModifiers = modifiers
        } else if let i = modifiers.firstIndex(of: "fileprivate") {
            modifiers.remove(at: i)
            initModifiers = modifiers
        } else {
            initModifiers = ["@inlinable"] + modifiers
            if !modifiers.contains("public") && !modifiers.contains("package") {
                modifiers = ["@usableFromInline"] + modifiers
            }
        }

        var decls: [DeclSyntax] = [
            "\(raw: modifiers.joined(separator: " ")) typealias RawValue = \(raw: storage.name)",
            "\(raw: modifiers.joined(separator: " ")) var rawValue: \(raw: storage.name)",
            "\(raw: initModifiers.joined(separator: " ")) init(rawValue: \(raw: storage.name)) { self.rawValue = rawValue }",
        ]

        var startBit = 0
        var placedFields: [(field: FieldInfo, attribute: AttributeSyntax)] = []

        for member in declaration.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }

            let attributes = bitAttributes(of: varDecl)
            guard let attribute = attributes.first else {
                diagnoseStoredProperty(varDecl, into: collector)
                continue
            }
            for duplicate in attributes.dropFirst() {
                collector.add(
                    node: duplicate,
                    .duplicateBitAttribute,
                    fixIts: [
                        .replacing(
                            varDecl,
                            with: varDecl.with(\.attributes, varDecl.attributes.filter { $0.as(AttributeSyntax.self) != duplicate }),
                            message: .removeDuplicateAttribute
                        )
                    ]
                )
            }

            let field: FieldInfo
            switch parseField(
                varDecl: varDecl,
                attribute: attribute,
                startBit: startBit,
                storage: storage,
                into: collector
            ) {
            case .valid(let parsed):
                field = parsed
            case .invalid(let name, let typeAnnotation, let isPrivate):
                if let name, let typeAnnotation {
                    decls.append(placeholderStorage(name: name, typeAnnotation: typeAnnotation, isPrivate: isPrivate))
                }
                continue
            }

            if let previous = placedFields.first(where: { $0.field.bits.overlaps(field.bits) }) {
                let overlap = max(previous.field.bits.lowerBound, field.bits.lowerBound)
                    ..< min(previous.field.bits.upperBound, field.bits.upperBound)
                collector.add(
                    node: attribute,
                    .overlappingFields(name: field.name.text, other: previous.field.name.text, bits: overlap),
                    notes: [
                        Note(node: Syntax(previous.attribute), message: BitFieldNote.previousFieldDeclaredHere(previous.field.name.text))
                    ]
                )
            }

            startBit = field.bits.upperBound
            placedFields.append((field, attribute))

            let shadowModifiers = field.isPrivate ? "private" : "@usableFromInline internal"
            let shadowDecl = try VariableDeclSyntax("\(raw: shadowModifiers) var _\(field.name)\(field.typeAnnotation.trimmed)") {
                for accessor in accessors(for: field) {
                    accessor
                }
            }
            decls.append(DeclSyntax(shadowDecl))
            decls.append(masks(for: field))
        }

        return decls
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // The member expansion already reported the problem; adding a
        // conformance to a declaration that cannot satisfy it would only bury
        // that diagnostic under a pile of follow-on errors.
        guard declaration.is(StructDeclSyntax.self) else { return [] }
        let extensionDecl = try ExtensionDeclSyntax("extension \(type.trimmed): BitField, BitwiseCopyable {}")
        return [extensionDecl]
    }
}

@main
struct BitFieldPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        BitMacro.self,
        BitFieldMacro.self
    ]
}
