import Foundation

/// 使用 `NSFileCoordinator` 的 `.forUploading` 选项把会话文件夹打包为 zip。
enum Zipper {
    /// 返回临时目录中的 `<会话文件夹名>.zip`。zip 内部包含会话文件夹这一层目录。
    /// 该方法是同步的，应在后台队列调用。
    static func zipSessionFolder(_ folder: URL) throws -> URL {
        let fileManager = FileManager.default
        let destination = fileManager.temporaryDirectory
            .appendingPathComponent(folder.lastPathComponent + ".zip", isDirectory: false)

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinationError) { zipURL in
            // zipURL 只在回调内有效，必须在这里复制出去。
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: zipURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError {
            throw error
        }
        if let error = copyError {
            throw error
        }
        return destination
    }
}
