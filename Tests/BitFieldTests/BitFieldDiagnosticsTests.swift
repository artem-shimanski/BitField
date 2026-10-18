//
//  BitFieldDiagnosticsTests.swift
//  BitField
//
//  Verifies the diagnostics and Fix-Its produced by the `@BitField` / `@Bit`
//  macros. These use `XCTest` because `assertMacroExpansion` reports failures
//  through `XCTFail`.
//

import XCTest
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import BitFieldMacros

private var macros: [String: Macro.Type] { [
    "Bit": BitMacro.self,
    "BitField": BitFieldMacro.self,
] }

final class BitFieldDiagnosticsTests: XCTestCase {

    // MARK: - Successful expansion

    func testExpansion() {
        assertMacroExpansion(
            """
            @BitField<UInt16>
            struct Packet {
                @Bit(3) var id: UInt8
                @Bit(1) var isEncrypted: Bool
                @Bit(8...9, readOnly: true) var mode: Mode
            }
            """,
            expandedSource: """
            struct Packet {
                var id: UInt8 {
                    @inlinable  get {
                        _id
                    }
                    @inlinable  set {
                        _id = newValue
                    }
                }
                var isEncrypted: Bool {
                    @inlinable  get {
                        _isEncrypted
                    }
                    @inlinable  set {
                        _isEncrypted = newValue
                    }
                }
                var mode: Mode {
                    @inlinable  get {
                        _mode
                    }
                }

                @usableFromInline typealias RawValue = UInt16

                @usableFromInline var rawValue: UInt16

                @inlinable init(rawValue: UInt16) {
                    self.rawValue = rawValue
                }

                @usableFromInline internal var _id: UInt8 {
                    @inlinable  get {
                        UInt8(truncatingIfNeeded: (rawValue & 0x7) >> 0)
                    }
                    @inlinable  set {
                        rawValue = (rawValue & RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x7)) | ((RawValue(truncatingIfNeeded: newValue) << 0) & 0x7)
                    }
                }

                @usableFromInline  static let $id = BitMask<RawValue>(mask: 0x7,
                                          clearMask: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x7),
                                          lowerBits: 0x0,
                                          higherBits: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x7),
                                          lowerBitsInclusive: 0x7,
                                          higherBitsInclusive: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x0),
                                          maxValue: 7,
                                          bits: 0 ..< 3)

                @usableFromInline internal var _isEncrypted: Bool {
                    @inlinable  get {
                        rawValue & 0x8 != 0
                    }
                    @inlinable  set {
                        rawValue = (rawValue & RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x8)) | (((newValue ? 1 : 0) << 3))
                    }
                }

                @usableFromInline  static let $isEncrypted = BitMask<RawValue>(mask: 0x8,
                                          clearMask: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x8),
                                          lowerBits: 0x7,
                                          higherBits: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0xf),
                                          lowerBitsInclusive: 0xf,
                                          higherBitsInclusive: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x7),
                                          maxValue: 1,
                                          bits: 3 ..< 4)

                @usableFromInline internal var _mode: Mode {
                    @inlinable  get {
                        Mode(rawValue: Mode.RawValue(truncatingIfNeeded: (rawValue & 0x300) >> 8))
                    }
                }

                @usableFromInline  static let $mode = BitMask<RawValue>(mask: 0x300,
                                          clearMask: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x300),
                                          lowerBits: 0xff,
                                          higherBits: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x3ff),
                                          lowerBitsInclusive: 0x3ff,
                                          higherBitsInclusive: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0xff),
                                          maxValue: 3,
                                          bits: 8 ..< 10)
            }

            extension Packet: BitField, BitwiseCopyable {
            }
            """,
            macros: macros
        )
    }

    // MARK: - Attachment

