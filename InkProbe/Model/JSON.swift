import Foundation
import CoreGraphics

/// 有序 JSON 值。
///
/// 导出不使用 `JSONEncoder`，原因有三：需要把可选字段显式写成 `null`；
/// 遇到 `NaN` / `Infinity` 时需要写成 `null` 而不是抛错；
/// 需要保证 Double 以最短往返（round-trip）形式输出，不做四舍五入。
enum JSONValue {
    case null
    case bool(Bool)
    case int(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    /// 非有限值（NaN、±Infinity）与 nil 都写为 null。
    static func num(_ value: Double?) -> JSONValue {
        guard let value = value, value.isFinite else { return .null }
        return .number(value)
    }

    static func cg(_ value: CGFloat) -> JSONValue {
        return num(Double(value))
    }

    static func str(_ value: String?) -> JSONValue {
        guard let value = value else { return .null }
        return .string(value)
    }

    static func nums(_ values: [Double]) -> JSONValue {
        return .array(values.map { JSONValue.num($0) })
    }

    static func strings(_ values: [String]) -> JSONValue {
        return .array(values.map { JSONValue.string($0) })
    }

    static func point(_ p: CGPoint) -> JSONValue {
        return nums([Double(p.x), Double(p.y)])
    }

    static func size(_ s: CGSize) -> JSONValue {
        return nums([Double(s.width), Double(s.height)])
    }

    static func rect(_ r: CGRect) -> JSONValue {
        return nums([Double(r.origin.x), Double(r.origin.y), Double(r.size.width), Double(r.size.height)])
    }
}

/// 把 `JSONValue` 序列化为 UTF-8 文本。
///
/// 输出为缩进格式，但只含标量（或标量数组）的对象和数组写在同一行，
/// 使每个样本、每个路径点各占一行，便于阅读和按行比较。
enum JSONWriter {
    static func data(_ value: JSONValue) -> Data {
        var out = ""
        write(value, indent: 0, into: &out)
        out.append("\n")
        return Data(out.utf8)
    }

    /// 有限 Double 的文本形式：整数值写成不带小数点的整数，其余使用 Swift 的最短往返表示。
    static func formatNumber(_ d: Double) -> String {
        if d == d.rounded(.towardZero) && abs(d) < 1e15 {
            return String(Int64(d))
        }
        return "\(d)"
    }

    private static func isScalar(_ v: JSONValue) -> Bool {
        switch v {
        case .array, .object:
            return false
        default:
            return true
        }
    }

    private static func isScalarArray(_ v: JSONValue) -> Bool {
        if case .array(let items) = v {
            return items.allSatisfy { isScalar($0) }
        }
        return false
    }

    private static func isFlat(_ v: JSONValue) -> Bool {
        switch v {
        case .array(let items):
            return items.allSatisfy { isScalar($0) || isScalarArray($0) }
        case .object(let pairs):
            return pairs.allSatisfy { isScalar($0.1) || isScalarArray($0.1) }
        default:
            return true
        }
    }

    private static func write(_ v: JSONValue, indent: Int, into out: inout String) {
        switch v {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .number(let d):
            out += d.isFinite ? formatNumber(d) : "null"
        case .string(let s):
            writeString(s, into: &out)
        case .array(let items):
            if items.isEmpty {
                out += "[]"
                return
            }
            if isFlat(v) {
                out += "["
                for (i, item) in items.enumerated() {
                    if i > 0 { out += ", " }
                    write(item, indent: indent, into: &out)
                }
                out += "]"
                return
            }
            let pad = String(repeating: "  ", count: indent + 1)
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += pad
                write(item, indent: indent + 1, into: &out)
                out += i < items.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: "  ", count: indent) + "]"
        case .object(let pairs):
            if pairs.isEmpty {
                out += "{}"
                return
            }
            if isFlat(v) {
                out += "{"
                for (i, pair) in pairs.enumerated() {
                    if i > 0 { out += ", " }
                    writeString(pair.0, into: &out)
                    out += ": "
                    write(pair.1, indent: indent, into: &out)
                }
                out += "}"
                return
            }
            let pad = String(repeating: "  ", count: indent + 1)
            out += "{\n"
            for (i, pair) in pairs.enumerated() {
                out += pad
                writeString(pair.0, into: &out)
                out += ": "
                write(pair.1, indent: indent + 1, into: &out)
                out += i < pairs.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: "  ", count: indent) + "}"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

/// 64 位 FNV-1a 哈希。
struct FNV1a64 {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    mutating func add(byte: UInt8) {
        value ^= UInt64(byte)
        value = value &* FNV1a64.prime
    }

    mutating func add<S: Sequence>(bytes: S) where S.Element == UInt8 {
        for b in bytes {
            add(byte: b)
        }
    }

    /// 按小端字节序加入 64 位整数。
    mutating func add(littleEndian v: UInt64) {
        for i in 0..<8 {
            add(byte: UInt8(truncatingIfNeeded: v >> UInt64(i * 8)))
        }
    }

    /// 按大端字节序加入 64 位整数（与十六进制字符串的书写顺序一致）。
    mutating func add(bigEndian v: UInt64) {
        for i in (0..<8).reversed() {
            add(byte: UInt8(truncatingIfNeeded: v >> UInt64(i * 8)))
        }
    }

    /// Float64 小端。
    mutating func add(double d: Double) {
        add(littleEndian: d.bitPattern)
    }

    /// UInt32 小端。
    mutating func add(uint32 v: UInt32) {
        for i in 0..<4 {
            add(byte: UInt8(truncatingIfNeeded: v >> UInt32(i * 8)))
        }
    }

    /// 16 位小写十六进制字符串。
    var hex: String {
        let s = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - s.count)) + s
    }
}
