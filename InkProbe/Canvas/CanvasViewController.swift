import UIKit
import PencilKit

/// 主界面：顶部工具栏 + 无限 PKCanvasView + 系统 PKToolPicker。
///
/// 画布、工具与橡皮的行为全部保持 PencilKit 默认实现；本控制器只负责记录和导出。
final class CanvasViewController: UIViewController, PKCanvasViewDelegate, PKToolPickerObserver {
    /// 画布基准尺寸（drawing 坐标）。`contentSize` 始终为基准尺寸 × `zoomScale`。
    static let baseCanvasSize = CGSize(width: 100_000, height: 100_000)
    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 4.0
    /// 序列结束后等待 drawing 变化回调的时间。
    static let snapshotTimeout: TimeInterval = 0.5
    /// viewportChanged 事件的最小记录间隔。
    static let viewportEventInterval: TimeInterval = 0.05

    private let canvasView = PKCanvasView()
    private let toolbar = ToolbarView()
    private let toolPicker = PKToolPicker()
    private let touchLogger = TouchLogger(target: nil, action: nil)
    private let hud = ProgressHUD()

    private var session: RecordingSession?
    private var didPerformInitialLayout = false
    private var snapshotsEnabled = true
    private var pendingSnapshotSequenceId: Int?
    private var pendingSnapshotToken = 0
    private var lastDrawingChangeUptime: TimeInterval = -Double.infinity
    private var lastViewportRecord: (time: TimeInterval, viewport: ViewportInfo)?
    private var suppressViewportEvents = false
    private var isSaving = false
    private var currentStrokeCount = 0
    private var statusTimer: Timer?
    private var exportJob: SessionExportJob?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        configureCanvas()
        configureToolbar()
        layoutViews()
        configureToolPicker()
        observeUndoManager()
        statusTimer = Timer.scheduledTimer(
            timeInterval: 0.25, target: self, selector: #selector(statusTimerFired), userInfo: nil, repeats: true
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !didPerformInitialLayout, canvasView.bounds.width > 0, canvasView.bounds.height > 0 else { return }
        didPerformInitialLayout = true
        // 启动时自动创建一个未命名会话，并把视口定位到画布中心。
        startNewSession(named: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        canvasView.becomeFirstResponder()
    }

    // MARK: - 配置

    private func configureCanvas() {
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.delegate = self
        canvasView.backgroundColor = .white
        canvasView.isOpaque = true
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.drawingPolicy = .pencilOnly
        canvasView.minimumZoomScale = CanvasViewController.minZoom
        canvasView.maximumZoomScale = CanvasViewController.maxZoom
        canvasView.zoomScale = 1.0
        // 不让安全区域改变 contentInset，保证 drawing 坐标 = (视图坐标 + contentOffset) ÷ zoomScale。
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.contentInset = .zero

        touchLogger.canvasView = canvasView
        touchLogger.recordsDirectTouches = false
        touchLogger.onSequenceBegan = { [weak self] sequence in
            self?.sequenceDidBegin(sequence)
        }
        touchLogger.onSequenceEnded = { [weak self] sequence in
            self?.sequenceDidEnd(sequence)
        }
        canvasView.addGestureRecognizer(touchLogger)
    }

    private func configureToolbar() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.onPencilOnlyChanged = { [weak self] isOn in
            self?.setPencilOnly(isOn)
        }
        toolbar.onSnapshotsChanged = { [weak self] isOn in
            self?.setSnapshotsEnabled(isOn)
        }
        toolbar.onLoggingChanged = { [weak self] isOn in
            self?.setLoggingEnabled(isOn)
        }
        toolbar.onNewSession = { [weak self] in
            self?.promptNewSession()
        }
        toolbar.onSave = { [weak self] in
            self?.saveSession()
        }
        toolbar.onShowSessions = { [weak self] in
            self?.showSessionList()
        }
    }

    private func layoutViews() {
        view.addSubview(canvasView)
        view.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 52),
            canvasView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureToolPicker() {
        // 只设置外观，不修改工具选择。colorUserInterfaceStyle 避免选择器按深色模式转换颜色。
        toolPicker.overrideUserInterfaceStyle = .light
        toolPicker.colorUserInterfaceStyle = .light
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        toolPicker.addObserver(self)
    }

