import Foundation

public enum MathExpressionError: LocalizedError, Equatable, Sendable {
    case invalidToken(String)
    case unexpectedEnd
    case unexpectedToken(String)
    case divisionByZero
    case unknownFunction(String)
    case nonFiniteResult

    public var errorDescription: String? {
        switch self {
        case .invalidToken(let token): "Invalid token: \(token)"
        case .unexpectedEnd: "The expression ended unexpectedly."
        case .unexpectedToken(let token): "Unexpected token: \(token)"
        case .divisionByZero: "Division by zero is undefined."
        case .unknownFunction(let function): "Unknown function: \(function)"
        case .nonFiniteResult: "The result is not finite."
        }
    }
}

public struct MathExpressionEvaluator: Sendable {
    public init() {}

    public func evaluate(_ expression: String, variables: [String: Double] = [:]) throws -> Double {
        var parser = try Parser(expression: expression, variables: variables)
        let result = try parser.parse()
        guard result.isFinite else { throw MathExpressionError.nonFiniteResult }
        return result
    }
}

fileprivate struct Parser {
    fileprivate enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case plus, minus, multiply, divide, power, leftParen, rightParen, comma, end

        var label: String {
            switch self {
            case .number(let value): String(value)
            case .identifier(let value): value
            case .plus: "+"
            case .minus: "-"
            case .multiply: "*"
            case .divide: "/"
            case .power: "^"
            case .leftParen: "("
            case .rightParen: ")"
            case .comma: ","
            case .end: "end"
            }
        }
    }

    private var tokens: [Token]
    private var index = 0
    private let variables: [String: Double]

    init(expression: String, variables: [String: Double]) throws {
        self.tokens = try Lexer.tokenize(expression)
        self.variables = variables.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    }

    mutating func parse() throws -> Double {
        let value = try parseExpression()
        guard current == .end else { throw MathExpressionError.unexpectedToken(current.label) }
        return value
    }

    private var current: Token { tokens[index] }

    private mutating func advance() { index = min(index + 1, tokens.count - 1) }

    private mutating func parseExpression() throws -> Double {
        var value = try parseTerm()
        while true {
            if current == .plus {
                advance()
                value += try parseTerm()
            } else if current == .minus {
                advance()
                value -= try parseTerm()
            } else {
                return value
            }
        }
    }

    private mutating func parseTerm() throws -> Double {
        var value = try parsePower()
        while true {
            if current == .multiply {
                advance()
                value *= try parsePower()
            } else if current == .divide {
                advance()
                let divisor = try parsePower()
                guard divisor != 0 else { throw MathExpressionError.divisionByZero }
                value /= divisor
            } else {
                return value
            }
        }
    }

    private mutating func parsePower() throws -> Double {
        var value = try parseUnary()
        if current == .power {
            advance()
            value = Foundation.pow(value, try parsePower())
        }
        return value
    }

    private mutating func parseUnary() throws -> Double {
        if current == .plus {
            advance()
            return try parseUnary()
        }
        if current == .minus {
            advance()
            return -(try parseUnary())
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> Double {
        switch current {
        case .number(let value):
            advance()
            return value
        case .identifier(let rawName):
            let name = rawName.lowercased()
            advance()
            if current == .leftParen {
                advance()
                var arguments: [Double] = []
                if current != .rightParen {
                    arguments.append(try parseExpression())
                    while current == .comma {
                        advance()
                        arguments.append(try parseExpression())
                    }
                }
                guard current == .rightParen else { throw MathExpressionError.unexpectedToken(current.label) }
                advance()
                return try Self.call(name, arguments: arguments)
            }
            if name == "pi" { return .pi }
            if name == "e" { return Foundation.exp(1) }
            guard let value = variables[name] else { throw MathExpressionError.invalidToken(rawName) }
            return value
        case .leftParen:
            advance()
            let value = try parseExpression()
            guard current == .rightParen else { throw MathExpressionError.unexpectedToken(current.label) }
            advance()
            return value
        case .end:
            throw MathExpressionError.unexpectedEnd
        default:
            throw MathExpressionError.unexpectedToken(current.label)
        }
    }

    private static func call(_ name: String, arguments: [Double]) throws -> Double {
        switch (name, arguments) {
        case ("sqrt", let values) where values.count == 1: Foundation.sqrt(values[0])
        case ("abs", let values) where values.count == 1: Swift.abs(values[0])
        case ("sin", let values) where values.count == 1: Foundation.sin(values[0])
        case ("cos", let values) where values.count == 1: Foundation.cos(values[0])
        case ("tan", let values) where values.count == 1: Foundation.tan(values[0])
        case ("ln", let values) where values.count == 1: Foundation.log(values[0])
        case ("log", let values) where values.count == 1: Foundation.log10(values[0])
        case ("pow", let values) where values.count == 2: Foundation.pow(values[0], values[1])
        case ("min", let values) where !values.isEmpty: values.min()!
        case ("max", let values) where !values.isEmpty: values.max()!
        default: throw MathExpressionError.unknownFunction(name)
        }
    }
}

fileprivate enum Lexer {
    static func tokenize(_ expression: String) throws -> [Parser.Token] {
        var tokens: [Parser.Token] = []
        var index = expression.startIndex

        while index < expression.endIndex {
            let character = expression[index]
            if character.isWhitespace {
                index = expression.index(after: index)
                continue
            }

            if character.isNumber || character == "." {
                let start = index
                var hasExponent = false
                index = expression.index(after: index)
                while index < expression.endIndex {
                    let next = expression[index]
                    if next.isNumber || next == "." {
                        index = expression.index(after: index)
                    } else if (next == "e" || next == "E") && !hasExponent {
                        hasExponent = true
                        index = expression.index(after: index)
                        if index < expression.endIndex,
                           (expression[index] == "+" || expression[index] == "-") {
                            index = expression.index(after: index)
                        }
                    } else {
                        break
                    }
                }
                let raw = String(expression[start..<index])
                guard let value = Double(raw) else { throw MathExpressionError.invalidToken(raw) }
                tokens.append(.number(value))
                continue
            }

            if character.isLetter || character == "_" {
                let start = index
                index = expression.index(after: index)
                while index < expression.endIndex,
                      (expression[index].isLetter || expression[index].isNumber || expression[index] == "_") {
                    index = expression.index(after: index)
                }
                tokens.append(.identifier(String(expression[start..<index])))
                continue
            }

            let token: Parser.Token
            switch character {
            case "+": token = .plus
            case "-": token = .minus
            case "*", "×": token = .multiply
            case "/", "÷": token = .divide
            case "^": token = .power
            case "(": token = .leftParen
            case ")": token = .rightParen
            case ",": token = .comma
            default: throw MathExpressionError.invalidToken(String(character))
            }
            tokens.append(token)
            index = expression.index(after: index)
        }

        tokens.append(.end)
        return tokens
    }
}
