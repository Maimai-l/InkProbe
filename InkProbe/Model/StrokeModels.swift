import UIKit
import PencilKit

/// 笔划指纹及用于 diff 的片段信息。
struct StrokeFingerprint {
    let index: Int
    let pathCreationDate: Double
    let pathHash: String
    let fragmentHash: String
    /// 导出用的遮罩区间：`mask` 为 nil 时为空数组。
    let maskedPathRanges: [ClosedRange<CGFloat>]
    /// `mask` 的 SVG path data；无遮罩时为 nil。
    let maskSVG: String?

    var rangesJSON: JSONValue {
        return .array(maskedPathRanges.map { JSONValue.nums([Double($0.lowerBound), Double($0.upperBound)]) })
    }

    var fragmentEntryJSON: JSONValue {
        return .object([
            ("index", .int(index)),
            ("fragmentHash", .string(fragmentHash)),
            ("maskedPathRanges", rangesJSON)
        ])
    }
}

/// 增量编码时记录每个片段第一次写入完整数据的步骤。
final class FragmentRegistry {
    var firstWritten: [String: (step: Int, dir: String)] = [:]
}

enum StrokeAnalyzer {
    /// 曲线插值步长（pt）。
    static let interpolationDistance: CGFloat = 0.5

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    static func exportedRanges(of stroke: PKStroke) -> [ClosedRange<CGFloat>] {
        return stroke.mask == nil ? [] : stroke.maskedPathRanges
    }

    /// 计算 `pathHash` 与 `fragmentHash`（64 位 FNV-1a）。
    ///
    /// - pathHash：pathCreationDate（Float64 LE）、pathCount（UInt32 LE），
    ///   以及每个控制点的 x、y、timeOffset、width、height、opacity、force、azimuth、altitude（Float64 LE）。
    /// - fragmentHash：pathHash 的 8 字节（大端，即十六进制字符串的书写顺序）、
    ///   transform 六个值、maskedPathRanges 全部端点（Float64 LE），以及 mask 字符串的 UTF-8 字节
    ///   （mask 为 null 时为单字节 0x00）。
    static func fingerprint(of stroke: PKStroke, index: Int) -> StrokeFingerprint {
        let path = stroke.path
        let creationDate = path.creationDate.timeIntervalSinceReferenceDate

        var pathHasher = FNV1a64()
        pathHasher.add(double: creationDate)
        pathHasher.add(uint32: UInt32(truncatingIfNeeded: path.count))
        for point in path {
            pathHasher.add(double: Double(point.location.x))
            pathHasher.add(double: Double(point.location.y))
            pathHasher.add(double: Double(point.timeOffset))
            pathHasher.add(double: Double(point.size.width))
            pathHasher.add(double: Double(point.size.height))
            pathHasher.add(double: Double(point.opacity))
            pathHasher.add(double: Double(point.force))
            pathHasher.add(double: Double(point.azimuth))
            pathHasher.add(double: Double(point.altitude))
        }

        let ranges = exportedRanges(of: stroke)
        let maskSVG: String? = stroke.mask.map { BezierPathSVG.pathData($0.cgPath) }

        var fragmentHasher = FNV1a64()
        fragmentHasher.add(bigEndian: pathHasher.value)
        let t = stroke.transform
        for v in [t.a, t.b, t.c, t.d, t.tx, t.ty] {
            fragmentHasher.add(double: Double(v))
        }
        for range in ranges {
            fragmentHasher.add(double: Double(range.lowerBound))
            fragmentHasher.add(double: Double(range.upperBound))
        }
        if let maskSVG = maskSVG {
            fragmentHasher.add(bytes: maskSVG.utf8)
        } else {
            fragmentHasher.add(byte: 0)
        }

        return StrokeFingerprint(
            index: index,
            pathCreationDate: creationDate,
            pathHash: pathHasher.hex,
            fragmentHash: fragmentHasher.hex,
            maskedPathRanges: ranges,
            maskSVG: maskSVG
        )
    }

    static func fingerprints(of drawing: PKDrawing) -> [StrokeFingerprint] {
        return drawing.strokes.enumerated().map { fingerprint(of: $0.element, index: $0.offset) }
    }

    /// 生成 strokes.json 的内容。
    ///
    /// `registry` 为 nil 时每个片段都写完整数据（`strokesEncoding = "full"`，用于 final/）。
    /// 传入 `registry` 时使用增量编码（用于 steps/）：片段第一次出现时写完整数据并登记，
    /// 之后只写引用 `{index, fragmentHash, pathHash, fullDataStep, fullDataDir}`。
    static func document(for drawing: PKDrawing, renderRect: CGRect?,
                         registry: FragmentRegistry? = nil, step: Int = 0, stepDir: String = "") -> JSONValue {
        let strokes = drawing.strokes
        var items: [JSONValue] = []
        items.reserveCapacity(strokes.count)
        for (index, stroke) in strokes.enumerated() {
            let fp = fingerprint(of: stroke, index: index)
            if let registry = registry {
                if let first = registry.firstWritten[fp.fragmentHash] {
                    items.append(.object([
                        ("index", .int(index)),
                        ("fragmentHash", .string(fp.fragmentHash)),
                        ("pathHash", .string(fp.pathHash)),
                        ("fullDataStep", .int(first.step)),
                        ("fullDataDir", .string(first.dir))
                    ]))
                    continue
                }
                registry.firstWritten[fp.fragmentHash] = (step: step, dir: stepDir)
            }
            items.append(strokeJSON(stroke, fingerprint: fp))
        }
        return .object([
            ("schemaVersion", .int(1)),
            ("strokesEncoding", .string(registry == nil ? "full" : "incremental")),
            ("renderRect", renderRect.map { JSONValue.rect($0) } ?? .null),
            ("strokes", .array(items))
        ])
    }

