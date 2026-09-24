import UIKit
import PencilKit

/// 位图渲染。只在主线程调用。
@MainActor
enum DrawingRenderer {
    /// renderRect 相对 `drawing.bounds` 向外扩展的距离（pt）。
    static let margin: CGFloat = 16
    /// 单张位图的像素上限，超过时跳过并写入 meta.json 的 warnings。
    static let maxPixelCount: CGFloat = 150_000_000

    /// `drawing.bounds` 向外扩展 16 pt 后取整到整数 pt。drawing 为空时返回 nil。
    static func renderRect(for drawing: PKDrawing) -> CGRect? {
        guard !drawing.strokes.isEmpty else { return nil }
        let bounds = drawing.bounds
        guard !bounds.isNull, !bounds.isInfinite, !bounds.isEmpty else { return nil }
        return bounds.insetBy(dx: -margin, dy: -margin).integral
    }

    static func unionRenderRect(of drawings: [PKDrawing]) -> CGRect? {
        var result: CGRect?
        for drawing in drawings {
            guard let rect = renderRect(for: drawing) else { continue }
            result = result.map { $0.union(rect) } ?? rect
        }
        return result
    }

    /// 渲染为 PNG。`whiteBackground` 为 true 时先铺同尺寸的白色背景再合成。
    static func pngData(drawing: PKDrawing, rect: CGRect, scale: CGFloat, whiteBackground: Bool) -> Data? {
        guard rect.width > 0, rect.height > 0,
              rect.width * scale * rect.height * scale <= maxPixelCount else {
            return nil
        }

        var image: UIImage?
        // 避免 PencilKit 按深色模式转换墨水颜色。
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: rect, scale: scale)
        }
        guard let rendered = image else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = whiteBackground
        format.preferredRange = .standard
        let canvas = CGRect(origin: .zero, size: rect.size)
        let renderer = UIGraphicsImageRenderer(bounds: canvas, format: format)
        return renderer.pngData { context in
            if whiteBackground {
                UIColor.white.setFill()
                context.fill(canvas)
            }
            rendered.draw(in: canvas)
        }
    }

    static func writePNG(drawing: PKDrawing, rect: CGRect, scale: CGFloat, whiteBackground: Bool,
                         to url: URL, label: String, warnings: ExportWarnings) throws {
        guard let data = pngData(drawing: drawing, rect: rect, scale: scale, whiteBackground: whiteBackground) else {
            let pixels = "\(Int(rect.width * scale))x\(Int(rect.height * scale))"
            warnings.items.append("未生成 \(label)（\(pixels) px，超过上限或渲染失败）")
            return
        }
        try data.write(to: url, options: .atomic)
    }

    /// `2` → `"2"`，`3` → `"3"`，用于文件名 `render@<scale>x.png`。
    static func scaleName(_ scale: CGFloat) -> String {
        return JSONWriter.formatNumber(Double(scale))
    }
}

final class ExportWarnings {
    var items: [String] = []
}

/// 导出过程中的一个步骤。步骤在主线程逐个执行，步骤之间让出 run loop 以刷新进度提示。
struct ExportTask {
    let title: String
    let run: () throws -> Void
}

/// 把一个会话写入 Documents/sessions/<yyyyMMdd-HHmmss>_<name>/。
///
/// 目录结构：
///
///     meta.json            最后写入，可作为保存完成的标记
///     input.json
///     final/drawing.drawing, render@1x.png, render@2x.png, render@<screenScale>x.png,
///           render-transparent@2x.png, strokes.json
///     steps/NNNN/drawing.drawing, render@2x.png, strokes.json, step.json
@MainActor
final class SessionExportJob {
    let folderURL: URL
    private(set) var tasks: [ExportTask] = []

