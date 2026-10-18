/// Declares a bit range of a `@BitField` struct's raw value as a computed property.
///
/// `@Bit(n)` takes `n` bits right after the previous field; `@Bit(a..<b)` and `@Bit(a...b)` select explicit bits.
/// Pass `readOnly: true` to omit the setter.
@attached(accessor)
public macro Bit(_ range: Range<Int>, readOnly: Bool = false) = #externalMacro(module: "BitFieldMacros", type: "BitMacro")

@attached(accessor)
public macro Bit(_ range: ClosedRange<Int>, readOnly: Bool = false) = #externalMacro(module: "BitFieldMacros", type: "BitMacro")

@attached(accessor)
public macro Bit(_ index: Int, readOnly: Bool = false) = #externalMacro(module: "BitFieldMacros", type: "BitMacro")


/// Turns a struct into a `RawRepresentable` wrapper over the unsigned integer `T`.
///
/// Adds `RawValue`, `rawValue`, `init(rawValue:)` and a `static let $name: BitMask` for every `@Bit` property.
@attached(member, names: arbitrary)
@attached(extension, conformances: BitField, BitwiseCopyable)
public macro BitField<T: UnsignedInteger & FixedWidthInteger & Sendable>(_ storage: T.Type = T.self) = #externalMacro(module: "BitFieldMacros", type: "BitFieldMacro")

public protocol BitField: RawRepresentable, BitwiseCopyable where RawValue: UnsignedInteger & FixedWidthInteger & Sendable {
    var rawValue: RawValue {get set}
    init(rawValue: RawValue)
}

extension BitField {
    @inlinable
    public static func & (lhs: Self, rhs: RawValue) -> Self {
        Self(rawValue: lhs.rawValue & rhs)
    }
    
    @inlinable
    public static func & (lhs: Self, rhs: Self) -> Self {
        Self(rawValue: lhs.rawValue & rhs.rawValue)
    }
    
    @inlinable
    public subscript(_ mask: BitMask<RawValue>) -> RawValue {
        get {
            (rawValue & mask.mask) >> mask.bits.lowerBound
        }
        mutating set {
            rawValue = (rawValue & mask.clearMask) | ((newValue << mask.bits.lowerBound) & mask.mask)
        }
    }
    
    @inlinable
    public subscript(_ bits: Range<Int>) -> RawValue {
        get {
            let mask = ((RawValue(1) << bits.count) &- 1) << bits.lowerBound
            return (rawValue & mask) >> bits.lowerBound
        }
        mutating set {
            let mask = ((RawValue(1) << bits.count) &- 1) << bits.lowerBound
            let clearMask = RawValue.max ^ mask
            rawValue = (rawValue & clearMask) | ((newValue << bits.lowerBound) & mask)
        }
    }

    @inlinable
    public subscript(_ bits: ClosedRange<Int>) -> RawValue {
        get {
            self[bits.lowerBound..<(bits.upperBound &+ 1)]
        }
        mutating set {
            self[bits.lowerBound..<(bits.upperBound &+ 1)] = newValue
        }
    }

    @inlinable
    public subscript(_ bits: PartialRangeFrom<Int>) -> RawValue {
        get {
            self[bits.lowerBound ..< MemoryLayout<RawValue>.size * 8]
        }
        mutating set {
            self[bits.lowerBound ..< MemoryLayout<RawValue>.size * 8] = newValue
        }
    }

    @inlinable
    public subscript(_ bits: PartialRangeThrough<Int>) -> RawValue {
        get {
            self[0 ..< bits.upperBound &+ 1]
        }
        mutating set {
            self[0 ..< bits.upperBound &+ 1] = newValue
        }
    }
    
    @inlinable
    public subscript(_ bits: PartialRangeUpTo<Int>) -> RawValue {
        get {
            self[0 ..< bits.upperBound]
        }
        mutating set {
            self[0 ..< bits.upperBound] = newValue
        }
    }

}
