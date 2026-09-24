import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit

/// 旁路触摸记录器。
///
/// 附加在 `PKCanvasView` 上，只读取触摸，不参与识别：
/// 始终保持 `.possible` 状态，不取消、不延迟触摸，并允许与所有识别器同时识别，
/// 因此不会改变 PencilKit 的绘制行为以及 `UIScrollView` 的滚动和缩放。
/// 记录期间只写内存，不做文件 IO。
final class TouchLogger: UIGestureRecognizer, UIGestureRecognizerDelegate {
    weak var canvasView: PKCanvasView?
    var session: RecordingSession?
    /// `drawingPolicy` 为 `.anyInput` 时同时记录 `direct` 类型的触摸。
    var recordsDirectTouches = false
    var onSequenceBegan: ((SequenceRecord) -> Void)?
    var onSequenceEnded: ((SequenceRecord) -> Void)?

    /// 以 `ObjectIdentifier(touch)` 为临时键，序列结束后移除。
    private var active: [ObjectIdentifier: SequenceRecord] = [:]

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
        delegate = self
    }

    // MARK: - 触摸

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let session = session, let canvas = canvasView else { return }
        for touch in touches where shouldRecord(touch) {
            let key = ObjectIdentifier(touch)
            if active[key] != nil { continue }
            let sequence = session.beginSequence(
                touchType: TouchLogger.touchTypeName(touch.type),
                tool: ToolState.info(for: canvas.tool),
                viewport: TouchLogger.viewport(of: canvas)
            )
            active[key] = sequence
            onSequenceBegan?(sequence)
            appendCoalesced(for: touch, event: event, to: sequence, session: session, canvas: canvas)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let session = session, let canvas = canvasView else { return }
        for touch in touches {
            guard let sequence = active[ObjectIdentifier(touch)] else { continue }
            appendCoalesced(for: touch, event: event, to: sequence, session: session, canvas: canvas)
            appendPredicted(for: touch, event: event, to: sequence, session: session, canvas: canvas)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finish(touches, event: event, endPhase: "ended")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finish(touches, event: event, endPhase: "cancelled")
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        super.touchesEstimatedPropertiesUpdated(touches)
        guard let session = session, let canvas = canvasView else { return }
        let receivedAt = Clock.now
        let zoom = canvas.zoomScale
        for touch in touches {
            // 更新常在 touchesEnded 之后到达，因此按 estimationUpdateIndex 查找所属序列，
            // 而不是按 UITouch 对象查找。
            guard let index = touch.estimationUpdateIndex?.intValue,
                  let sequence = session.pendingEstimations[index] else { continue }
            let p = touch.preciseLocation(in: canvas)
            let stillExpecting = touch.estimatedPropertiesExpectingUpdates
            sequence.updates.append(EstimationUpdate(
                estimationUpdateIndex: index,
                receivedAt: receivedAt,
                force: Double(touch.force),
                altitude: Double(touch.altitudeAngle),
                azimuth: Double(touch.azimuthAngle(in: canvas)),
                x: Double(p.x / zoom),
                y: Double(p.y / zoom),
                stillExpecting: stillExpecting
            ))
            if stillExpecting.isEmpty {
                session.pendingEstimations.removeValue(forKey: index)
            }
        }
    }

    override func reset() {
        super.reset()
        // 状态保持 .possible，不清空任何已记录的数据。
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    /// 在停用记录器或结束会话前关闭仍在进行的序列。
    func finishActiveSequences(endPhase: String) {
        let sequences = active.values.sorted { $0.sequenceId < $1.sequenceId }
        active.removeAll()
        for sequence in sequences {
            sequence.endPhase = endPhase
            onSequenceEnded?(sequence)
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    // MARK: - 私有

    private func shouldRecord(_ touch: UITouch) -> Bool {
        switch touch.type {
        case .pencil:
            return true
        case .direct:
            return recordsDirectTouches
        default:
            return false
        }
    }

    private func finish(_ touches: Set<UITouch>, event: UIEvent, endPhase: String) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard let sequence = active[key] else { continue }
            if let session = session, let canvas = canvasView {
                appendCoalesced(for: touch, event: event, to: sequence, session: session, canvas: canvas)
            }
            sequence.endPhase = endPhase
            active.removeValue(forKey: key)
            onSequenceEnded?(sequence)
        }
    }

    private func appendCoalesced(for touch: UITouch, event: UIEvent, to sequence: SequenceRecord,
                                 session: RecordingSession, canvas: PKCanvasView) {
        let zoom = canvas.zoomScale
        let offset = canvas.contentOffset
        // 合并触摸数组已包含事件主触摸，不再单独记录主触摸。
        let coalesced = event.coalescedTouches(for: touch) ?? [touch]
        for t in coalesced {
            session.append(makeSample(t, kind: .coalesced, canvas: canvas, zoom: zoom, offset: offset), to: sequence)
        }
    }

    private func appendPredicted(for touch: UITouch, event: UIEvent, to sequence: SequenceRecord,
                                 session: RecordingSession, canvas: PKCanvasView) {
        guard let predicted = event.predictedTouches(for: touch) else { return }
        let zoom = canvas.zoomScale
        let offset = canvas.contentOffset
        for t in predicted {
            session.append(makeSample(t, kind: .predicted, canvas: canvas, zoom: zoom, offset: offset), to: sequence)
        }
    }

    private func makeSample(_ t: UITouch, kind: TouchSample.Kind, canvas: PKCanvasView,
                            zoom: CGFloat, offset: CGPoint) -> TouchSample {
        // preciseLocation(in: canvas) 位于 scroll view 的 bounds 坐标系，已包含 contentOffset。
        let p = t.preciseLocation(in: canvas)
        let expecting = t.estimatedPropertiesExpectingUpdates
        return TouchSample(
            kind: kind,
            phase: TouchLogger.phaseName(t.phase),
            timestamp: t.timestamp,
            x: Double(p.x / zoom),
            y: Double(p.y / zoom),
            vx: Double(p.x - offset.x),
            vy: Double(p.y - offset.y),
            force: Double(t.force),
            maxForce: Double(t.maximumPossibleForce),
            altitude: Double(t.altitudeAngle),
            azimuth: Double(t.azimuthAngle(in: canvas)),
            majorRadius: Double(t.majorRadius),
            majorRadiusTolerance: Double(t.majorRadiusTolerance),
            estimatedProperties: t.estimatedProperties,
            expectingUpdates: expecting,
            estimationUpdateIndex: expecting.isEmpty ? nil : t.estimationUpdateIndex?.intValue
        )
    }

    static func viewport(of canvas: PKCanvasView) -> ViewportInfo {
        return ViewportInfo(
            zoom: Double(canvas.zoomScale),
            contentOffset: canvas.contentOffset,
            visibleSize: canvas.bounds.size
        )
    }

    static func touchTypeName(_ type: UITouch.TouchType) -> String {
        switch type {
        case .direct:
            return "direct"
        case .indirect:
            return "indirect"
        case .pencil:
            return "pencil"
        case .indirectPointer:
            return "indirectPointer"
        @unknown default:
            return "unknown"
        }
    }

    static func phaseName(_ phase: UITouch.Phase) -> String {
        switch phase {
        case .began:
            return "began"
        case .moved:
            return "moved"
        case .stationary:
            return "stationary"
        case .ended:
            return "ended"
        case .cancelled:
            return "cancelled"
        case .regionEntered:
            return "regionEntered"
        case .regionMoved:
            return "regionMoved"
        case .regionExited:
            return "regionExited"
        @unknown default:
            return "unknown"
        }
    }
}
