import UIKit

/// 与 `UITouch.timestamp` 同一时基的当前时间（系统启动后的非睡眠时间，单位秒）。
enum Clock {
    static var now: TimeInterval {
        return ProcessInfo.processInfo.systemUptime
    }
}

/// 一次触摸序列开始时，或工具切换事件中记录的工具。
struct ToolInfo {
    var category: String
    var eraserType: String?
    var inkType: String?
    /// sRGB RGBA，取值 0 到 1。
    var color: [Double]?
    /// 宽度（pt）。橡皮宽度仅在 iOS 16.4 及以上读取。
    var width: Double?

    var json: JSONValue {
        return .object([
            ("category", .string(category)),
            ("eraserType", .str(eraserType)),
            ("inkType", .str(inkType)),
            ("color", color.map { JSONValue.nums($0) } ?? .null),
            ("width", .num(width))
        ])
    }
}

/// 画布视口：缩放比例、`contentOffset` 和可见区域尺寸（`canvasView.bounds.size`）。
struct ViewportInfo: Equatable {
    var zoom: Double
    var contentOffset: CGPoint
    var visibleSize: CGSize

    var fields: [(String, JSONValue)] {
        return [
            ("zoom", .num(zoom)),
            ("contentOffset", .point(contentOffset)),
            ("visibleSize", .size(visibleSize))
        ]
    }

    var json: JSONValue {
        return .object(fields)
    }
}

/// `UITouch.Properties` 与字符串数组之间的转换。
enum TouchProperties {
    static func names(_ properties: UITouch.Properties) -> [String] {
        var result: [String] = []
        if properties.contains(.force) { result.append("force") }
        if properties.contains(.azimuth) { result.append("azimuth") }
        if properties.contains(.altitude) { result.append("altitude") }
        if properties.contains(.location) { result.append("location") }
        return result
    }
}

/// 一条触摸样本。时间保存原始 `UITouch.timestamp`，导出时再减去 clockOrigin。
struct TouchSample {
    enum Kind: String {
        case coalesced
        case predicted
    }

    let kind: Kind
    let phase: String
    let timestamp: TimeInterval
    /// drawing 坐标。
    let x: Double
    let y: Double
    /// 视图坐标（以画布可见区域左上角为原点）。
    let vx: Double
    let vy: Double
    let force: Double
    let maxForce: Double
    let altitude: Double
    let azimuth: Double
    let majorRadius: Double
    let majorRadiusTolerance: Double
    let estimatedProperties: UITouch.Properties
    let expectingUpdates: UITouch.Properties
    /// 仅在 `expectingUpdates` 非空时有值。
    let estimationUpdateIndex: Int?

    func json(origin: TimeInterval) -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            ("kind", .string(kind.rawValue)),
            ("phase", .string(phase)),
            ("t", .num(timestamp - origin)),
            ("x", .num(x)),
            ("y", .num(y)),
            ("vx", .num(vx)),
            ("vy", .num(vy)),
            ("force", .num(force)),
            ("maxForce", .num(maxForce)),
            ("altitude", .num(altitude)),
            ("azimuth", .num(azimuth)),
            ("majorRadius", .num(majorRadius)),
            ("majorRadiusTolerance", .num(majorRadiusTolerance)),
            ("estimatedProperties", .strings(TouchProperties.names(estimatedProperties))),
            ("expectingUpdates", .strings(TouchProperties.names(expectingUpdates)))
        ]
        if let index = estimationUpdateIndex {
            pairs.append(("estimationUpdateIndex", .int(index)))
        }
        return .object(pairs)
    }
}

/// 估计属性的一次后续更新。不修改原样本，只追加记录。
struct EstimationUpdate {
    let estimationUpdateIndex: Int
    let receivedAt: TimeInterval
    let force: Double
    let altitude: Double
    let azimuth: Double
    let x: Double
    let y: Double
    let stillExpecting: UITouch.Properties

    func json(origin: TimeInterval) -> JSONValue {
        return .object([
            ("estimationUpdateIndex", .int(estimationUpdateIndex)),
            ("tReceived", .num(receivedAt - origin)),
            ("force", .num(force)),
            ("altitude", .num(altitude)),
            ("azimuth", .num(azimuth)),
            ("x", .num(x)),
            ("y", .num(y)),
            ("stillExpecting", .strings(TouchProperties.names(stillExpecting)))
        ])
    }
}

/// 同一个 touchId 从 began 到 ended / cancelled 的全部样本。
final class SequenceRecord {
    let sequenceId: Int
    let touchId: Int
    let touchType: String
    let tool: ToolInfo
    let viewportAtBegin: ViewportInfo
    /// `ended`、`cancelled`；记录被中断时为 `loggerDisabled` 或 `sessionSaved`；序列未结束时为 nil。
    var endPhase: String?
    var samples: [TouchSample] = []
    var updates: [EstimationUpdate] = []

    init(sequenceId: Int, touchId: Int, touchType: String, tool: ToolInfo, viewportAtBegin: ViewportInfo) {
        self.sequenceId = sequenceId
        self.touchId = touchId
        self.touchType = touchType
        self.tool = tool
        self.viewportAtBegin = viewportAtBegin
        samples.reserveCapacity(512)
    }

    /// 最后一条合并触摸样本的原始时间戳。
    var lastCoalescedTimestamp: TimeInterval? {
        return samples.last(where: { $0.kind == .coalesced })?.timestamp
    }

    func json(origin: TimeInterval) -> JSONValue {
        return .object([
            ("sequenceId", .int(sequenceId)),
            ("touchId", .int(touchId)),
            ("touchType", .string(touchType)),
            ("tool", tool.json),
            ("viewportAtBegin", viewportAtBegin.json),
            ("endPhase", .str(endPhase)),
            ("samples", .array(samples.map { $0.json(origin: origin) })),
            ("updates", .array(updates.map { $0.json(origin: origin) }))
        ])
    }
}

/// `input.json` 的 `events` 数组中的事件。时间保存原始系统时间。
enum InputEvent {
    case toolChanged(time: TimeInterval, tool: ToolInfo)
    case viewportChanged(time: TimeInterval, viewport: ViewportInfo)
    case undo(time: TimeInterval, afterSequenceId: Int)
    case redo(time: TimeInterval, afterSequenceId: Int)
    case drawingPolicyChanged(time: TimeInterval, policy: String)

    func json(origin: TimeInterval) -> JSONValue {
        switch self {
        case let .toolChanged(time, tool):
            return .object([
                ("type", .string("toolChanged")),
                ("t", .num(time - origin)),
                ("tool", tool.json)
            ])
        case let .viewportChanged(time, viewport):
            var pairs: [(String, JSONValue)] = [
                ("type", .string("viewportChanged")),
                ("t", .num(time - origin))
            ]
            pairs.append(contentsOf: viewport.fields)
            return .object(pairs)
        case let .undo(time, afterSequenceId):
            return .object([
                ("type", .string("undo")),
                ("t", .num(time - origin)),
                ("afterSequenceId", .int(afterSequenceId))
            ])
        case let .redo(time, afterSequenceId):
            return .object([
                ("type", .string("redo")),
                ("t", .num(time - origin)),
                ("afterSequenceId", .int(afterSequenceId))
            ])
        case let .drawingPolicyChanged(time, policy):
            return .object([
                ("type", .string("drawingPolicyChanged")),
                ("t", .num(time - origin)),
                ("drawingPolicy", .string(policy))
            ])
        }
    }
}
