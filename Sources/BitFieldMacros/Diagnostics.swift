//
//  Diagnostics.swift
//  BitField
//
//  Created by Artem Shimanski on 12.06.2026.
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

private let bitFieldDomain = "BitField"

// MARK: - Message types

/// A single diagnostic message produced by the `@BitField` / `@Bit` macros.
///
/// Every distinct problem gets its own ``MessageID`` so that IDEs and other
/// tools can filter, group or suppress them individually.
struct BitFieldDiagnostic: DiagnosticMessage {
    let id: String
    let message: String
    let severity: DiagnosticSeverity

    var diagnosticID: MessageID { MessageID(domain: bitFieldDomain, id: id) }

    static func error(_ id: String, _ message: String) -> BitFieldDiagnostic {
        BitFieldDiagnostic(id: id, message: message, severity: .error)
    }

    static func warning(_ id: String, _ message: String) -> BitFieldDiagnostic {
        BitFieldDiagnostic(id: id, message: message, severity: .warning)
    }
}

/// A note that points at a second location relevant for a diagnostic.
struct BitFieldNote: NoteMessage {
    let id: String
    let message: String

    var noteID: MessageID { MessageID(domain: bitFieldDomain, id: id) }
}

/// A description of a Fix-It offered together with a diagnostic.
struct BitFieldFixIt: FixItMessage {
    let id: String
    let message: String

    var fixItID: MessageID { MessageID(domain: bitFieldDomain, id: id) }
}

// MARK: - Collecting diagnostics

/// Accumulates diagnostics so that a single macro expansion can report *all*
/// problems it found instead of aborting on the first one.
final class DiagnosticCollector {
    private(set) var diagnostics: [Diagnostic] = []

    var hasErrors: Bool {
        diagnostics.contains { $0.diagMessage.severity == .error }
    }

    func add(_ diagnostic: Diagnostic) {
        diagnostics.append(diagnostic)
    }

    func add(
        node: some SyntaxProtocol,
        _ message: BitFieldDiagnostic,
        notes: [Note] = [],
        fixIts: [FixIt] = []
    ) {
        diagnostics.append(Diagnostic(node: node, message: message, notes: notes, fixIts: fixIts))
    }

    func emit(into context: some MacroExpansionContext) {
        for diagnostic in diagnostics {
            context.diagnose(diagnostic)
        }
    }
}

// MARK: - Fix-It helpers

extension FixIt {
    /// A Fix-It that replaces `oldNode` with `newNode`.
    static func replacing(
        _ oldNode: some SyntaxProtocol,
        with newNode: some SyntaxProtocol,
        message: BitFieldFixIt
    ) -> FixIt {
        FixIt(
            message: message,
            changes: [.replace(oldNode: Syntax(oldNode), newNode: Syntax(newNode))]
        )
    }
}

// MARK: - `@BitField` diagnostics

extension BitFieldDiagnostic {
    static func attachedToNonStruct(kind: String) -> BitFieldDiagnostic {
        .error(
            "bitfield-requires-struct",
            """
            '@BitField' can only be attached to a struct, not to a \(kind). \
            A bit field stores all of its members inside a single 'rawValue', \
            which requires value semantics.
            """
        )
    }

    static let missingStorageType = BitFieldDiagnostic.error(
        "bitfield-missing-storage-type",
        """
        '@BitField' cannot infer the storage type. Spell it out as \
        '@BitField<UInt32>' or '@BitField(UInt32.self)'.
        """
    )

    static func signedStorageType(_ type: String, suggestion: String) -> BitFieldDiagnostic {
        .error(
            "bitfield-signed-storage-type",
            """
            '\(type)' cannot be used as bit-field storage because it is signed; \
            shifting bits into its sign bit is undefined. Use the unsigned \
            counterpart '\(suggestion)' instead.
            """
        )
    }

    static func unsupportedStorageType(_ type: String) -> BitFieldDiagnostic {
        .error(
            "bitfield-unsupported-storage-type",
            """
            '\(type)' cannot be used as bit-field storage. Use one of \
            'UInt8', 'UInt16', 'UInt32', 'UInt64', 'UInt128' or 'UInt'.
            """
        )
    }

    static func reservedMember(_ name: String) -> BitFieldDiagnostic {
        .error(
            "bitfield-reserved-member",
            """
            '@BitField' already synthesizes '\(name)'; declaring it here makes \
            it an invalid redeclaration. Remove this declaration.
            """
        )
    }

    static func storedPropertyWithoutBit(_ name: String) -> BitFieldDiagnostic {
        .warning(
            "bitfield-stored-property-without-bit",
            """
            Stored property '\(name)' is not part of the bit field, so it is \
            not covered by 'rawValue' and breaks the value/'rawValue' \
            round-trip. Annotate it with '@Bit', make it computed, or move it \
            out of the '@BitField' struct.
            """
        )
    }
}

