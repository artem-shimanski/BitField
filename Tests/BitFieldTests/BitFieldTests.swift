//
//  BitFieldTests.swift
//  BitField
//
//  Created by Artem Shimanski on 12.06.2026.
//

import Testing
@testable import BitField
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import BitFieldMacros

var testMacros: [String: Macro.Type] { [
    "Bit": BitMacro.self,
    "BitField": BitFieldMacro.self
] }


enum ConnectionMode: UInt8 {
    case disconnected = 0
    case connecting   = 1
    case connected    = 2
    case fault        = 3
}

@BitField(UInt64.self)
struct TestPacket {
    
    @Bit(0..<8) var temperature: Int8
    @Bit(12..<13) var isReady: Bool
    @Bit(16...17) var mode: ConnectionMode!
    @Bit(32..<64) var largeValue: UInt32
}

@Test func testBitEncodingAndDecoding() {
    var packet = TestPacket(rawValue: 0)
    
    packet.temperature = -15
    packet.isReady = true
    packet.mode = .connected
    packet.largeValue = 0xDEADBEEF
    
    #expect(packet.temperature == -15)
    #expect(packet.isReady == true)
    #expect(packet.mode == .connected)
    #expect(packet.largeValue == 0xDEADBEEF)
}


@Test func testRawValueBinaryRepresentation() {
    var packet = TestPacket(rawValue: 0)
    packet.mode = .connected
    
    #expect(packet.rawValue == 0x20000)
    packet.isReady = true
    #expect(packet.rawValue == 0x21000)
}

@Test func testFieldIsolation() {
    var packet = TestPacket(rawValue: UInt64.max)
    
    packet.isReady = false
    
    #expect(packet.temperature == -1)
    #expect(packet.mode == .fault)
    #expect(packet.largeValue == UInt32.max)
    #expect(packet.isReady == false)
}

@Test func testTruncationOverflow() {
    var packet = TestPacket(rawValue: 0)
    
    packet.rawValue = (packet.rawValue & ~(0x3 << 16)) | ((UInt64(truncatingIfNeeded: 7) << 16) & (0x3 << 16))
    #expect(packet.mode == .fault)
}

@Test func testMasks() {
    #expect(TestPacket.$temperature.mask == 0xff)
    #expect(TestPacket.$temperature.clearMask == 0xffffffff_ffffff00)
    #expect(TestPacket.$temperature.lowerBits == 0x0)
    #expect(TestPacket.$temperature.higherBits == 0xffffffff_ffffff00)
    #expect(TestPacket.$temperature.lowerBitsInclusive == 0xff)
    #expect(TestPacket.$temperature.higherBitsInclusive == 0xffffffff_ffffffff)

    #expect(TestPacket.$isReady.mask == 0x1000)
    #expect(TestPacket.$isReady.clearMask == 0xffffffff_ffffefff)
    #expect(TestPacket.$isReady.lowerBits == 0x0fff)
    #expect(TestPacket.$isReady.higherBits == 0xffffffff_ffffe000)
    #expect(TestPacket.$isReady.lowerBitsInclusive == 0x1fff)
    #expect(TestPacket.$isReady.higherBitsInclusive == 0xffffffff_fffff000)

    #expect(TestPacket.$isReady.bits == 12..<13)
}

@Test func testSubscript() {
    var packet = TestPacket(rawValue: 0)
    packet[TestPacket.$largeValue] = 0xDEADBEEF
    #expect(packet[TestPacket.$largeValue] == 0xDEADBEEF)
    #expect(packet[32..<64] == 0xDEADBEEF)
    #expect(packet.largeValue == 0xDEADBEEF)
    packet[0..<64] = .max
    #expect(packet.rawValue == .max)
    packet[32..<64] = 0xDEADBEEF
    #expect(packet.largeValue == 0xDEADBEEF)
}

// Macro expansion and diagnostics are covered by `BitFieldDiagnosticsTests`,
// which uses XCTest so that `assertMacroExpansion` failures are actually
// reported as test failures rather than as warnings.

