import UIKit
import PencilKit

/// 一个逐步快照：序列结束后保存的 drawing 值及其指纹和 diff。
struct StepSnapshot {
    let step: Int
    let afterSequenceId: Int
    let drawingChanged: Bool
    let drawing: PKDrawing
    let uptime: TimeInterval
    let events: [String]
    let fingerprints: [StrokeFingerprint]
    let diff: JSONValue
}

/// 当前会话的全部内存数据。会话结束时由 `SessionExportJob` 一次性写盘。
@MainActor
final class RecordingSession {
    let name: String
    let createdAt: Date
    let startUptime: TimeInterval
    let drawingPolicy: String
    let initialViewport: ViewportInfo

    /// 会话第一条样本的 `UITouch.timestamp` 原始值。
    private(set) var clockOrigin: TimeInterval?
    private(set) var sequences: [SequenceRecord] = []
    private(set) var events: [InputEvent] = []
    private(set) var sampleCount = 0
    private(set) var steps: [StepSnapshot] = []
    /// estimationUpdateIndex → 所属序列，用于匹配估计属性的后续更新。
    var pendingEstimations: [Int: SequenceRecord] = [:]

    private var nextTouchId = 1
    private var eventsSinceLastStep: [String] = []

    init(name: String, drawingPolicy: String, initialViewport: ViewportInfo) {
        self.name = name
        self.createdAt = Date()
        self.startUptime = Clock.now
        self.drawingPolicy = drawingPolicy
        self.initialViewport = initialViewport
    }

    /// 导出时使用的时间原点。没有任何样本时退化为会话开始时间。
    var exportClockOrigin: TimeInterval {
        return clockOrigin ?? startUptime
    }

    var lastSequenceId: Int {
        return sequences.last?.sequenceId ?? 0
    }

    // MARK: - 记录

    func beginSequence(touchType: String, tool: ToolInfo, viewport: ViewportInfo) -> SequenceRecord {
        let sequence = SequenceRecord(
            sequenceId: sequences.count + 1,
            touchId: nextTouchId,
            touchType: touchType,
            tool: tool,
            viewportAtBegin: viewport
        )
        nextTouchId += 1
        sequences.append(sequence)
        return sequence
    }

    func append(_ sample: TouchSample, to sequence: SequenceRecord) {
        if clockOrigin == nil {
            clockOrigin = sample.timestamp
        }
        sequence.samples.append(sample)
        sampleCount += 1
        if let index = sample.estimationUpdateIndex {
            pendingEstimations[index] = sequence
        }
    }

    func record(_ event: InputEvent) {
        events.append(event)
        switch event {
        case .undo:
            eventsSinceLastStep.append("undo")
        case .redo:
            eventsSinceLastStep.append("redo")
        default:
            break
        }
    }

    func addStep(afterSequenceId: Int, drawingChanged: Bool, drawing: PKDrawing, uptime: TimeInterval) {
        let fingerprints = StrokeAnalyzer.fingerprints(of: drawing)
        let previous = steps.last
        let diff = StepDiff.compute(
            previous: previous?.fingerprints ?? [],
            previousStep: previous?.step ?? 0,
            current: fingerprints
        )
        steps.append(StepSnapshot(
            step: steps.count + 1,
            afterSequenceId: afterSequenceId,
            drawingChanged: drawingChanged,
            drawing: drawing,
            uptime: uptime,
            events: eventsSinceLastStep,
            fingerprints: fingerprints,
            diff: diff
        ))
        eventsSinceLastStep = []
    }

    // MARK: - 导出文档

    func inputDocument() -> JSONValue {
        let origin = exportClockOrigin
        return .object([
            ("schemaVersion", .int(1)),
            ("sequences", .array(sequences.map { $0.json(origin: origin) })),
            ("events", .array(events.map { $0.json(origin: origin) }))
        ])
    }

    func stepDocument(_ step: StepSnapshot) -> JSONValue {
        return .object([
            ("schemaVersion", .int(1)),
            ("step", .int(step.step)),
            ("afterSequenceId", .int(step.afterSequenceId)),
            ("drawingChanged", .bool(step.drawingChanged)),
            ("strokeCount", .int(step.fingerprints.count)),
            ("t", .num(step.uptime - exportClockOrigin)),
            ("eventsSincePreviousStep", .strings(step.events)),
            ("diff", step.diff)
        ])
    }

    func metaDocument(finalStrokeCount: Int, warnings: [String]) -> JSONValue {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
        let buildVersion = info?["CFBundleVersion"] as? String ?? "?"
        let screen = UIScreen.main
        return .object([
            ("schemaVersion", .int(1)),
            ("appVersion", .string("\(shortVersion) (\(buildVersion))")),
            ("sessionName", .string(name)),
            ("createdAt", .string(DateFormats.iso8601Seconds.string(from: createdAt))),
            ("device", .object([
                ("model", .string(DeviceInfo.machine)),
                ("systemVersion", .string(UIDevice.current.systemVersion)),
                ("screenScale", .cg(screen.scale)),
                ("maximumFramesPerSecond", .int(screen.maximumFramesPerSecond))
            ])),
            ("canvas", .object([
                ("mode", .string("infinite")),
                ("contentSize", .size(CanvasViewController.baseCanvasSize)),
                ("initialContentOffset", .point(initialViewport.contentOffset)),
                ("initialZoom", .num(initialViewport.zoom)),
                ("initialVisibleSize", .size(initialViewport.visibleSize)),
                ("minZoom", .cg(CanvasViewController.minZoom)),
                ("maxZoom", .cg(CanvasViewController.maxZoom)),
                ("background", .string("#FFFFFF"))
            ])),
            ("drawingPolicy", .string(drawingPolicy)),
            ("clockOrigin", .num(exportClockOrigin)),
            ("counts", .object([
                ("samples", .int(sampleCount)),
                ("sequences", .int(sequences.count)),
                ("finalStrokes", .int(finalStrokeCount)),
                ("steps", .int(steps.count))
            ])),
            ("exportFormat", .object([
                ("stepStrokes", .string("incremental")),
                ("stepPathData", .string("firstAppearanceOnly")),
                ("stepImages", .string("lastStepOnly")),
                ("json", .string("compact"))
            ])),
            ("warnings", .strings(warnings))
        ])
    }
}
