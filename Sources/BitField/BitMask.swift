//
//  BitMask.swift
//  BitField
//
//  Created by Artem Shimanski on 14.06.2026.
//


public struct BitMask<Storage: UnsignedInteger & Sendable>: Sendable {
    public let mask: Storage
    public let clearMask: Storage
    public let lowerBits: Storage
    public let higherBits: Storage
    public let lowerBitsInclusive: Storage
    public let higherBitsInclusive: Storage
    public let maxValue: Storage
    public let bits: Range<Int>
    
    @inlinable
    public init(mask: Storage, clearMask: Storage, lowerBits: Storage, higherBits: Storage, lowerBitsInclusive: Storage, higherBitsInclusive: Storage, maxValue: Storage, bits: Range<Int>) {
        self.mask = mask
        self.clearMask = clearMask
        self.lowerBits = lowerBits
        self.higherBits = higherBits
        self.lowerBitsInclusive = lowerBitsInclusive
        self.higherBitsInclusive = higherBitsInclusive
        self.maxValue = maxValue
        self.bits = bits
    }
}
