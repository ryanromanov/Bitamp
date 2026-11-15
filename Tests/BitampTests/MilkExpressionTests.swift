import Foundation
import Testing
@testable import BitampKit

@Suite struct MilkExpressionTests {
    private func run(_ code: String, _ setup: ((MilkContext) -> Void)? = nil) throws -> (Double, MilkContext) {
        let context = MilkContext()
        setup?(context)
        let value = try MilkProgram(code, in: context).run()
        return (value, context)
    }

    @Test func arithmeticAndPrecedence() throws {
        #expect(try run("1 + 2 * 3").0 == 7)
        #expect(try run("(1 + 2) * 3").0 == 9)
        #expect(try run("-2 * 3").0 == -6)
        #expect(try run("7 % 4").0 == 3)
        #expect(try run("2 ^ 3 ^ 2").0 == 512)
        #expect(try run("1 + 1 == 2").0 == 1)
    }

    @Test func missingThingsReadAsZero() throws {
        #expect(try run("nothing_here").0 == 0)
        #expect(try run("5 / 0").0 == 0)
        #expect(try run("5 % 0").0 == 0)
        #expect(try run("sqrt(-4)").0 == 2)
        #expect(try run("log(0)").0 == 0)
    }

    @Test func variablesIgnoreCaseAndPersist() throws {
        let (_, context) = try run("X = 3; y = x * 2; Y += 1")
        #expect(context["x"] == 3)
        #expect(context["Y"] == 7)
    }

    @Test func assignmentOperators() throws {
        let (_, context) = try run("a = 10; a -= 4; a *= 3; a /= 2; a %= 5")
        #expect(context["a"] == 4)
    }

    @Test func truthUsesATolerance() throws {
        #expect(try run("if(0.000001, 1, 2)").0 == 2)
        #expect(try run("if(0.5, 1, 2)").0 == 1)
        #expect(try run("equal(1, 1.000001)").0 == 1)
        #expect(try run("above(2, 1) + below(2, 1)").0 == 1)
        #expect(try run("bnot(0)").0 == 1)
        #expect(try run("band(1, 0) + bor(1, 0)").0 == 1)
        #expect(try run("3 > 2 && 1 < 2").0 == 1)
    }

    @Test func bitOperatorsWorkOnIntegers() throws {
        #expect(try run("6 & 3").0 == 2)
        #expect(try run("6 | 3").0 == 7)
    }

    @Test func functions() throws {
        #expect(try run("sqr(4) + abs(-1) + sign(-9) + max(1, 5) + min(1, 5)").0 == 22)
        #expect(try run("int(3.9) + floor(2.5) + ceil(0.2)").0 == 6)
        #expect(abs(try run("sigmoid(0, 1)").0 - 0.5) < 1e-9)
        #expect(try run("exec2(a = 2, a * 3)").0 == 6)
        #expect(try run("loop(4, n = n + 2); n").0 == 8)
    }

    @Test func randomIsAWholeNumberBelowTheBound() throws {
        for _ in 0..<50 {
            let value = try run("rand(5)").0
            #expect(value == value.rounded(.down) && value >= 0 && value < 5)
        }
    }

    @Test func bufferMemory() throws {
        #expect(try run("megabuf(7) = 3; megabuf(7) * 2").0 == 6)
        #expect(try run("gmegabuf(9) = 5; gmegabuf(9)").0 == 5)
    }

    @Test func assignFunctionWritesAVariable() throws {
        let (_, context) = try run("assign(k, 4 + 1)")
        #expect(context["k"] == 5)
    }

    @Test func commentsAndHexAndConstants() throws {
        #expect(try run("1 + // nothing\n 2").0 == 3)
        #expect(try run("0x10").0 == 16)
        #expect(abs(try run("$pi").0 - Double.pi) < 1e-12)
    }

    @Test func badCodeThrows() {
        #expect(throws: (any Error).self) { try MilkProgram("1 +", in: MilkContext()) }
        #expect(throws: (any Error).self) { try MilkProgram("(1", in: MilkContext()) }
    }
}
