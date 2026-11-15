import Foundation

/// A double as an integer for the bit operators, without trapping on huge or odd values.
@inline(__always) func milkInt(_ d: Double) -> Int64 {
    d.isFinite ? (abs(d) < 9e18 ? Int64(d) : (d > 0 ? .max : .min)) : 0
}

/// The variables one group of preset code shares: a name for each slot of a flat array, so
/// compiled code reads and writes by index. Names don't care about case; one that was never
/// set reads as 0.
final class MilkContext {
    static let capacity = 1024
    private var slots: [String: Int] = [:]
    let values: UnsafeMutablePointer<Double>
    /// `megabuf`: this context's own scratch memory, made when first used.
    fileprivate var megabuf: UnsafeMutablePointer<Double>?

    /// `gmegabuf`: scratch memory every context shares.
    nonisolated(unsafe) fileprivate static var shared: UnsafeMutablePointer<Double>?
    fileprivate static let bufferSize = 1 << 16

    init() {
        values = .allocate(capacity: Self.capacity)
        values.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        values.deallocate()
        megabuf?.deallocate()
    }

    func slot(_ name: String) -> Int? {
        let key = name.lowercased()
        if let index = slots[key] { return index }
        guard slots.count < Self.capacity else { return nil }
        slots[key] = slots.count
        return slots.count - 1
    }

    func has(_ name: String) -> Bool { slots[name.lowercased()] != nil }

    subscript(name: String) -> Double {
        get { slot(name).map { values[$0] } ?? 0 }
        set { if let index = slot(name) { values[index] = newValue } }
    }

    fileprivate func memory() -> UnsafeMutablePointer<Double> {
        if let megabuf { return megabuf }
        let buffer = UnsafeMutablePointer<Double>.allocate(capacity: Self.bufferSize)
        buffer.initialize(repeating: 0, count: Self.bufferSize)
        megabuf = buffer
        return buffer
    }

    /// Clears `gmegabuf`, as a new preset starts.
    static func resetShared() {
        shared?.update(repeating: 0, count: bufferSize)
    }

    fileprivate static func sharedMemory() -> UnsafeMutablePointer<Double> {
        if let shared { return shared }
        let buffer = UnsafeMutablePointer<Double>.allocate(capacity: bufferSize)
        buffer.initialize(repeating: 0, count: bufferSize)
        shared = buffer
        return buffer
    }

    /// Forgets every value, as a new preset starts.
    func reset() {
        values.update(repeating: 0, count: Self.capacity)
        megabuf?.update(repeating: 0, count: Self.bufferSize)
    }
}

/// Preset code, compiled once to a tree of closures over a context's slots.
final class MilkProgram {
    private let body: () -> Double

    /// Runs the code and gives the value of its last expression.
    @discardableResult func run() -> Double { body() }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    init(_ source: String, in context: MilkContext) throws {
        var parser = Parser(tokens: try Lexer.tokens(source), context: context)
        body = try parser.program()
    }

    // MARK: - Lexing

    fileprivate enum Token: Equatable {
        case number(Double)
        case name(String)
        case op(String)
    }

