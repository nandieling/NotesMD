import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - pixhost 图床模型与 API

/// 一次上传的图片记录（本地历史用）
struct PixImage: Codable, Equatable {
    var name: String
    var direct: String    // 原图直链（iN.pixhost.to/images/...）
    var show: String      // 展示页（pixhost.to/show/...）
    var thumb: String     // 缩略图（tN.pixhost.to/thumbs/...）
    var manage: String?   // 管理链接（含删除 token，可能为空）
    var date: Date
    var size: Int?        // 字节数
}

enum PixhostAPI {
    struct UploadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let apiBase = "https://api.pixhost.to"

    /// 由缩略图地址推导原图直链：
    /// https://t3.pixhost.to/thumbs/5452/xxx.png -> https://img3.pixhost.to/images/5452/xxx.png
    static func directLink(fromThumb th: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: #"^(https?://)t(\d+)\.pixhost\.(to|cc|st)/thumbs/"#) else { return th }
        let ns = th as NSString
        if let m = re.firstMatch(in: th, range: NSRange(location: 0, length: ns.length)) {
            return re.stringByReplacingMatches(in: th, range: m.range,
                                               withTemplate: "$1img$2.pixhost.$3/images/")
        }
        return th
    }

    /// 上传图片文件（不支持的格式自动转 PNG），回调在主线程
    static func upload(fileURL: URL, completion: @escaping (Result<PixImage, Error>) -> Void) {
        let supported: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif"]
        let ext = fileURL.pathExtension.lowercased()
        let name0 = fileURL.lastPathComponent
        do {
            var data = try Data(contentsOf: fileURL)
            var name = name0
            var mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "image/png"
            let mimeOK = ["image/jpeg", "image/png", "image/gif", "image/webp", "image/avif"].contains(mime)
            if !supported.contains(ext) || !mimeOK {
                guard let img = NSImage(contentsOf: fileURL),
                      let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    DispatchQueue.main.async {
                        completion(.failure(UploadError(message: "无法读取图片：\(name0)")))
                    }
                    return
                }
                data = png
                mime = "image/png"
                name = (name0 as NSString).deletingPathExtension + ".png"
            }
            upload(data: data, filename: name, mime: mime, completion: completion)
        } catch {
            DispatchQueue.main.async {
                completion(.failure(UploadError(message: "读取文件失败：\(error.localizedDescription)")))
            }
        }
    }

    private static func upload(data: Data, filename: String, mime: String,
                               completion: @escaping (Result<PixImage, Error>) -> Void) {
        let boundary = "----notesmd" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var body = Data()
        // multipart part：头部与数据之间必须是空行（\r\n\r\n）
        func part(_ head: String, _ payload: Data) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data(head.utf8))
            body.append(Data("\r\n\r\n".utf8))
            body.append(payload)
            body.append(Data("\r\n".utf8))
        }
        part("Content-Disposition: form-data; name=\"img\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)", data)
        part("Content-Disposition: form-data; name=\"content_type\"", Data("0".utf8))
        part("Content-Disposition: form-data; name=\"max_th_size\"", Data("420".utf8))
        part("Content-Disposition: form-data; name=\"include_manage_url\"", Data("1".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))

        guard let url = URL(string: "\(apiBase)/images") else {
            DispatchQueue.main.async { completion(.failure(UploadError(message: "API 地址无效"))) }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err {
                DispatchQueue.main.async { completion(.failure(err)) }
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let rawBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if ProcessInfo.processInfo.environment["NMD_DEBUG"] != nil {
                FileHandle.standardError.write(Data("pixhost resp code=\(code) body=\(rawBody.prefix(400))\n".utf8))
            }
            guard (200..<300).contains(code),
                  let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let show = obj["show_url"] as? String else {
                let msg: String
                switch code {
                case 413: msg = "图片超过 10MB 限制"
                case 400: msg = "格式不被支持（支持 JPG / PNG / GIF / WebP / AVIF）"
                case 0: msg = "网络错误，请检查网络连接"
                default: msg = "上传失败（HTTP \(code)）"
                }
                DispatchQueue.main.async { completion(.failure(UploadError(message: msg))) }
                return
            }
            let thumb = (obj["th_url"] as? String) ?? ""
            let img = PixImage(
                name: (obj["name"] as? String) ?? filename,
                direct: directLink(fromThumb: thumb),
                show: show,
                thumb: thumb,
                manage: obj["manage_url"] as? String,
                date: Date(),
                size: (obj["size"] as? NSNumber)?.intValue
            )
            DispatchQueue.main.async { completion(.success(img)) }
        }.resume()
    }

    /// 用 manage 链接删除远端图片（200 success 或 410 已删除都算成功）
    static func delete(_ image: PixImage, completion: @escaping (Bool) -> Void) {
        guard let manage = image.manage,
              let token = manage.components(separatedBy: "/").last,
              !token.isEmpty,
              let url = URL(string: "\(apiBase)/management/\(token)/delete") else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var ok = code == 410
            if (200..<300).contains(code),
               let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                ok = (obj["success"] as? Bool) ?? false
            }
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }
}