    func testAttachedToClass() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            class Packet {
            }
            """,
            expandedSource: """
            class Packet {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    '@BitField' can only be attached to a struct, not to a class. A bit field stores all of \
                    its members inside a single 'rawValue', which requires value semantics.
                    """,
                    line: 1,
                    column: 1,
                    fixIts: [FixItSpec(message: "Replace with 'struct'")]
                )
            ],
            macros: macros,
            applyFixIts: ["Replace with 'struct'"],
            fixedSource: """
            @BitField<UInt8>
            struct Packet {
            }
            """
        )
    }

    func testBitOutsideBitField() {
        assertMacroExpansion(
            """
            struct Packet {
                @Bit(1) var flag: Bool
            }
            """,
            expandedSource: """
            struct Packet {
                var flag: Bool {
                    get {
                        fatalError("'@Bit' requires the enclosing type to be annotated with '@BitField'")
                    }
                    set {
                    }
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    '@Bit' can only be used on a property of a struct annotated with '@BitField', which \
                    provides the 'rawValue' storage the field reads from and writes to.
                    """,
                    line: 2,
                    column: 5
                )
            ],
            macros: macros
        )
    }

    // MARK: - Bit ranges

    func testReversedRange() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            struct Packet {
                @Bit(7...0) var value: UInt8
            }
            """,
            expandedSource: expectedPlaceholderExpansion(name: "value", type: "UInt8"),
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    The lower bound of the bit range (7) is greater than its upper bound (0). Bit ranges go \
                    from the least significant bit to the most significant one.
                    """,
                    line: 3,
                    column: 10,
                    fixIts: [FixItSpec(message: "Replace the bit range with '0...7'")]
                )
            ],
            macros: macros
        )
    }

    func testEmptyRange() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            struct Packet {
                @Bit(4..<4) var value: UInt8
            }
            """,
            expandedSource: expectedPlaceholderExpansion(name: "value", type: "UInt8"),
            diagnostics: [
                DiagnosticSpec(
                    message: "The bit range '4..<4' is empty, so the field would occupy no bits.",
                    line: 3,
                    column: 10,
                    fixIts: [FixItSpec(message: "Replace the bit range with '4...4'")]
                )
            ],
            macros: macros
        )
    }