    init(session: RecordingSession, finalDrawing: PKDrawing, screenScale: CGFloat) throws {
        let fileManager = FileManager.default
        let folder = try SessionStore.makeSessionFolder(createdAt: session.createdAt, name: session.name)
        folderURL = folder

        let finalDir = folder.appendingPathComponent("final", isDirectory: true)
        let stepsDir = folder.appendingPathComponent("steps", isDirectory: true)
        try fileManager.createDirectory(at: finalDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stepsDir, withIntermediateDirectories: true)

        let warnings = ExportWarnings()
        let steps = session.steps
        let finalRect = DrawingRenderer.renderRect(for: finalDrawing)
        // 各步位图统一使用最终 drawing 的 renderRect；最终 drawing 为空时退化为各步 renderRect 的并集。
        let stepRect = finalRect ?? DrawingRenderer.unionRenderRect(of: steps.map { $0.drawing })
        if finalRect == nil, stepRect != nil {
            warnings.items.append("最终 drawing 为空，steps 位图改用各步 renderRect 的并集")
        }

        var scales: [CGFloat] = [1, 2]
        if !scales.contains(screenScale) {
            scales.append(screenScale)
        }

        tasks.append(ExportTask(title: "input.json") {
            let data = JSONWriter.data(session.inputDocument())
            try data.write(to: folder.appendingPathComponent("input.json", isDirectory: false), options: .atomic)
        })

        tasks.append(ExportTask(title: "final/drawing.drawing") {
            try finalDrawing.dataRepresentation()
                .write(to: finalDir.appendingPathComponent("drawing.drawing", isDirectory: false), options: .atomic)
        })

        tasks.append(ExportTask(title: "final/strokes.json") {
            let data = JSONWriter.data(StrokeAnalyzer.document(for: finalDrawing, renderRect: finalRect))
            try data.write(to: finalDir.appendingPathComponent("strokes.json", isDirectory: false), options: .atomic)
        })

        if let rect = finalRect {
            for scale in scales {
                let fileName = "render@\(DrawingRenderer.scaleName(scale))x.png"
                tasks.append(ExportTask(title: "final/\(fileName)") {
                    try DrawingRenderer.writePNG(
                        drawing: finalDrawing, rect: rect, scale: scale, whiteBackground: true,
                        to: finalDir.appendingPathComponent(fileName, isDirectory: false),
                        label: "final/\(fileName)", warnings: warnings
                    )
                })
            }
            tasks.append(ExportTask(title: "final/render-transparent@2x.png") {
                try DrawingRenderer.writePNG(
                    drawing: finalDrawing, rect: rect, scale: 2, whiteBackground: false,
                    to: finalDir.appendingPathComponent("render-transparent@2x.png", isDirectory: false),
                    label: "final/render-transparent@2x.png", warnings: warnings
                )
            })
        }

        for step in steps {
            let folderName = SessionExportJob.stepFolderName(step.afterSequenceId)
            let dir = stepsDir.appendingPathComponent(folderName, isDirectory: true)
            tasks.append(ExportTask(title: "steps/\(folderName)") {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                try step.drawing.dataRepresentation()
                    .write(to: dir.appendingPathComponent("drawing.drawing", isDirectory: false), options: .atomic)
                try JSONWriter.data(StrokeAnalyzer.document(for: step.drawing, renderRect: stepRect))
                    .write(to: dir.appendingPathComponent("strokes.json", isDirectory: false), options: .atomic)
                try JSONWriter.data(session.stepDocument(step))
                    .write(to: dir.appendingPathComponent("step.json", isDirectory: false), options: .atomic)
                if let rect = stepRect {
                    try DrawingRenderer.writePNG(
                        drawing: step.drawing, rect: rect, scale: 2, whiteBackground: true,
                        to: dir.appendingPathComponent("render@2x.png", isDirectory: false),
                        label: "steps/\(folderName)/render@2x.png", warnings: warnings
                    )
                }
            })
        }

        tasks.append(ExportTask(title: "meta.json") {
            let data = JSONWriter.data(session.metaDocument(
                finalStrokeCount: finalDrawing.strokes.count,
                warnings: warnings.items
            ))
            try data.write(to: folder.appendingPathComponent("meta.json", isDirectory: false), options: .atomic)
        })
    }

    /// 序列编号四位补零。
    static func stepFolderName(_ sequenceId: Int) -> String {
        let digits = String(sequenceId)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}