// MARK: - 历史图片存储（UserDefaults JSON）

enum PixHistory {
    private static let key = "notesmd.pixhistory"
    static let limit = 500

    static func load() -> [PixImage] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([PixImage].self, from: d) else { return [] }
        return items
    }

    static func save(_ items: [PixImage]) {
        if let d = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    static func add(_ item: PixImage) {
        var items = load()
        items.insert(item, at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
        save(items)
    }

    static func remove(_ item: PixImage) {
        var items = load()
        items.removeAll { $0.show == item.show }
        save(items)
    }
}

// MARK: - 翻转容器（内容从顶部往下排，避免短内容贴底）

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 缩略图视图

final class ThumbnailView: NSImageView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        imageScaling = .scaleProportionallyUpOrDown
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(urlString: String) {
        guard let url = URL(string: urlString), url.scheme != nil else { return }
        ImageStore.shared.image(for: url) { [weak self] img in
            if let img { self?.image = img }
        }
    }
}

/// 行/卡片上按钮的 action 载体
final class ItemActions: NSObject {
    let item: PixImage
    private let onCopy: () -> Void
    private let onRemove: () -> Void
    private let onOpen: () -> Void
    init(item: PixImage, onCopy: @escaping () -> Void, onRemove: @escaping () -> Void,
         onOpen: @escaping () -> Void = {}) {
        self.item = item
        self.onCopy = onCopy
        self.onRemove = onRemove
        self.onOpen = onOpen
    }
    @objc func copyLink() { onCopy() }
    @objc func remove() { onRemove() }
    @objc func openShow() { onOpen() }
}

// MARK: - 上传结果 sheet

final class PixResultSheet: NSObject {
    private let results: [Result<PixImage, Error>]
    private weak var view: NSView?
    private let onInsert: (String) -> Void

    init(results: [Result<PixImage, Error>], onInsert: @escaping (String) -> Void) {
        self.results = results
        self.okItems_ = results.compactMap { r in
            if case .success(let img) = r { return img } else { return nil }
        }
        self.onInsert = onInsert
    }

