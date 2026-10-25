# BitField

Swift macros that pack several values into one unsigned integer. `@BitField<T>` turns a struct
into a `RawRepresentable` wrapper over `T`; each `@Bit` property becomes a computed accessor
over a range of bits. The accessors expand into plain shifts and masks.

## Features

- Field types: fixed-width integers (signed ones are sign-extended on read), `Bool`, and
  `RawRepresentable` types such as enums with a raw value.
- Automatic packing with `@Bit(width)`, or explicit ranges with `@Bit(a..<b)` / `@Bit(a...b)`.
- Per-field masks (`Type.$field`) for building and testing raw values.
- Compile-time diagnostics with Fix-Its for invalid declarations (listed below).

## Requirements

- Swift tools 6.2.
- macOS 15 / iOS 17 (`platforms` in `Package.swift`).
- `swift-syntax` 603.x or 604.x (a dependency of the macro target).

## Installation

The repository has no remote or tags yet, so add it by path:

```swift
dependencies: [
    .package(path: "../BitField")
],
targets: [
    .target(name: "MyTarget", dependencies: [.product(name: "BitField", package: "BitField")])
]
```

## Usage

```swift
import BitField

enum ConnectionMode: UInt8 {
    case disconnected, connecting, connected, fault
}

@BitField<UInt32>                         // also accepted: @BitField(UInt32.self)
struct Packet {
    @Bit(3) var id: UInt8                 // width 3: bits 0..<3 (packed after the previous field)
    @Bit(1) var isEncrypted: Bool         // bit 3
    @Bit(4...5) var mode: ConnectionMode! // explicit range; enum fields must be optional
    @Bit(6..<14) var temperature: Int8    // signed: sign-extended on read
    @Bit(2, readOnly: true) var version: UInt8   // getter only, bits 14..<16
}

var packet = Packet(rawValue: 0)
packet.id = 5
packet.isEncrypted = true
packet.mode = .connected
packet.temperature = -3
print(String(packet.rawValue, radix: 2))
```

`@BitField` adds `typealias RawValue`, `var rawValue`, `init(rawValue:)` and the conformances
`BitField` and `BitwiseCopyable`. Visibility follows the struct (`public` struct gives a public
`rawValue`); for an internal struct they are `@usableFromInline`.

## Fields

- `@Bit(n)`: `n` bits starting right after the previous field (the first one starts at bit 0).
  An explicit range also moves this cursor to its end.
- `@Bit(a..<b)` / `@Bit(a...b)`: explicit bits. Bounds must be integer literals.
- `readOnly: true` (a literal) omits the setter.
- `RawRepresentable` fields must be declared `T?` or `T!`: the getter uses `init(rawValue:)`, so
  a bit pattern with no case reads as `nil`, and assigning `nil` writes 0. A non-optional enum
  does not compile. `Bool` and integer fields cannot be optional.
- Assigned values are truncated to the field width, not trapped.
- Storage may be `UInt8`, `UInt16`, `UInt32`, `UInt64`, `UInt128` or `UInt`; signed storage is rejected.

## Masks and operators

For each field the macro also generates `static let $name: BitMask<RawValue>` with the same
visibility as the field. For `@Bit(12..<13) var isReady` on `UInt64`:

| Property | Meaning | Value |
| --- | --- | --- |
| `mask` | the field's bits | `0x1000` |
| `clearMask` | everything except the field | `0xffff_ffff_ffff_efff` |
| `lowerBits` | bits below the field | `0x0fff` |
| `higherBits` | bits above the field | `0xffff_ffff_ffff_e000` |
| `lowerBitsInclusive` | the field and the bits below | `0x1fff` |
| `higherBitsInclusive` | the field and the bits above | `0xffff_ffff_ffff_f000` |
| `maxValue` | largest value that fits | `1` |
| `bits` | the `Range<Int>` | `12..<13` |

Every `BitField` type also gets:

- `&` as `Self & RawValue` and `Self & Self`, returning `Self`, e.g. `value & Packet.$mode.higherBitsInclusive`.
- Subscripts by `BitMask` (`packet[Packet.$mode]`), `Range`, `ClosedRange`, `PartialRangeFrom`,
  `PartialRangeThrough` and `PartialRangeUpTo`, each readable and writable: `packet[4...5]`.

## Diagnostics

Reported on the offending node, with a Fix-It where an obvious correction exists:

- `@BitField` on anything but a struct (class/actor: change to `struct`); missing, signed or
  unsupported storage type; hand-written `RawValue`, `rawValue` or `init(rawValue:)`.
- `@Bit` outside a `@BitField` type; duplicated `@Bit`; `static`, `let`, initialized or
  accessor-bearing properties; missing type annotation; several bindings in one declaration.
- Ranges: non-literal, partial (`0...`), unsupported operator, negative, reversed, empty, or zero width.
- Fit: field beyond the storage width, field wider than its Swift type, multi-bit `Bool`,
  optional `Bool`/integer, overlapping fields (with a note on the first one), non-literal `readOnly:`.
- Warning: a stored property without `@Bit`, which would not be part of `rawValue`.

## Tests

```
xcrun swift test
```

`BitFieldTests` covers runtime behavior (round trips, sign extension, field isolation, masks,
subscripts) with Swift Testing. `BitFieldDiagnosticsTests` checks macro expansions and each
diagnostic with XCTest and `assertMacroExpansion`.

## License

MIT. See [LICENSE](LICENSE).
