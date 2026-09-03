import AppKit
import Foundation

/// 本地图床：粘贴的图片若无网络链接，则保存到应用支持目录，返回本地路径
enum MediaStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("NotesMD", isDirectory: true)
                        .appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 保存图片，返回可写进 markdown 的本地路径；失败返回 nil
    static func save(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let t = Date().timeIntervalSince1970
        let name = "img-\(Int(t))-\(Int64.random(in: 0...0xFFFFFF)).png"
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }
}