    private func observeUndoManager() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(undoManagerDidUndo(_:)),
                           name: .NSUndoManagerDidUndoChange, object: nil)
        center.addObserver(self, selector: #selector(undoManagerDidRedo(_:)),
                           name: .NSUndoManagerDidRedoChange, object: nil)
    }

    // MARK: - 视口

    private var drawingPolicyName: String {
        switch canvasView.drawingPolicy {
        case .pencilOnly:
            return "pencilOnly"
        case .anyInput:
            return "anyInput"
        case .default:
            return "default"
        @unknown default:
            return "unknown"
        }
    }

    private func currentViewport() -> ViewportInfo {
        return TouchLogger.viewport(of: canvasView)
    }

    private func updateContentSize() {
        let zoom = canvasView.zoomScale
        canvasView.contentSize = CGSize(
            width: CanvasViewController.baseCanvasSize.width * zoom,
            height: CanvasViewController.baseCanvasSize.height * zoom
        )
    }

    /// 缩放恢复为 1.0，视口定位到画布中心。
    private func resetViewport() {
        suppressViewportEvents = true
        canvasView.zoomScale = 1.0
        updateContentSize()
        let visible = canvasView.bounds.size
        canvasView.contentOffset = CGPoint(
            x: ((canvasView.contentSize.width - visible.width) / 2).rounded(),
            y: ((canvasView.contentSize.height - visible.height) / 2).rounded()
        )
        suppressViewportEvents = false
    }

    /// 滚动或缩放期间每 50 ms 最多记录一次，手势结束时记录最终值。
    private func recordViewportIfNeeded(isFinal: Bool) {
        guard let session = session, !suppressViewportEvents else { return }
        let viewport = currentViewport()
        let now = Clock.now
        if let last = lastViewportRecord {
            if last.viewport == viewport { return }
            if !isFinal && now - last.time < CanvasViewController.viewportEventInterval { return }
        }
        lastViewportRecord = (time: now, viewport: viewport)
        session.record(.viewportChanged(time: now, viewport: viewport))
    }

    // MARK: - UIScrollViewDelegate（PKCanvasViewDelegate 继承自 UIScrollViewDelegate）
    // 注意：不实现 viewForZooming(in:)，缩放由 PencilKit 自行处理。

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        recordViewportIfNeeded(isFinal: false)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateContentSize()
        recordViewportIfNeeded(isFinal: false)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            recordViewportIfNeeded(isFinal: true)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        recordViewportIfNeeded(isFinal: true)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        recordViewportIfNeeded(isFinal: true)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        recordViewportIfNeeded(isFinal: true)
    }

    // MARK: - PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        lastDrawingChangeUptime = Clock.now
        currentStrokeCount = canvasView.drawing.strokes.count
        if let sequenceId = pendingSnapshotSequenceId {
            pendingSnapshotSequenceId = nil
            takeSnapshot(afterSequenceId: sequenceId, drawingChanged: true)
        }
    }

    // MARK: - PKToolPickerObserver

    func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
        session?.record(.toolChanged(time: Clock.now, tool: ToolState.info(for: toolPicker.selectedTool)))
    }

    // MARK: - 撤销与重做

    @objc private func undoManagerDidUndo(_ notification: Notification) {
        guard let session = session else { return }
        session.record(.undo(time: Clock.now, afterSequenceId: session.lastSequenceId))
    }

    @objc private func undoManagerDidRedo(_ notification: Notification) {
        guard let session = session else { return }
        session.record(.redo(time: Clock.now, afterSequenceId: session.lastSequenceId))
    }

    // MARK: - 逐步快照

    private func sequenceDidBegin(_ sequence: SequenceRecord) {
        // 新序列开始前，先保存上一个仍在等待的快照，避免新序列的改动混入。
        flushPendingSnapshot()
    }

    private func sequenceDidEnd(_ sequence: SequenceRecord) {
        guard snapshotsEnabled, session != nil, !isSaving else { return }
        flushPendingSnapshot()

        // PencilKit 可能在同一次事件分发中、先于本回调提交 drawing 变化。
        if let lastTimestamp = sequence.lastCoalescedTimestamp, lastDrawingChangeUptime >= lastTimestamp {
            takeSnapshot(afterSequenceId: sequence.sequenceId, drawingChanged: true)
            return
        }

        pendingSnapshotSequenceId = sequence.sequenceId
        pendingSnapshotToken += 1
        let token = pendingSnapshotToken
        DispatchQueue.main.asyncAfter(deadline: .now() + CanvasViewController.snapshotTimeout) { [weak self] in
            guard let self = self,
                  self.pendingSnapshotToken == token,
                  let sequenceId = self.pendingSnapshotSequenceId else { return }
            self.pendingSnapshotSequenceId = nil
            self.takeSnapshot(afterSequenceId: sequenceId, drawingChanged: false)
        }
    }

    private func flushPendingSnapshot() {
        guard let sequenceId = pendingSnapshotSequenceId else { return }
        pendingSnapshotSequenceId = nil
        takeSnapshot(afterSequenceId: sequenceId, drawingChanged: false)
    }

    private func takeSnapshot(afterSequenceId: Int, drawingChanged: Bool) {
        guard let session = session else { return }
        session.addStep(
            afterSequenceId: afterSequenceId,
            drawingChanged: drawingChanged,
            drawing: canvasView.drawing,
            uptime: Clock.now
        )
    }

    // MARK: - 工具栏开关

    private func setPencilOnly(_ isOn: Bool) {
        canvasView.drawingPolicy = isOn ? .pencilOnly : .anyInput
        touchLogger.recordsDirectTouches = !isOn
        session?.record(.drawingPolicyChanged(time: Clock.now, policy: drawingPolicyName))
    }

    private func setSnapshotsEnabled(_ isOn: Bool) {
        if !isOn {
            flushPendingSnapshot()
        }
        snapshotsEnabled = isOn
    }

    private func setLoggingEnabled(_ isOn: Bool) {
        if isOn {
            touchLogger.isEnabled = true
        } else {
            touchLogger.finishActiveSequences(endPhase: "loggerDisabled")
            touchLogger.isEnabled = false
        }
    }

    // MARK: - 会话

    private func promptNewSession() {
        let alert = UIAlertController(
            title: "新会话",
            message: "将清空画布，当前会话中未保存的数据会被丢弃。会话名称可以留空。",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "会话名称（可选）"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.canvasView.becomeFirstResponder()
        })
        alert.addAction(UIAlertAction(title: "开始", style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text
            self?.startNewSession(named: name)
            self?.canvasView.becomeFirstResponder()
        })
        present(alert, animated: true)
    }

    private func startNewSession(named rawName: String?) {
        pendingSnapshotSequenceId = nil
        pendingSnapshotToken += 1
        session = nil
        touchLogger.session = nil
        touchLogger.finishActiveSequences(endPhase: "sessionReset")

        canvasView.drawing = PKDrawing()
        canvasView.undoManager?.removeAllActions()
        currentStrokeCount = 0
        lastDrawingChangeUptime = -Double.infinity
        resetViewport()

        let newSession = RecordingSession(
            name: SessionStore.displayName(from: rawName),
            drawingPolicy: drawingPolicyName,
            initialViewport: currentViewport()
        )
        session = newSession
        touchLogger.session = newSession
        lastViewportRecord = (time: newSession.startUptime, viewport: newSession.initialViewport)
        refreshStatus()
    }

    private func saveSession() {
        guard let session = session, !isSaving else { return }
        flushPendingSnapshot()
        isSaving = true
        touchLogger.finishActiveSequences(endPhase: "sessionSaved")

        let finalDrawing = canvasView.drawing
        canvasView.isUserInteractionEnabled = false
        toolbar.setControlsEnabled(false)
        canvasView.resignFirstResponder()
        hud.show(in: view, text: "正在准备保存…")

        do {
            exportJob = try SessionExportJob(
                session: session,
                finalDrawing: finalDrawing,
                screenScale: UIScreen.main.scale
            )
        } catch {
            finishSaving(folder: nil, error: error)
            return
        }
        runExportTask(at: 0)
    }

    /// 在主线程逐个执行导出步骤；每步之间让出 run loop，使进度提示得以刷新。
    private func runExportTask(at index: Int) {
        guard let job = exportJob else { return }
        guard index < job.tasks.count else {
            finishSaving(folder: job.folderURL, error: nil)
            return
        }
        hud.setText("正在保存 \(index + 1)/\(job.tasks.count)\n\(job.tasks[index].title)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self = self, let job = self.exportJob else { return }
            do {
                try autoreleasepool {
                    try job.tasks[index].run()
                }
            } catch {
                self.finishSaving(folder: job.folderURL, error: error)
                return
            }
            self.runExportTask(at: index + 1)
        }
    }

    private func finishSaving(folder: URL?, error: Error?) {
        exportJob = nil
        hud.hide()
        isSaving = false
        canvasView.isUserInteractionEnabled = true
        toolbar.setControlsEnabled(true)

        if let error = error {
            var message = error.localizedDescription
            if let folder = folder {
                message += "\n\n未完成的文件夹：\(folder.lastPathComponent)"
            }
            let alert = UIAlertController(title: "保存失败", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
                self?.canvasView.becomeFirstResponder()
            })
            present(alert, animated: true)
            return
        }

        let folderName = folder?.lastPathComponent ?? ""
        startNewSession(named: nil)
        let alert = UIAlertController(
            title: "已保存",
            message: "会话已保存到 Documents/sessions/\(folderName)。\n已自动开始新的未命名会话。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
            self?.canvasView.becomeFirstResponder()
        })
        present(alert, animated: true)
    }

    private func showSessionList() {
        let list = SessionListViewController()
        list.onClose = { [weak self] in
            self?.canvasView.becomeFirstResponder()
        }
        let navigation = UINavigationController(rootViewController: list)
        navigation.modalPresentationStyle = .formSheet
        navigation.isModalInPresentation = true
        present(navigation, animated: true)
    }

    // MARK: - 状态文本

    @objc private func statusTimerFired() {
        refreshStatus()
    }

    private func refreshStatus() {
        let name = session?.name ?? "—"
        let samples = session?.sampleCount ?? 0
        let sequences = session?.sequences.count ?? 0
        let zoom = String(format: "%.2f", Double(canvasView.zoomScale))
        toolbar.statusLabel.text = "会话 \(name) · 样本 \(samples) · 序列 \(sequences) · 笔划 \(currentStrokeCount) · 缩放 \(zoom)×"
    }
}