    func testZeroWidth() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            struct Packet {
                @Bit(0) var value: UInt8
            }
            """,
            expandedSource: expectedPlaceholderExpansion(name: "value", type: "UInt8"),
            diagnostics: [
                DiagnosticSpec(
                    message: "A bit field must be at least 1 bit wide, but a width of 0 was given.",
                    line: 3,
                    column: 10
                )
            ],
            macros: macros
        )
    }

    func testNegativeBound() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            struct Packet {
                @Bit(-1..<3) var value: UInt8
            }
            """,
            expandedSource: expectedPlaceholderExpansion(name: "value", type: "UInt8"),
            diagnostics: [
                DiagnosticSpec(
                    message: "Bit indices start at 0 and cannot be negative, but '-1' was given.",
                    line: 3,
                    column: 10
                )
            ],
            macros: macros
        )
    }

    func testNonLiteralRange() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            struct Packet {
                @Bit(start..<3) var value: UInt8
            }
            """,
            expandedSource: expectedPlaceholderExpansion(name: "value", type: "UInt8"),
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    'start' is not a valid bit range. The bounds must be integer literals so that the masks \
                    can be computed at compile time — write '@Bit(0..<8)', '@Bit(0...7)' or '@Bit(8)' for a \
                    field of 8 bits placed right after the previous one.
                    """,
                    line: 3,
                    column: 10
                )
            ],
            macros: macros
        )
    }

    func testNonLiteralReadOnly() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            struct Packet {
                @Bit(1, readOnly: flag) var value: Bool
            }
            """,
            expandedSource: """
            struct Packet {
                var value: Bool {
                    @inlinable  get {
                        _value
                    }
                    @inlinable  set {
                        _value = newValue
                    }
                }

                @usableFromInline typealias RawValue = UInt8

                @usableFromInline var rawValue: UInt8

                @inlinable init(rawValue: UInt8) {
                    self.rawValue = rawValue
                }

                @usableFromInline internal var _value: Bool {
                    @inlinable  get {
                        rawValue & 0x1 != 0
                    }
                    @inlinable  set {
                        rawValue = (rawValue & RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x1)) | (((newValue ? 1 : 0) << 0))
                    }
                }

                @usableFromInline  static let $value = BitMask<RawValue>(mask: 0x1,
                                          clearMask: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x1),
                                          lowerBits: 0x0,
                                          higherBits: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x1),
                                          lowerBitsInclusive: 0x1,
                                          higherBitsInclusive: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x0),
                                          maxValue: 1,
                                          bits: 0 ..< 1)
            }

            extension Packet: BitField, BitwiseCopyable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    'readOnly' must be a 'true' or 'false' literal: the setter is either synthesized or not \
                    at compile time, so the value cannot be computed at run time.
                    """,
                    line: 3,
                    column: 23,
                    fixIts: [FixItSpec(message: "Use 'readOnly: true'")]
                )
            ],
            macros: macros
        )
    }

    // MARK: - Layout

    func testFieldExceedsStorage() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            struct Packet {
                @Bit(0..<16) var value: UInt16
            }
            """,
            expandedSource: expectedPlaceholderExpansion(name: "value", type: "UInt16"),
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    Field 'value' occupies bits 0..<16, which does not fit into the 8 bits of the storage \
                    type 'UInt8'.
                    """,
                    line: 3,
                    column: 5,
                    fixIts: [FixItSpec(message: "Change the storage type to 'UInt16'")]
                )
            ],
            macros: macros,
            applyFixIts: ["Change the storage type to 'UInt16'"],
            fixedSource: """
            @BitField<UInt16>
            struct Packet {
                @Bit(0..<16) var value: UInt16
            }
            """
        )
    }

    func testFieldTypeTooNarrow() {
        assertMacroExpansion(
            """
            @BitField<UInt32>
            struct Packet {
                @Bit(0..<16) var value: UInt8
            }
            """,
            expandedSource: expectedPlaceholderExpansion(name: "value", type: "UInt8", storage: "UInt32"),
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    Field 'value' is 16 bits wide, but its type 'UInt8' can only represent 8 bits, so the \
                    value would be silently truncated.
                    """,
                    line: 3,
                    column: 29,
                    fixIts: [FixItSpec(message: "Change the type to 'UInt16'")]
                )
            ],
            macros: macros,
            applyFixIts: ["Change the type to 'UInt16'"],
            fixedSource: """
            @BitField<UInt32>
            struct Packet {
                @Bit(0..<16) var value: UInt16
            }
            """
        )
    }

    func testBoolMustBeSingleBit() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            struct Packet {
                @Bit(0..<3) var flag: Bool
            }
            """,
            expandedSource: expectedPlaceholderExpansion(name: "flag", type: "Bool"),
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    A 'Bool' field must occupy exactly one bit, but 'flag' spans 3 bits. Use a fixed-width \
                    integer type for multi-bit fields.
                    """,
                    line: 3,
                    column: 5,
                    fixIts: [FixItSpec(message: "Replace the bit range with '0...0'")]
                )
            ],
            macros: macros,
            applyFixIts: ["Replace the bit range with '0...0'"],
            fixedSource: """
            @BitField<UInt8>
            struct Packet {
                @Bit(0...0) var flag: Bool
            }
            """
        )
    }

    func testUnsupportedFieldType() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            struct Packet {
                @Bit(2) var pair: (Int, Int)
            }
            """,
            expandedSource: expectedPlaceholderExpansion(name: "pair", type: "(Int, Int)"),
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    '(Int, Int)' cannot be stored in a bit field. Use a fixed-width integer, 'Bool', or a \
                    'RawRepresentable' type (such as an enum) whose 'RawValue' is a fixed-width integer.
                    """,
                    line: 3,
                    column: 23
                )
            ],
            macros: macros
        )
    }

    func testOptionalPrimitive() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            struct Packet {
                @Bit(4) var value: UInt8?
            }
            """,
            expandedSource: expectedPlaceholderExpansion(name: "value", type: "UInt8?"),
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    An optional 'UInt8' cannot be stored in a bit field: every bit pattern is already a \
                    valid value, so there is none left to mean 'nil'. Declare 'value' as 'UInt8', or use a \
                    'RawRepresentable' type that reserves a case for the absent value.
                    """,
                    line: 3,
                    column: 24,
                    fixIts: [FixItSpec(message: "Change the type to 'UInt8'")]
                )
            ],
            macros: macros,
            applyFixIts: ["Change the type to 'UInt8'"],
            fixedSource: """
            @BitField<UInt8>
            struct Packet {
                @Bit(4) var value: UInt8
            }
            """
        )
    }

    func testOverlappingFields() {
        assertMacroExpansion(
            """
            @BitField<UInt16>
            struct Packet {
                @Bit(0..<8) var low: UInt8
                @Bit(4..<12) var high: UInt8
            }
            """,
            expandedSource: """
            struct Packet {
                var low: UInt8 {
                    @inlinable  get {
                        _low
                    }
                    @inlinable  set {
                        _low = newValue
                    }
                }
                var high: UInt8 {
                    @inlinable  get {
                        _high
                    }
                    @inlinable  set {
                        _high = newValue
                    }
                }

                @usableFromInline typealias RawValue = UInt16

                @usableFromInline var rawValue: UInt16

                @inlinable init(rawValue: UInt16) {
                    self.rawValue = rawValue
                }

                @usableFromInline internal var _low: UInt8 {
                    @inlinable  get {
                        UInt8(truncatingIfNeeded: (rawValue & 0xff) >> 0)
                    }
                    @inlinable  set {
                        rawValue = (rawValue & RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0xff)) | ((RawValue(truncatingIfNeeded: newValue) << 0) & 0xff)
                    }
                }

                @usableFromInline  static let $low = BitMask<RawValue>(mask: 0xff,
                                          clearMask: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0xff),
                                          lowerBits: 0x0,
                                          higherBits: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0xff),
                                          lowerBitsInclusive: 0xff,
                                          higherBitsInclusive: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x0),
                                          maxValue: 255,
                                          bits: 0 ..< 8)

                @usableFromInline internal var _high: UInt8 {
                    @inlinable  get {
                        UInt8(truncatingIfNeeded: (rawValue & 0xff0) >> 4)
                    }
                    @inlinable  set {
                        rawValue = (rawValue & RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0xff0)) | ((RawValue(truncatingIfNeeded: newValue) << 4) & 0xff0)
                    }
                }

                @usableFromInline  static let $high = BitMask<RawValue>(mask: 0xff0,
                                          clearMask: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0xff0),
                                          lowerBits: 0xf,
                                          higherBits: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0xfff),
                                          lowerBitsInclusive: 0xfff,
                                          higherBitsInclusive: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0xf),
                                          maxValue: 255,
                                          bits: 4 ..< 12)
            }

            extension Packet: BitField, BitwiseCopyable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    Field 'high' overlaps 'low' at bits 4..<8; writing one of them will change the other.
                    """,
                    line: 4,
                    column: 5,
                    severity: .warning,
                    notes: [NoteSpec(message: "'low' is declared here", line: 3, column: 5)]
                )
            ],
            macros: macros
        )
    }

    // MARK: - Declaration shape

    func testStaticProperty() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            struct Packet {
                @Bit(1) static var flag: Bool
            }
            """,
            expandedSource: expectedPlaceholderExpansion(name: "flag", type: "Bool", declaration: "static var"),
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    '@Bit' cannot be applied to the type property 'flag' because a bit field reads and \
                    writes the instance's 'rawValue'.
                    """,
                    line: 3,
                    column: 13,
                    fixIts: [FixItSpec(message: "Remove 'static'")]
                )
            ],
            macros: macros,
            applyFixIts: ["Remove 'static'"],
            fixedSource: """
            @BitField<UInt8>
            struct Packet {
                @Bit(1) var flag: Bool
            }
            """
        )
    }

    func testLetProperty() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            struct Packet {
                @Bit(1) let flag: Bool
            }
            """,
            expandedSource: expectedPlaceholderExpansion(name: "flag", type: "Bool", declaration: "let"),
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    '@Bit' requires 'flag' to be declared with 'var': the property is turned into a computed \
                    property backed by 'rawValue', and 'let' cannot have accessors.
                    """,
                    line: 3,
                    column: 13,
                    fixIts: [FixItSpec(message: "Replace 'let' with 'var'")]
                )
            ],
            macros: macros,
            applyFixIts: ["Replace 'let' with 'var'"],
            fixedSource: """
            @BitField<UInt8>
            struct Packet {
                @Bit(1) var flag: Bool
            }
            """
        )
    }

    func testInitializer() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            struct Packet {
                @Bit(1) var flag: Bool = false
            }
            """,
            expandedSource: expectedPlaceholderExpansion(name: "flag", type: "Bool"),
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    '@Bit' property 'flag' cannot have an initial value because it is computed from \
                    'rawValue'. Set it from the initializer of the enclosing type instead.
                    """,
                    line: 3,
                    column: 28,
                    fixIts: [FixItSpec(message: "Remove the initial value")]
                )
            ],
            macros: macros,
            applyFixIts: ["Remove the initial value"],
            fixedSource: """
            @BitField<UInt8>
            struct Packet {
                @Bit(1) var flag: Bool
            }
            """
        )
    }

    func testMissingTypeAnnotation() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            struct Packet {
                @Bit(1) var flag
            }
            """,
            expandedSource: """
            struct Packet {
                var flag {
                    @inlinable  get {
                        _flag
                    }
                    @inlinable  set {
                        _flag = newValue
                    }
                }

                @usableFromInline typealias RawValue = UInt8

                @usableFromInline var rawValue: UInt8

                @inlinable init(rawValue: UInt8) {
                    self.rawValue = rawValue
                }
            }

            extension Packet: BitField, BitwiseCopyable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    '@Bit' requires an explicit type annotation on 'flag' (for example 'var flag: UInt8'); \
                    the type cannot be inferred because the property has no initial value.
                    """,
                    line: 3,
                    column: 17
                )
            ],
            macros: macros
        )
    }

    func testReservedMemberAndStoredProperty() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            struct Packet {
                var rawValue: UInt8
                var extra: Int
            }
            """,
            expandedSource: """
            struct Packet {
                var rawValue: UInt8
                var extra: Int

                @usableFromInline typealias RawValue = UInt8

                @usableFromInline var rawValue: UInt8

                @inlinable init(rawValue: UInt8) {
                    self.rawValue = rawValue
                }
            }

            extension Packet: BitField, BitwiseCopyable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    '@BitField' already synthesizes 'rawValue'; declaring it here makes it an invalid \
                    redeclaration. Remove this declaration.
                    """,
                    line: 3,
                    column: 5
                ),
                DiagnosticSpec(
                    message: """
                    Stored property 'extra' is not part of the bit field, so it is not covered by 'rawValue' \
                    and breaks the value/'rawValue' round-trip. Annotate it with '@Bit', make it computed, \
                    or move it out of the '@BitField' struct.
                    """,
                    line: 4,
                    column: 9,
                    severity: .warning
                ),
            ],
            macros: macros
        )
    }

    func testDuplicateBitAttribute() {
        assertMacroExpansion(
            """
            @BitField<UInt8>
            struct Packet {
                @Bit(1) @Bit(2) var flag: Bool
            }
            """,
            expandedSource: """
            struct Packet {
                var flag: Bool {
                    @inlinable  get {
                        _flag
                    }
                    @inlinable  set {
                        _flag = newValue
                    }
                    @inlinable  get {
                        _flag
                    }
                    @inlinable  set {
                        _flag = newValue
                    }
                }

                @usableFromInline typealias RawValue = UInt8

                @usableFromInline var rawValue: UInt8

                @inlinable init(rawValue: UInt8) {
                    self.rawValue = rawValue
                }

                @usableFromInline internal var _flag: Bool {
                    @inlinable  get {
                        rawValue & 0x1 != 0
                    }
                    @inlinable  set {
                        rawValue = (rawValue & RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x1)) | (((newValue ? 1 : 0) << 0))
                    }
                }

                @usableFromInline  static let $flag = BitMask<RawValue>(mask: 0x1,
                                          clearMask: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x1),
                                          lowerBits: 0x0,
                                          higherBits: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x1),
                                          lowerBitsInclusive: 0x1,
                                          higherBitsInclusive: RawValue(truncatingIfNeeded: RawValue.Magnitude.max ^ 0x0),
                                          maxValue: 1,
                                          bits: 0 ..< 1)
            }

            extension Packet: BitField, BitwiseCopyable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "A property can carry only one '@Bit' attribute; the extra attributes are ignored. Remove them.",
                    line: 3,
                    column: 13,
                    fixIts: [FixItSpec(message: "Remove the redundant '@Bit' attribute")]
                )
            ],
            macros: macros,
            applyFixIts: ["Remove the redundant '@Bit' attribute"],
            fixedSource: """
            @BitField<UInt8>
            struct Packet {
                @Bit(1) var flag: Bool
            }
            """
        )
    }
}

/// The expansion produced for a struct whose single `@Bit` field was rejected:
/// the field keeps its forwarding accessors and gets placeholder storage, so
/// that only the macro's own diagnostic is reported.
private func expectedPlaceholderExpansion(
    name: String,
    type: String,
    storage: String = "UInt8",
    declaration: String = "var"
) -> String {
    """
    struct Packet {
        \(declaration) \(name): \(type) {
            @inlinable  get {
                _\(name)
            }
            @inlinable  set {
                _\(name) = newValue
            }
        }

        @usableFromInline typealias RawValue = \(storage)

        @usableFromInline var rawValue: \(storage)

        @inlinable init(rawValue: \(storage)) {
            self.rawValue = rawValue
        }

        @usableFromInline internal var _\(name): \(type) {
            get {
                fatalError("'\(name)' is not a valid bit field")
            }
            set {
            }
        }
    }

    extension Packet: BitField, BitwiseCopyable {
    }
    """
}