    static func strokeJSON(_ stroke: PKStroke, fingerprint fp: StrokeFingerprint) -> JSONValue {
        let path = stroke.path
        let t = stroke.transform

        var randomSeed: JSONValue = .null
        if #available(iOS 16.0, *) {
            randomSeed = .int(Int(stroke.randomSeed))
        }

        var points: [JSONValue] = []
        points.reserveCapacity(path.count)
        for point in path {
            points.append(pointJSON(point, rangeIndex: nil))
        }

        var interpolated: [JSONValue] = []
        if path.count > 0 {
            if stroke.mask == nil {
                for point in path.interpolatedPoints(in: nil, by: .distance(interpolationDistance)) {
                    interpolated.append(pointJSON(point, rangeIndex: 0))
                }
            } else {
                for (rangeIndex, range) in fp.maskedPathRanges.enumerated() {
                    for point in path.interpolatedPoints(in: range, by: .distance(interpolationDistance)) {
                        interpolated.append(pointJSON(point, rangeIndex: rangeIndex))
                    }
                }
            }
        }

        return .object([
            ("index", .int(fp.index)),
            ("pathCreationDate", .num(fp.pathCreationDate)),
            ("pathCreationDateISO", .string(isoFormatter.string(from: path.creationDate))),
            ("pathCount", .int(path.count)),
            ("pathHash", .string(fp.pathHash)),
            ("fragmentHash", .string(fp.fragmentHash)),
            ("ink", .object([
                ("inkType", .string(ToolState.inkTypeName(stroke.ink.inkType))),
                ("color", .nums(ColorUtil.srgbComponents(stroke.ink.color)))
            ])),
            ("transform", .nums([Double(t.a), Double(t.b), Double(t.c), Double(t.d), Double(t.tx), Double(t.ty)])),
            ("randomSeed", randomSeed),
            ("renderBounds", .rect(stroke.renderBounds)),
            ("points", .array(points)),
            ("interpolatedPoints", .array(interpolated)),
            ("mask", .str(fp.maskSVG)),
            ("maskedPathRanges", fp.rangesJSON)
        ])
    }

    static func pointJSON(_ p: PKStrokePoint, rangeIndex: Int?) -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            ("x", .cg(p.location.x)),
            ("y", .cg(p.location.y)),
            ("timeOffset", .num(p.timeOffset)),
            ("width", .cg(p.size.width)),
            ("height", .cg(p.size.height)),
            ("opacity", .cg(p.opacity)),
            ("force", .cg(p.force)),
            ("azimuth", .cg(p.azimuth)),
            ("altitude", .cg(p.altitude))
        ]
        if let rangeIndex = rangeIndex {
            pairs.append(("rangeIndex", .int(rangeIndex)))
        }
        return .object(pairs)
    }
}

/// step.json 中 `diff` 的计算。
enum StepDiff {
    static func compute(previous: [StrokeFingerprint], previousStep: Int, current: [StrokeFingerprint]) -> JSONValue {
        // 片段：按 fragmentHash 做多重集合比较。
        var remainingPrevious: [String: Int] = [:]
        for f in previous {
            remainingPrevious[f.fragmentHash, default: 0] += 1
        }
        var remainingCurrent: [String: Int] = [:]
        for f in current {
            remainingCurrent[f.fragmentHash, default: 0] += 1
        }

        var added: [String] = []
        var unchangedCount = 0
        for f in current {
            if let n = remainingPrevious[f.fragmentHash], n > 0 {
                remainingPrevious[f.fragmentHash] = n - 1
                unchangedCount += 1
            } else {
                added.append(f.fragmentHash)
            }
        }
        var removed: [String] = []
        for f in previous {
            if let n = remainingCurrent[f.fragmentHash], n > 0 {
                remainingCurrent[f.fragmentHash] = n - 1
            } else {
                removed.append(f.fragmentHash)
            }
        }

        // 来源路径：按 pathHash 分组，只列出片段集合发生变化的路径。
        var order: [String] = []
        var seen = Set<String>()
        var before: [String: [StrokeFingerprint]] = [:]
        var after: [String: [StrokeFingerprint]] = [:]
        for f in current {
            after[f.pathHash, default: []].append(f)
            if seen.insert(f.pathHash).inserted { order.append(f.pathHash) }
        }
        for f in previous {
            before[f.pathHash, default: []].append(f)
            if seen.insert(f.pathHash).inserted { order.append(f.pathHash) }
        }

        var paths: [JSONValue] = []
        for hash in order {
            let b = before[hash] ?? []
            let a = after[hash] ?? []
            if b.map({ $0.fragmentHash }).sorted() == a.map({ $0.fragmentHash }).sorted() {
                continue
            }
            let change: String
            if b.isEmpty {
                change = "added"
            } else if a.isEmpty {
                change = "removed"
            } else {
                change = "modified"
            }
            let creationDate = (a.first ?? b.first)?.pathCreationDate
            paths.append(.object([
                ("pathHash", .string(hash)),
                ("pathCreationDate", .num(creationDate)),
                ("change", .string(change)),
                ("before", .array(b.map { $0.fragmentEntryJSON })),
                ("after", .array(a.map { $0.fragmentEntryJSON }))
            ]))
        }

        return .object([
            ("previousStep", .int(previousStep)),
            ("fragments", .object([
                ("added", .strings(added)),
                ("removed", .strings(removed)),
                ("unchangedCount", .int(unchangedCount))
            ])),
            ("paths", .array(paths))
        ])
    }
}