    /// 返回 sheet 内容视图（尺寸已定好）
    func makeView() -> NSView {
        let okCount = results.filter {
            if case .success = $0 { return true } else { return false }
        }.count
        let failCount = results.count - okCount
        let width: CGFloat = 580
        let rowH: CGFloat = 62
        let h = max(150, 44 + CGFloat(okCount) * rowH + (failCount > 0 ? 30 : 0) + 56)
        let sheet = NSView(frame: NSRect(x: 0, y: 0, width: width, height: h))
        view = sheet

        let title = NSTextField(labelWithString: okCount > 0 ? "已上传到 pixhost（\(okCount) 张）" : "上传失败")
        title.font = NSFont.boldSystemFont(ofSize: 14)
        title.frame = NSRect(x: 18, y: h - 34, width: width - 36, height: 20)
        sheet.addSubview(title)

        let okItems_ = okItems()
        var y = h - 44 - 30
        for (i, img) in okItems_.enumerated() {
            let thumb = ThumbnailView(frame: NSRect(x: 18, y: y - 44, width: 48, height: 48))
            thumb.load(urlString: img.thumb.isEmpty ? img.direct : img.thumb)
            sheet.addSubview(thumb)

            let name = NSTextField(labelWithString: img.name)
            name.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            name.lineBreakMode = .byTruncatingTail
            name.frame = NSRect(x: 78, y: y - 6, width: width - 230, height: 18)
            name.toolTip = img.direct
            sheet.addSubview(name)

            let link = NSTextField(labelWithString: img.direct)
            link.font = NSFont.systemFont(ofSize: 11)
            link.textColor = .secondaryLabelColor
            link.lineBreakMode = .byTruncatingMiddle
            link.frame = NSRect(x: 78, y: y - 26, width: width - 230, height: 15)
            sheet.addSubview(link)

            let copyBtn = smallButton("复制链接", tag: i)
            copyBtn.frame = NSRect(x: width - 132, y: y - 24, width: 64, height: 26)
            copyBtn.action = #selector(copyLink(_:))
            sheet.addSubview(copyBtn)

            let insertBtn = smallButton("插入", tag: i)
            insertBtn.frame = NSRect(x: width - 62, y: y - 24, width: 44, height: 26)
            insertBtn.action = #selector(insertImage(_:))
            insertBtn.toolTip = "在编辑区插入 ![](原图链接)"
            sheet.addSubview(insertBtn)
            y -= rowH
        }

        if failCount > 0 {
            let fail = NSTextField(labelWithString: "其中 \(failCount) 张上传失败，请重试")
            fail.font = NSFont.systemFont(ofSize: 11)
            fail.textColor = .systemRed
            fail.frame = NSRect(x: 18, y: y - 20, width: width - 36, height: 16)
            sheet.addSubview(fail)
        }

        let doneBtn = NSButton(title: "完成", target: self, action: #selector(done))
        doneBtn.bezelStyle = .rounded
        doneBtn.frame = NSRect(x: width - 90, y: 12, width: 72, height: 28)
        doneBtn.keyEquivalent = "\r"
        sheet.addSubview(doneBtn)
        return sheet
    }

    private func smallButton(_ title: String, tag: Int) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(copyLink(_:)))
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.tag = tag
        return b
    }

    private let okItems_: [PixImage]
    private func okItems() -> [PixImage] { okItems_ }

    @objc private func copyLink(_ sender: NSButton) {
        let items = okItems()
        guard sender.tag < items.count else { return }
        let img = items[sender.tag]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(img.direct, forType: .string)
        sender.title = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak sender] in
            sender?.title = "复制链接"
        }
    }

    @objc private func insertImage(_ sender: NSButton) {
        let items = okItems()
        guard sender.tag < items.count else { return }
        let img = items[sender.tag]
        onInsert("![](" + img.direct + ")")
    }

    @objc private func done() {
        if let view, let parent = view.window?.sheetParent {
            parent.endSheet(view.window!)
        }
    }
}

// MARK: - 历史图片窗口（列表 / 卡片、分页、复制、移除）

final class PixHistoryWindowController: NSWindowController, NSWindowDelegate {
    enum Mode { case list, card }