// MARK: - `@Bit` placement diagnostics

extension BitFieldDiagnostic {
    static let bitOutsideBitField = BitFieldDiagnostic.error(
        "bit-outside-bitfield",
        """
        '@Bit' can only be used on a property of a struct annotated with \
        '@BitField', which provides the 'rawValue' storage the field reads \
        from and writes to.
        """
    )

    static func missingTypeAnnotation(_ name: String) -> BitFieldDiagnostic {
        .error(
            "bit-missing-type-annotation",
            """
            '@Bit' requires an explicit type annotation on '\(name)' \
            (for example 'var \(name): UInt8'); the type cannot be inferred \
            because the property has no initial value.
            """
        )
    }

    static let missingPropertyName = BitFieldDiagnostic.error(
        "bit-requires-identifier-pattern",
        """
        '@Bit' can only be applied to a property with a simple name; \
        tuple destructuring and wildcard patterns are not supported.
        """
    )

    static let multipleBindings = BitFieldDiagnostic.error(
        "bit-multiple-bindings",
        """
        '@Bit' can only be applied to a declaration that introduces exactly \
        one property. Declare each bit field on its own line with its own \
        '@Bit' attribute.
        """
    )

    static let duplicateBitAttribute = BitFieldDiagnostic.error(
        "bit-duplicate-attribute",
        """
        A property can carry only one '@Bit' attribute; the extra attributes \
        are ignored. Remove them.
        """
    )

    static func staticProperty(_ name: String) -> BitFieldDiagnostic {
        .error(
            "bit-static-property",
            """
            '@Bit' cannot be applied to the type property '\(name)' because a \
            bit field reads and writes the instance's 'rawValue'.
            """
        )
    }

    static func notAVariable(_ name: String) -> BitFieldDiagnostic {
        .error(
            "bit-requires-var",
            """
            '@Bit' requires '\(name)' to be declared with 'var': the property \
            is turned into a computed property backed by 'rawValue', and \
            'let' cannot have accessors.
            """
        )
    }

    static func unexpectedInitializer(_ name: String) -> BitFieldDiagnostic {
        .error(
            "bit-unexpected-initializer",
            """
            '@Bit' property '\(name)' cannot have an initial value because it \
            is computed from 'rawValue'. Set it from the initializer of the \
            enclosing type instead.
            """
        )
    }

    static func unexpectedAccessors(_ name: String) -> BitFieldDiagnostic {
        .error(
            "bit-unexpected-accessors",
            """
            '@Bit' synthesizes the accessors of '\(name)', so the property \
            must not declare its own accessor block.
            """
        )
    }
}

// MARK: - `@Bit` range diagnostics

extension BitFieldDiagnostic {
    static func nonLiteralBitRange(_ text: String) -> BitFieldDiagnostic {
        .error(
            "bit-non-literal-range",
            """
            '\(text)' is not a valid bit range. The bounds must be integer \
            literals so that the masks can be computed at compile time — \
            write '@Bit(0..<8)', '@Bit(0...7)' or '@Bit(8)' for a field of \
            8 bits placed right after the previous one.
            """
        )
    }

    static func partialBitRange(_ text: String) -> BitFieldDiagnostic {
        .error(
            "bit-partial-range",
            """
            '\(text)' is a partial range, which leaves the field's width \
            undefined. Write both bounds, for example '@Bit(0..<8)'.
            """
        )
    }

    static func unsupportedRangeOperator(_ op: String) -> BitFieldDiagnostic {
        .error(
            "bit-unsupported-range-operator",
            """
            '\(op)' is not a range operator. Use '..<' for a half-open bit \
            range or '...' for a closed one.
            """
        )
    }

    static func negativeBitBound(_ value: Int) -> BitFieldDiagnostic {
        .error(
            "bit-negative-bound",
            "Bit indices start at 0 and cannot be negative, but '\(value)' was given."
        )
    }

    static func reversedBitRange(lowerBound: Int, upperBound: Int) -> BitFieldDiagnostic {
        .error(
            "bit-reversed-range",
            """
            The lower bound of the bit range (\(lowerBound)) is greater than \
            its upper bound (\(upperBound)). Bit ranges go from the least \
            significant bit to the most significant one.
            """
        )
    }

    static func emptyBitRange(_ text: String) -> BitFieldDiagnostic {
        .error(
            "bit-empty-range",
            "The bit range '\(text)' is empty, so the field would occupy no bits."
        )
    }

    static func nonPositiveBitWidth(_ value: Int) -> BitFieldDiagnostic {
        .error(
            "bit-non-positive-width",
            "A bit field must be at least 1 bit wide, but a width of \(value) was given."
        )
    }

