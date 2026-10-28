import AppKit
import Foundation

/// 图床图片缓存：下载、缓存、合并进行中的请求，供预览区渲染 ![](url) 使用
final class ImageStore {
    static let shared = ImageStore()

    private static var baseStorage: URL = FileManager.default.homeDirectoryForCurrentUser

    /// 相对图片路径的基准目录（应为绝对路径）。
    /// 默认用户主目录；编辑器打开 .md 文件后由 App 改为该文件所在目录。
    static var baseDirectory: URL {
        get {
            baseStorage.isFileURL && baseStorage.path.hasPrefix("/")
                ? baseStorage
                : FileManager.default.homeDirectoryForCurrentUser
        }
        set { baseStorage = newValue }
    }

    private let cache = NSCache<NSURL, NSImage>()
    private var inflight: [String: [(NSImage?) -> Void]] = [:]
    private let queue = DispatchQueue(label: "notesmd.imagestore")

    private init() {
        cache.countLimit = 64
    }

    /// 解析图片地址：http/https/file URL、本地绝对路径、~ 开头路径，
    /// 或相对路径（按 baseDirectory 解析）
    static func url(from text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let url = URL(string: t), let scheme = url.scheme,
           ["http", "https", "file"].contains(scheme.lowercased()) {
            return url
        }
        let path = (t as NSString).expandingTildeInPath
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return baseDirectory.standardizedFileURL
            .appendingPathComponent(path)
            .standardizedFileURL
    }

    /// 同步取缓存；未命中返回 nil
    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    /// 同步读取本地图片并写入缓存（「粘贴进备忘录」等需要同步拿到图片数据的场景）。
    /// 远程 URL 直接返回 false；已缓存返回 true。
    @discardableResult
    func loadLocalSync(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if cached(url) != nil { return true }
        guard let img = NSImage(contentsOf: url) else { return false }
        cache.setObject(img, forKey: url as NSURL)
        return true
    }

    /// 异步获取图片（已缓存则立即回调；同一 URL 的并发请求只下载一次）。回调始终在主线程。
    func image(for url: URL, completion: @escaping (NSImage?) -> Void) {
        if let img = cache.object(forKey: url as NSURL) {
            DispatchQueue.main.async { completion(img) }
            return
        }
        var shouldFetch = false
        queue.sync {
            if var waiters = inflight[url.absoluteString] {
                waiters.append(completion)
                inflight[url.absoluteString] = waiters
            } else {
                inflight[url.absoluteString] = [completion]
                shouldFetch = true
            }
        }
        guard shouldFetch else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let img = data.flatMap { NSImage(data: $0) }
            var callbacks: [(NSImage?) -> Void] = []
            if let self {
                self.queue.sync {
                    callbacks = self.inflight[url.absoluteString] ?? []
                    self.inflight[url.absoluteString] = nil
                    if let img {
                        self.cache.setObject(img, forKey: url as NSURL)
                    }
                }
            }
            DispatchQueue.main.async { callbacks.forEach { $0(img) } }
        }.resume()
    }

    /// 下载中的占位图
    static func placeholder(size: NSSize) -> NSImage {
        let s = NSSize(width: max(size.width, 20), height: max(size.height, 20))
        let img = NSImage(size: s)
        img.lockFocus()
        let inset = NSRect(x: 0.5, y: 0.5, width: s.width - 1, height: s.height - 1)
        let path = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
        NSColor(white: 0.92, alpha: 1).setFill()
        path.fill()
        NSColor(white: 0.75, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
        img.unlockFocus()
        return img
    }

    /// 计算不超过约束的展示尺寸（等比缩放，不放大）
    static func fitSize(_ size: NSSize, maxWidth: CGFloat, maxHeight: CGFloat) -> NSSize {
        guard size.width > 0, size.height > 0 else {
            return NSSize(width: min(maxWidth, 320), height: 100)
        }
        let scale = min(1, maxWidth / size.width, maxHeight / size.height)
        return NSSize(width: size.width * scale, height: size.height * scale)
    }

    /// 返回指定展示尺寸的图片（复用原表示，按尺寸缩放绘制）
    static func scaled(_ image: NSImage, toSize size: NSSize) -> NSImage {
        guard image.size != size else { return image }
        let copy = NSImage(size: size)
        image.representations.forEach { copy.addRepresentation($0) }
        return copy
    }
}
