import UIKit
import PencilKit

/// 读取并序列化 PencilKit 工具。只读取，不修改任何工具参数。
enum ToolState {
    static func info(for tool: PKTool) -> ToolInfo {
        if let inking = tool as? PKInkingTool {
            return ToolInfo(
                category: "inking",
                eraserType: nil,
                inkType: inkTypeName(inking.inkType),
                color: ColorUtil.srgbComponents(inking.color),
                width: Double(inking.width)
            )
        }
        if let eraser = tool as? PKEraserTool {
            var width: Double?
            if #available(iOS 16.4, *) {
                width = Double(eraser.width)
            }
            return ToolInfo(
                category: "eraser",
                eraserType: eraserTypeName(eraser.eraserType),
                inkType: nil,
                color: nil,
                width: width
            )
        }
        if tool is PKLassoTool {
            return ToolInfo(category: "lasso", eraserType: nil, inkType: nil, color: nil, width: nil)
        }
        return ToolInfo(category: "other", eraserType: nil, inkType: nil, color: nil, width: nil)
    }

    /// `com.apple.ink.pen` → `pen`。
    static func inkTypeName(_ type: PKInkingTool.InkType) -> String {
        let raw = type.rawValue
        let prefix = "com.apple.ink."
        return raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
    }

    static func eraserTypeName(_ type: PKEraserTool.EraserType) -> String {
        switch type {
        case .vector:
            return "vector"
        case .bitmap:
            return "bitmap"
        default:
            // iOS 16.4 起的 fixedWidthBitmap 等。
            return String(describing: type)
        }
    }
}

enum ColorUtil {
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)

    /// 在浅色外观下解析颜色，并转换到 sRGB 色彩空间，返回 RGBA。
    static func srgbComponents(_ color: UIColor) -> [Double] {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        if let space = srgb,
           let converted = resolved.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
           let components = converted.components,
           components.count >= 4 {
            return [Double(components[0]), Double(components[1]), Double(components[2]), Double(components[3])]
        }
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b), Double(a)]
    }
}