    static let nonLiteralReadOnly = BitFieldDiagnostic.error(
        "bit-non-literal-read-only",
        """
        'readOnly' must be a 'true' or 'false' literal: the setter is either \
        synthesized or not at compile time, so the value cannot be computed \
        at run time.
        """
    )
}

// MARK: - Layout diagnostics

extension BitFieldDiagnostic {
    static func fieldExceedsStorage(
        name: String,
        bits: Range<Int>,
        storage: String,
        storageWidth: Int
    ) -> BitFieldDiagnostic {
        .error(
            "bit-exceeds-storage",
            """
            Field '\(name)' occupies bits \(bits.lowerBound)..<\(bits.upperBound), \
            which does not fit into the \(storageWidth) bits of the storage \
            type '\(storage)'.
            """
        )
    }

    static func fieldTypeTooNarrow(
        name: String,
        type: String,
        typeWidth: Int,
        bitCount: Int
    ) -> BitFieldDiagnostic {
        .error(
            "bit-type-too-narrow",
            """
            Field '\(name)' is \(bitCount) bits wide, but its type '\(type)' \
            can only represent \(typeWidth) bits, so the value would be \
            silently truncated.
            """
        )
    }

    static func boolMustBeSingleBit(name: String, bitCount: Int) -> BitFieldDiagnostic {
        .error(
            "bit-bool-width",
            """
            A 'Bool' field must occupy exactly one bit, but '\(name)' spans \
            \(bitCount) bits. Use a fixed-width integer type for multi-bit fields.
            """
        )
    }

    static func optionalPrimitive(name: String, type: String) -> BitFieldDiagnostic {
        .error(
            "bit-optional-primitive",
            """
            An optional '\(type)' cannot be stored in a bit field: every bit \
            pattern is already a valid value, so there is none left to mean \
            'nil'. Declare '\(name)' as '\(type)', or use a \
            'RawRepresentable' type that reserves a case for the absent value.
            """
        )
    }

    static func unsupportedFieldType(_ type: String) -> BitFieldDiagnostic {
        .error(
            "bit-unsupported-type",
            """
            '\(type)' cannot be stored in a bit field. Use a fixed-width \
            integer, 'Bool', or a 'RawRepresentable' type (such as an enum) \
            whose 'RawValue' is a fixed-width integer.
            """
        )
    }

    static func overlappingFields(name: String, other: String, bits: Range<Int>) -> BitFieldDiagnostic {
        .warning(
            "bit-overlapping-fields",
            """
            Field '\(name)' overlaps '\(other)' at bits \
            \(bits.lowerBound)..<\(bits.upperBound); writing one of them will \
            change the other.
            """
        )
    }
}

// MARK: - Notes

extension BitFieldNote {
    static func previousFieldDeclaredHere(_ name: String) -> BitFieldNote {
        BitFieldNote(id: "bit-previous-field", message: "'\(name)' is declared here")
    }
}

// MARK: - Fix-It messages

extension BitFieldFixIt {
    static func changeDeclarationKeyword(to keyword: String) -> BitFieldFixIt {
        BitFieldFixIt(id: "fixit-change-decl-keyword", message: "Replace with '\(keyword)'")
    }

    static func specifyStorageType(_ type: String) -> BitFieldFixIt {
        BitFieldFixIt(id: "fixit-specify-storage-type", message: "Use '@BitField<\(type)>'")
    }

    static func changeStorageType(to type: String) -> BitFieldFixIt {
        BitFieldFixIt(id: "fixit-change-storage-type", message: "Change the storage type to '\(type)'")
    }

    static func changeFieldType(to type: String) -> BitFieldFixIt {
        BitFieldFixIt(id: "fixit-change-field-type", message: "Change the type to '\(type)'")
    }

    static let removeStatic = BitFieldFixIt(id: "fixit-remove-static", message: "Remove 'static'")

    static let replaceLetWithVar = BitFieldFixIt(id: "fixit-let-to-var", message: "Replace 'let' with 'var'")

    static let removeInitializer = BitFieldFixIt(id: "fixit-remove-initializer", message: "Remove the initial value")

    static let removeDuplicateAttribute = BitFieldFixIt(
        id: "fixit-remove-duplicate-bit",
        message: "Remove the redundant '@Bit' attribute"
    )

    static func replaceRange(with text: String) -> BitFieldFixIt {
        BitFieldFixIt(id: "fixit-replace-range", message: "Replace the bit range with '\(text)'")
    }

    static func replaceReadOnly(with text: String) -> BitFieldFixIt {
        BitFieldFixIt(id: "fixit-replace-read-only", message: "Use 'readOnly: \(text)'")
    }
}