    private var items: [PixImage] = []
    private var mode: Mode = .list
    private var page = 1
    private var seg: NSSegmentedControl!
    private var prevBtn: NSButton!
    private var nextBtn: NSButton!
    private var pageLabel: NSTextField!
    private var countLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var scroll: NSScrollView!
    private var topBar: NSView!
    private var actions: [ItemActions] = []
    private var statusWork: DispatchWorkItem?

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private var pageSize: Int { mode == .list ? 20 : 12 }
    private var pageCount: Int { max(1, (items.count + pageSize - 1) / pageSize) }
    private var pageItems: [PixImage] {
        let s = (page - 1) * pageSize
        guard s < items.count else { return [] }
        return Array(items[s ..< min(s + pageSize, items.count)])
    }

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "pixhost 历史图片"
        win.minSize = NSSize(width: 560, height: 380)
        self.init(window: win)
        win.delegate = self
        build()
    }

    /// 测试用：切换显示模式
    func setModeForTesting(_ m: Mode) {
        mode = m
        seg.selectedSegment = (m == .card) ? 1 : 0
        page = 1
        rebuild()
    }

    /// 打开并刷新数据
    func showWindowAndReload() {
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reload() {
        items = PixHistory.load()
        page = 1
        rebuild()
    }

    // MARK: - 界面

    private func build() {
        guard let content = window?.contentView else { return }
        let W = content.bounds.width
        let H = content.bounds.height

        // 顶栏
        let top = NSView(frame: NSRect(x: 0, y: H - 44, width: W, height: 44))
        top.autoresizingMask = [.width, .minYMargin]
        topBar = top

        countLabel = NSTextField(labelWithString: "")
        countLabel.font = NSFont.systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        countLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        top.addSubview(countLabel)

        seg = NSSegmentedControl(labels: ["列表", "卡片"],
                                 trackingMode: .selectOne,
                                 target: self, action: #selector(modeChanged(_:)))
        seg.selectedSegment = 0
        seg.autoresizingMask = [.minXMargin, .minYMargin]
        top.addSubview(seg)

        prevBtn = iconButton("chevron.left", action: #selector(prevPage), tooltip: "上一页")
        nextBtn = iconButton("chevron.right", action: #selector(nextPage), tooltip: "下一页")
        pageLabel = NSTextField(labelWithString: "")
        pageLabel.font = NSFont.systemFont(ofSize: 12)
        pageLabel.alignment = .center
        for v in [prevBtn, nextBtn, pageLabel] { v?.autoresizingMask = [.minXMargin, .minYMargin] }
        top.addSubview(pageLabel)
        top.addSubview(prevBtn)
        top.addSubview(nextBtn)
        content.addSubview(top)
        layoutTopBar(top: top, width: W)

        // 底部状态栏
        let bottom = NSView(frame: NSRect(x: 0, y: 0, width: W, height: 28))
        bottom.autoresizingMask = [.width]
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        bottom.addSubview(statusLabel)
        content.addSubview(bottom)

        // 内容滚动区
        scroll = NSScrollView(frame: NSRect(x: 0, y: 28, width: W, height: H - 44 - 28))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        content.addSubview(scroll)
    }

    private func layoutTopBar(top: NSView, width W: CGFloat) {
        let cy: CGFloat = 10
        countLabel.frame = NSRect(x: 14, y: cy, width: 160, height: 24)
        nextBtn.frame = NSRect(x: W - 42, y: cy - 2, width: 30, height: 30)
        prevBtn.frame = NSRect(x: W - 158, y: cy - 2, width: 30, height: 30)
        pageLabel.frame = NSRect(x: W - 124, y: cy + 2, width: 62, height: 20)
        seg.frame = NSRect(x: W - 292, y: cy, width: 120, height: 24)
    }

    func windowDidResize(_ notification: Notification) {
        layoutTopBar(top: topBar, width: topBar.bounds.width)
        rebuild()
    }

    private func iconButton(_ symbol: String, action: Selector, tooltip: String) -> NSButton {
        let b = NSButton()
        b.bezelStyle = .rounded
        b.imagePosition = .imageOnly
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            b.image = img
        } else {
            b.title = symbol
            b.imagePosition = .noImage
        }
        b.target = self
        b.action = action
        b.toolTip = tooltip
        return b
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        mode = sender.selectedSegment == 1 ? .card : .list
        page = 1
        rebuild()
    }

    @objc private func prevPage() {
        page = max(1, page - 1)
        rebuild()
    }

    @objc private func nextPage() {
        page = min(pageCount, page + 1)
        rebuild()
    }

    // MARK: - 内容重建

    private func rebuild() {
        page = min(max(1, page), pageCount)
        countLabel.stringValue = items.isEmpty ? "暂无历史图片" : "共 \(items.count) 张"
        pageLabel.stringValue = "第 \(page) / \(pageCount) 页"
        prevBtn.isEnabled = page > 1
        nextBtn.isEnabled = page < pageCount
        actions = []
        let w = max(scroll.contentSize.width, 320)
        let h = max(scroll.contentSize.height, 200)
        scroll.documentView = (mode == .list) ? makeListDoc(width: w, viewportH: h) : makeCardDoc(width: w, viewportH: h)
    }

    private func emptyDoc(width: CGFloat, height: CGFloat) -> NSView {
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: max(height, 10)))
        let label = NSTextField(labelWithString: "这一页没有图片")
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 30, width: width, height: 24)
        doc.addSubview(label)
        return doc
    }

    private func makeListDoc(width: CGFloat, viewportH: CGFloat) -> NSView {
        let rows = pageItems
        let rowH: CGFloat = 72
        guard !rows.isEmpty else { return emptyDoc(width: width, height: viewportH) }
        let h = max(CGFloat(rows.count) * rowH + 8, viewportH)
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: h))
        for (i, item) in rows.enumerated() {
            doc.addSubview(makeRow(item, y: CGFloat(i) * rowH + 4, width: width))
        }
        return doc
    }

    private func makeRow(_ item: PixImage, y: CGFloat, width: CGFloat) -> NSView {
        let rowH: CGFloat = 72
        let row = NSView(frame: NSRect(x: 0, y: y, width: width, height: rowH))

        let thumb = ThumbnailView(frame: NSRect(x: 10, y: 8, width: 56, height: 56))
        thumb.load(urlString: item.thumb.isEmpty ? item.direct : item.thumb)
        row.addSubview(thumb)

        let name = NSTextField(labelWithString: item.name)
        name.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: 80, y: rowH - 26, width: width - 240, height: 18)
        name.toolTip = item.direct
        row.addSubview(name)

        let meta = NSTextField(labelWithString: Self.dateFmt.string(from: item.date)
            + (item.size.map { " · \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" } ?? ""))
        meta.font = NSFont.systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.frame = NSRect(x: 80, y: rowH - 44, width: width - 240, height: 14)
        row.addSubview(meta)

        let link = NSTextField(labelWithString: item.direct)
        link.font = NSFont.systemFont(ofSize: 10.5)
        link.textColor = .tertiaryLabelColor
        link.lineBreakMode = .byTruncatingMiddle
        link.frame = NSRect(x: 80, y: rowH - 60, width: width - 240, height: 13)
        row.addSubview(link)

        let act = ItemActions(item: item,
                              onCopy: { [weak self] in self?.copyLink(item) },
                              onRemove: { [weak self] in self?.confirmRemove(item) })
        actions.append(act)
        let copyB = iconButton("doc.on.doc", action: #selector(ItemActions.copyLink), tooltip: "复制原图链接")
        copyB.target = act
        copyB.frame = NSRect(x: width - 84, y: 21, width: 34, height: 30)
        row.addSubview(copyB)
        let delB = iconButton("trash", action: #selector(ItemActions.remove), tooltip: "移除")
        delB.target = act
        delB.frame = NSRect(x: width - 46, y: 21, width: 34, height: 30)
        row.addSubview(delB)
        return row
    }

    private func makeCardDoc(width: CGFloat, viewportH: CGFloat) -> NSView {
        let rows_ = pageItems
        let cardW: CGFloat = 168, cardH: CGFloat = 218, spacing: CGFloat = 12
        guard !rows_.isEmpty else { return emptyDoc(width: width, height: viewportH) }
        let cols = max(1, Int((width - 16 + spacing) / (cardW + spacing)))
        let usable = CGFloat(cols) * cardW + CGFloat(cols - 1) * spacing
        let offX = max((width - usable) / 2, 8)
        let rowCount = (rows_.count + cols - 1) / cols
        let h = max(CGFloat(rowCount) * cardH + CGFloat(rowCount - 1) * spacing + 16, viewportH)
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: h))
        for (i, item) in rows_.enumerated() {
            let r = i / cols
            let c = i % cols
            let x = offX + CGFloat(c) * (cardW + spacing)
            let y = 8 + CGFloat(r) * (cardH + spacing)
            doc.addSubview(makeCard(item, frame: NSRect(x: x, y: y, width: cardW, height: cardH)))
        }
        return doc
    }

    private func makeCard(_ item: PixImage, frame: NSRect) -> NSView {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 8
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.borderWidth = 1

        let thumb = ThumbnailView(frame: NSRect(x: 10, y: frame.height - 130,
                                                width: frame.width - 20, height: 120))
        thumb.load(urlString: item.thumb.isEmpty ? item.direct : item.thumb)
        card.addSubview(thumb)

        let name = NSTextField(labelWithString: item.name)
        name.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: 10, y: frame.height - 152, width: frame.width - 20, height: 16)
        name.toolTip = item.direct
        card.addSubview(name)

        let meta = NSTextField(labelWithString: Self.dateFmt.string(from: item.date))
        meta.font = NSFont.systemFont(ofSize: 10.5)
        meta.textColor = .secondaryLabelColor
        meta.frame = NSRect(x: 10, y: frame.height - 170, width: frame.width - 20, height: 13)
        card.addSubview(meta)

        let act = ItemActions(item: item,
                              onCopy: { [weak self] in self?.copyLink(item) },
                              onRemove: { [weak self] in self?.confirmRemove(item) },
                              onOpen: { [weak self] in self?.openShow(item) })
        actions.append(act)
        let copyB = iconButton("doc.on.doc", action: #selector(ItemActions.copyLink), tooltip: "复制原图链接")
        copyB.target = act
        copyB.frame = NSRect(x: 12, y: 10, width: 34, height: 30)
        card.addSubview(copyB)
        let delB = iconButton("trash", action: #selector(ItemActions.remove), tooltip: "移除")
        delB.target = act
        delB.frame = NSRect(x: 52, y: 10, width: 34, height: 30)
        card.addSubview(delB)
        let openB = iconButton("arrow.up.right.square", action: #selector(ItemActions.openShow), tooltip: "打开展示页")
        openB.target = act
        openB.frame = NSRect(x: frame.width - 46, y: 10, width: 34, height: 30)
        card.addSubview(openB)
        return card
    }

    // MARK: - 操作

    private func copyLink(_ item: PixImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.direct, forType: .string)
        flash("已复制原图链接")
    }

    private func openShow(_ item: PixImage) {
        if let url = URL(string: item.show) {
            NSWorkspace.shared.open(url)
        }
    }

    private func confirmRemove(_ item: PixImage) {
        let alert = NSAlert()
        alert.messageText = "移除这张图片？"
        alert.informativeText = "「\(item.name)」\n\n• 移除并删除远端：从历史列表移除，并调用 pixhost 接口删除服务器上的图片（链接将失效）\n• 仅移出列表：只从本地历史移除，图片仍保留在 pixhost 上"
        alert.addButton(withTitle: "移除并删除远端")
        alert.addButton(withTitle: "仅移出列表")
        alert.addButton(withTitle: "取消")
        let resp = alert.runModal()
        switch resp {
        case .alertFirstButtonReturn:
            PixHistory.remove(item)
            reload()
            flash("正在从 pixhost 删除…")
            PixhostAPI.delete(item) { [weak self] ok in
                self?.flash(ok ? "已移除，并已从 pixhost 删除" : "已移除（远端删除失败，图片可能已不存在）")
            }
        case .alertSecondButtonReturn:
            PixHistory.remove(item)
            reload()
            flash("已移出列表（远端图片保留）")
        default:
            break
        }
    }

    private func flash(_ text: String) {
        statusLabel.stringValue = text
        statusWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.statusLabel.stringValue = "" }
        statusWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }
}