    fileprivate enum Lexer {
        static let operators = ["<<", ">>", "==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "|=", "&=", "^=",
                                "+", "-", "*", "/", "%", "^", "&", "|", "~", "!", "<", ">", "=", "(", ")", ",", ";", "?", ":", "[", "]"]

        static func tokens(_ text: String) throws -> [Token] {
            let chars = Array(text.lowercased().unicodeScalars)
            var out: [Token] = []
            var i = 0
            func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }
            func isStart(_ c: Unicode.Scalar) -> Bool { (c.value >= 97 && c.value <= 122) || c == "_" || c == "$" }
            while i < chars.count {
                let c = chars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1; continue }
                if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
                if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    i += 2
                    while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                    i += 2
                    continue
                }
                if isDigit(c) || (c == "." && i + 1 < chars.count && isDigit(chars[i + 1])) {
                    var j = i
                    if c == "0", i + 1 < chars.count, chars[i + 1] == "x" {
                        j += 2
                        while j < chars.count, chars[j].properties.isASCIIHexDigit { j += 1 }
                        let digits = String(String.UnicodeScalarView(chars[(i + 2)..<j]))
                        out.append(.number(Double(UInt64(digits, radix: 16) ?? 0)))
                        i = j
                        continue
                    }
                    while j < chars.count, isDigit(chars[j]) || chars[j] == "." { j += 1 }
                    if j < chars.count, chars[j] == "e" {
                        var k = j + 1
                        if k < chars.count, chars[k] == "-" || chars[k] == "+" { k += 1 }
                        if k < chars.count, isDigit(chars[k]) {
                            while k < chars.count, isDigit(chars[k]) { k += 1 }
                            j = k
                        }
                    }
                    let literal = String(String.UnicodeScalarView(chars[i..<j]))
                    out.append(.number(Double(literal) ?? 0))
                    i = j
                    continue
                }
                if isStart(c) {
                    var j = i + 1
                    while j < chars.count, isStart(chars[j]) || isDigit(chars[j]) || chars[j] == "." { j += 1 }
                    out.append(.name(String(String.UnicodeScalarView(chars[i..<j]))))
                    i = j
                    continue
                }
                var matched = false
                for op in operators {
                    let scalars = Array(op.unicodeScalars)
                    if i + scalars.count <= chars.count, Array(chars[i..<(i + scalars.count)]) == scalars {
                        out.append(.op(op))
                        i += scalars.count
                        matched = true
                        break
                    }
                }
                if !matched { throw Failure(description: "unexpected character \(c)") }
            }
            return out
        }
    }

    // MARK: - Parsing and compiling

    private typealias Node = () -> Double

    private struct Parser {
        let tokens: [Token]
        let context: MilkContext
        var position = 0
        let v: UnsafeMutablePointer<Double>

        init(tokens: [Token], context: MilkContext) {
            self.tokens = tokens
            self.context = context
            v = context.values
        }

        var current: Token? { position < tokens.count ? tokens[position] : nil }

        mutating func accept(_ op: String) -> Bool {
            if current == .op(op) { position += 1; return true }
            return false
        }

        mutating func expect(_ op: String) throws {
            guard accept(op) else { throw Failure(description: "expected \(op)") }
        }

        mutating func program() throws -> Node {
            var statements: [Node] = []
            while current != nil {
                if accept(";") { continue }
                statements.append(try expression())
                if current != nil, current != .op(";") { throw Failure(description: "unexpected \(current!)") }
            }
            if statements.isEmpty { return { 0 } }
            if statements.count == 1 { return statements[0] }
            let all = statements
            return {
                var last = 0.0
                for statement in all { last = statement() }
                return last
            }
        }

        // Precedence, loosest first: assignment, ?:, ||, &&, |, ~, &, == !=, < > <= >=, << >>, + -, * / %, unary, ^

        mutating func expression() throws -> Node { try assignment() }

        /// What an assignment writes to: a variable, or a spot in a buffer.
        private enum Target {
            case slot(Int)
            case memory(shared: Bool, index: Node)
        }

        private mutating func target() throws -> Target? {
            let start = position
            if case .name(let name)? = current {
                position += 1
                if (name == "megabuf" || name == "gmegabuf"), accept("(") {
                    let index = try expression()
                    try expect(")")
                    return .memory(shared: name == "gmegabuf", index: index)
                }
                if current != .op("("), let slot = context.slot(name) { return .slot(slot) }
            }
            position = start
            return nil
        }

        mutating func assignment() throws -> Node {
            let start = position
            if let target = try target() {
                for op in ["=", "+=", "-=", "*=", "/=", "%=", "|=", "&=", "^="] where current == .op(op) {
                    position += 1
                    let rhs = try assignment()
                    return Self.makeAssignment(target, op, rhs, v: v, context: context)
                }
            }
            position = start
            return try ternary()
        }

        private static func combine(_ op: String, _ a: Double, _ b: Double) -> Double {
            switch op {
            case "+=": return a + b
            case "-=": return a - b
            case "*=": return a * b
            case "/=": return b == 0 ? 0 : a / b
            case "%=": return Self.mod(a, b)
            case "|=": return Double(milkInt(a) | milkInt(b))
            case "&=": return Double(milkInt(a) & milkInt(b))
            case "^=": return pow(a, b)
            default: return b
            }
        }

        private static func makeAssignment(_ target: Target, _ op: String, _ rhs: @escaping Node,
                                           v: UnsafeMutablePointer<Double>, context: MilkContext) -> Node {
            switch target {
            case .slot(let slot):
                if op == "=" { return { let x = rhs(); v[slot] = x; return x } }
                return { let x = combine(op, v[slot], rhs()); v[slot] = x; return x }
            case .memory(let shared, let index):
                return {
                    let memory = shared ? MilkContext.sharedMemory() : context.memory()
                    let i = Int(truncatingIfNeeded: milkInt(index())) & (MilkContext.bufferSize - 1)
                    let x = op == "=" ? rhs() : combine(op, memory[i], rhs())
                    memory[i] = x
                    return x
                }
            }
        }

        mutating func ternary() throws -> Node {
            let condition = try binary(0)
            guard accept("?") else { return condition }
            let yes = try assignment()
            try expect(":")
            let no = try assignment()
            return { Self.truth(condition()) ? yes() : no() }
        }

        private static let levels: [[String]] = [
            ["||"], ["&&"], ["|"], ["~"], ["&"], ["==", "!="], ["<", ">", "<=", ">="], ["<<", ">>"], ["+", "-"], ["*", "/", "%"],
        ]

        static let epsilon = 1e-5
        static func truth(_ x: Double) -> Bool { abs(x) > epsilon }
        static func bool(_ b: Bool) -> Double { b ? 1 : 0 }
        static func mod(_ a: Double, _ b: Double) -> Double {
            let m = milkInt(b)
            return m == 0 ? 0 : Double(milkInt(a) % m)
        }

        mutating func binary(_ level: Int) throws -> Node {
            if level >= Self.levels.count { return try unary() }
            var left = try binary(level + 1)
            while case .op(let op)? = current, Self.levels[level].contains(op) {
                position += 1
                let right = try binary(level + 1)
                left = Self.makeBinary(op, left, right)
            }
            return left
        }

        private static func makeBinary(_ op: String, _ a: @escaping Node, _ b: @escaping Node) -> Node {
            switch op {
            case "||": return { bool(truth(a()) || truth(b())) }
            case "&&": return { bool(truth(a()) && truth(b())) }
            case "|": return { Double(milkInt(a()) | milkInt(b())) }
            case "&": return { Double(milkInt(a()) & milkInt(b())) }
            case "~": return { Double(milkInt(a()) ^ milkInt(b())) }
            case "==": return { bool(abs(a() - b()) < epsilon) }
            case "!=": return { bool(abs(a() - b()) >= epsilon) }
            case "<": return { bool(a() < b()) }
            case ">": return { bool(a() > b()) }
            case "<=": return { bool(a() <= b()) }
            case ">=": return { bool(a() >= b()) }
            case "<<": return { Double(milkInt(a()) << (milkInt(b()) & 63)) }
            case ">>": return { Double(milkInt(a()) >> (milkInt(b()) & 63)) }
            case "+": return { a() + b() }
            case "-": return { a() - b() }
            case "*": return { a() * b() }
            case "/": return { let d = b(); let n = a(); return d == 0 ? 0 : n / d }
            default: return { let x = a(); return mod(x, b()) }
            }
        }

        mutating func unary() throws -> Node {
            if accept("-") { let x = try unary(); return { -x() } }
            if accept("+") { return try unary() }
            if accept("!") { let x = try unary(); return { Self.bool(!Self.truth(x())) } }
            return try power()
        }

        mutating func power() throws -> Node {
            let base = try primary()
            guard accept("^") else { return base }
            let exponent = try unary()
            return { Self.pow(base(), exponent()) }
        }

        static func pow(_ a: Double, _ b: Double) -> Double {
            let r = Foundation.pow(a, b)
            return r.isFinite ? r : 0
        }

        mutating func primary() throws -> Node {
            guard let token = current else { throw Failure(description: "unexpected end") }
            position += 1
            switch token {
            case .number(let n):
                return { n }
            case .op("("):
                let inner = try expression()
                try expect(")")
                return inner
            case .op(let op):
                throw Failure(description: "unexpected \(op)")
            case .name(let name):
                if accept("(") {
                    var arguments: [Node] = []
                    var targets: [Target?] = []
                    if !accept(")") {
                        repeat {
                            // `assign` wants the variable itself, not its value.
                            let start = position
                            var pure = try target()
                            if pure != nil, current != .op(","), current != .op(")") { pure = nil }
                            targets.append(pure)
                            position = start
                            arguments.append(try expression())
                        } while accept(",")
                        try expect(")")
                    }
                    return try call(name, arguments, targets)
                }
                switch name {
                case "$pi": return { Double.pi }
                case "$e": return { M_E }
                case "$phi": return { 1.618033988749895 }
                default:
                    guard let slot = context.slot(name) else { throw Failure(description: "too many variables") }
                    let v = v
                    return { v[slot] }
                }
            }
        }

        private func call(_ name: String, _ a: [Node], _ targets: [Target?]) throws -> Node {
            func arg(_ i: Int) -> Node { i < a.count ? a[i] : { 0 } }
            let x = arg(0), y = arg(1), z = arg(2)
            let context = context
            switch name {
            case "sin": return { Foundation.sin(x()) }
            case "cos": return { Foundation.cos(x()) }
            case "tan": return { let r = Foundation.tan(x()); return r.isFinite ? r : 0 }
            case "asin": return { let n = x(); return abs(n) <= 1 ? Foundation.asin(n) : 0 }
            case "acos": return { let n = x(); return abs(n) <= 1 ? Foundation.acos(n) : 0 }
            case "atan": return { Foundation.atan(x()) }
            case "atan2": return { Foundation.atan2(x(), y()) }
            case "sqr": return { let n = x(); return n * n }
            case "sqrt": return { Foundation.sqrt(abs(x())) }
            case "pow": return { Self.pow(x(), y()) }
            case "exp": return { let r = Foundation.exp(x()); return r.isFinite ? r : 0 }
            case "log": return { let n = x(); return n > 0 ? Foundation.log(n) : 0 }
            case "log10": return { let n = x(); return n > 0 ? Foundation.log10(n) : 0 }
            case "abs": return { Swift.abs(x()) }
            case "min": return { Swift.min(x(), y()) }
            case "max": return { Swift.max(x(), y()) }
            case "sign": return { let n = x(); return n > 0 ? 1 : n < 0 ? -1 : 0 }
            case "floor": return { Foundation.floor(x()) }
            case "ceil": return { Foundation.ceil(x()) }
            case "int": return { Foundation.trunc(x()) }
            case "sigmoid": return {
                let d = 1 + Foundation.exp(-x() * y())
                return d.isFinite && d != 0 ? 1 / d : 0
            }
            case "rand": return { Foundation.floor(Double.random(in: 0..<1) * Swift.max(x(), 1)) }
            case "if": return { Self.truth(x()) ? y() : z() }
            case "equal": return { Self.bool(Swift.abs(x() - y()) < Self.epsilon) }
            case "above": return { Self.bool(x() > y()) }
            case "below": return { Self.bool(x() < y()) }
            case "bnot": return { Self.bool(!Self.truth(x())) }
            case "band": return { Self.bool(Self.truth(x()) && Self.truth(y())) }
            case "bor": return { Self.bool(Self.truth(x()) || Self.truth(y())) }
            case "exec2": return { _ = x(); return y() }
            case "exec3": return { _ = x(); _ = y(); return z() }
            case "loop": return {
                let count = Swift.min(Int(Swift.max(x(), 0)), 1_000_000)
                var last = 0.0
                for _ in 0..<count { last = y() }
                return last
            }
            case "assign":
                guard targets.count == 2, let target = targets[0] else { throw Failure(description: "assign needs a variable") }
                return Self.makeAssignment(target, "=", y, v: v, context: context)
            case "megabuf", "gmegabuf":
                let shared = name == "gmegabuf"
                return {
                    let memory = shared ? MilkContext.sharedMemory() : context.memory()
                    return memory[Int(truncatingIfNeeded: milkInt(x())) & (MilkContext.bufferSize - 1)]
                }
            default:
                // Something this engine doesn't know reads as 0 and stays out of the way.
                return { 0 }
            }
        }
    }
}
