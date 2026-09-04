import AppKit
import Carbon.HIToolbox
import CoreServices
import UniformTypeIdentifiers

// MARK: - 全局快捷键 (⌥⌘M)

private func notesMDHotKeyHandler(_ next: EventHandlerCallRef?,
                                  _ event: EventRef?,
                                  _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async {
        (NSApp.delegate as? AppDelegate)?.toggleWindow()
    }
    return noErr
}

enum Hotkey {
    private static var hotKeyRef: EventHotKeyRef?

    static func register() {
        var hotKeyID = EventHotKeyID(signature: 0x4E4D444D, id: 1) // "NMDM"
        _ = InstallEventHandler(GetEventDispatcherTarget(),
                                notesMDHotKeyHandler, 1,
                                [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))], nil, nil)
        _ = RegisterEventHotKey(UInt32(kVK_ANSI_M),
                                UInt32(optionKey | cmdKey),
                                hotKeyID,
                                GetEventDispatcherTarget(), 0, &hotKeyRef)
    }
}

// MARK: - 示例内容

enum Sample {
    static let markdown = """
    # 快速上手 NotesMD

    在左侧用 **Markdown** 写作，右侧即时预览排版效果。

    ## 支持的语法
    - **加粗**、*斜体*、~~删除线~~、`行内代码`
    - [链接](https://developer.apple.com)
    - 行首加 > 就是引用

    > 这是一段引用文字。

    1. 有序列表
    2. 自动编号

    ## 代码块
    ```swift
    func hello() -> String { "你好" }
    ```

    ## 三种用法
    1. 新建备忘录并粘贴：生成一条原生排版的备忘录，富文本同时进剪贴板
    2. 复制为富文本：自行选择粘贴位置
    3. 右上角「自动保存」：打开文件后停顿 0.6 秒自动保存

    ---
    全局快捷键：⌥⌘M 打开 / 隐藏窗口
    """
}

// MARK: - 编辑区文本视图（粘贴图片/图床链接时自动转 ![](链接)）

final class EditorTextView: NSTextView {
    /// 粘贴图片时的保存回调，返回写进 markdown 的路径；nil 则按普通粘贴处理
    var onPasteImage: ((NSImage) -> String?)?

    override func paste(_ sender: Any?) {
        guard onPasteImage != nil else {
            super.paste(sender); return
        }
        let pb = NSPasteboard.general
        // 1) 剪贴板带图床 URL（浏览器复制图片链接/URL 文本）
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first,
           let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
            insertText("![](" + url.absoluteString + ")", replacementRange: selectedRange())
            return
        }
        // 2) 剪贴板是图片：存到本地图床，写入本地路径
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first,
           let path = onPasteImage?(image) {
            insertText("![](" + path + ")", replacementRange: selectedRange())
            return
        }
        super.paste(sender)
    }
}

// MARK: - 背景图视图

/// 预览背景图：等比放大铺满（aspect fill），不透明度可调；
/// 位于预览分栏内部，不影响窗口大小与比例
final class BackgroundImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var imageAlpha: CGFloat = 1 { didSet { needsDisplay = true } }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 无背景图时铺文本底色（与 NSTextView 默认背景一致，观感不变）
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let image, bounds.width > 0, bounds.height > 0 else { return }
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }
        let scale = max(bounds.width / imgSize.width, bounds.height / imgSize.height)
        let w = imgSize.width * scale
        let h = imgSize.height * scale
        let rect = NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: imageAlpha,
                   respectFlipped: false, hints: [NSImageRep.HintKey.interpolation: NSImageInterpolation.high.rawValue])
    }
}
// MARK: - 主窗口

final class EditorWindowController: NSWindowController, NSTextViewDelegate, NSWindowDelegate {
    fileprivate var editorTextView: NSTextView!
    fileprivate var previewTextView: NSTextView!
    fileprivate var splitView: NSSplitView!
    private var titleField: NSTextField!
    private var statusLabel: NSTextField!
    private var updateWorkItem: DispatchWorkItem?
    private var statusClearWork: DispatchWorkItem?
    private var fileURL: URL?
    private var isDirty = false
    private var isProgrammaticChange = false

    private var windowBackground: BackgroundImageView!
    private var opacitySlider: NSSlider!
    private var bgClearButton: NSButton!
    private var backgroundURL: URL?
    private var backgroundOpacity: CGFloat = 1
    private var autoSaveSwitch: NSSwitch!
    private var autoSaveEnabled = false
    private var autoSaveWork: DispatchWorkItem?
    private var hasPushedToNotes = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "NotesMD - Markdown 备忘录"
        window.minSize = NSSize(width: 640, height: 400)
        window.center()
        self.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        buildViews()
        window.makeFirstResponder(editorTextView)
        updateTitle()
    }

    private func buildViews() {
        guard let content = window?.contentView else { return }

        autoSaveEnabled = UserDefaults.standard.bool(forKey: Self.defaultKeyAutoSave)

        // 窗口级背景图：先加入即位于最底层，覆盖编辑区与预览区；不改动窗口 frame，
        // 因此添加背景图不会改变窗口大小与比例
        windowBackground = BackgroundImageView()
        windowBackground.autoresizingMask = [.width, .height]
        windowBackground.frame = content.bounds
        content.addSubview(windowBackground)

        // 底部操作栏
        let bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: content.bounds.width, height: 48))
        bottomBar.autoresizingMask = [.width]

        let newButton = makeButton("新建", action: #selector(newDocument))
        let openFileButton = makeButton("打开", action: #selector(openDocument))
        let saveButton = makeButton("保存", action: #selector(saveDocumentAction))
        let noteButton = makeButton("新建备忘录并粘贴", action: #selector(createNoteAndPaste))
        noteButton.keyEquivalent = "r"
        let copyButton = makeButton("复制为富文本", action: #selector(copyRich))
        copyButton.keyEquivalent = "c"
        copyButton.keyEquivalentModifierMask = [.command, .shift]

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let bar = NSStackView(views: [newButton, openFileButton, saveButton, noteButton, copyButton, statusLabel])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 14),
            bar.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -14),
            bar.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor)
        ])
        content.addSubview(bottomBar)

        // 顶行：标题输入
        let topBar = NSView(frame: NSRect(x: 0, y: content.bounds.height - 36,
                                          width: content.bounds.width, height: 36))
        topBar.autoresizingMask = [.width, .minYMargin]
        let titleHint = NSTextField(labelWithString: "标题")
        titleHint.font = NSFont.systemFont(ofSize: 12)
        titleHint.textColor = .secondaryLabelColor
        titleField = NSTextField(string: "")
        titleField.placeholderString = "留空则自动从正文提取"
        titleField.font = NSFont.systemFont(ofSize: 13)
        titleField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        titleField.autoresizingMask = []
        topBar.addSubview(titleHint)
        topBar.addSubview(titleField)
        titleHint.translatesAutoresizingMaskIntoConstraints = false
        titleField.translatesAutoresizingMaskIntoConstraints = false
        let titleWidth = titleField.widthAnchor.constraint(equalToConstant: 320)
        titleWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            titleHint.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 14),
            titleHint.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: titleHint.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleWidth,
            titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        // 顶栏右侧：自动保存 + 背景图片 + 透明度
        let autoSaveHint = NSTextField(labelWithString: "自动保存")
        autoSaveHint.font = NSFont.systemFont(ofSize: 11)
        autoSaveHint.textColor = .secondaryLabelColor
        autoSaveSwitch = NSSwitch()
        autoSaveSwitch.state = autoSaveEnabled ? .on : .off
        autoSaveSwitch.target = self
        autoSaveSwitch.action = #selector(toggleAutoSave(_:))
        autoSaveSwitch.toolTip = "开启后：打开文件时，停顿 0.6 秒自动保存该文件"
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let bgButton = makeButton("背景图片…", action: #selector(pickBackgroundImage))
        bgButton.controlSize = .small
        bgClearButton = makeButton("清除背景", action: #selector(clearBackgroundImage))
        bgClearButton.controlSize = .small
        let opacityHint = NSTextField(labelWithString: "透明度")
        opacityHint.font = NSFont.systemFont(ofSize: 11)
        opacityHint.textColor = .secondaryLabelColor
        opacitySlider = NSSlider(value: 100, minValue: 0, maxValue: 100,
                                 target: self, action: #selector(opacitySliderChanged(_:)))
        opacitySlider.controlSize = .small
        opacitySlider.toolTip = "背景图片不透明度"
        let rightStack = NSStackView(views: [autoSaveHint, autoSaveSwitch, sep, opacityHint, opacitySlider, bgButton, bgClearButton])
        rightStack.orientation = .horizontal
        rightStack.spacing = 8
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(rightStack)
        opacitySlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        NSLayoutConstraint.activate([
            rightStack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -14),
            rightStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor)
        ])
        content.addSubview(topBar)

        // 中间：左编辑 右预览
        let split = NSSplitView(frame: NSRect(x: 0, y: 48,
                                              width: content.bounds.width,
                                              height: content.bounds.height - 48 - 36))
        split.autoresizingMask = [.width, .height]
        split.isVertical = true
        split.dividerStyle = .thin
        splitView = split

        let editorScroll = makeScroll()
        editorTextView = makeTextView(forEditor: true)
        editorTextView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        editorTextView.delegate = self
        editorTextView.drawsBackground = false
        editorScroll.documentView = editorTextView

        let previewScroll = makeScroll()
        previewTextView = makeTextView()
        previewTextView.isEditable = false
        previewTextView.isSelectable = true
        previewTextView.drawsBackground = false
        previewScroll.documentView = previewTextView

        split.addArrangedSubview(editorScroll)
        split.addArrangedSubview(previewScroll)
        content.addSubview(split)
        DispatchQueue.main.async { [weak split] in
            guard let split, split.subviews.count >= 2 else { return }
            split.setPosition(split.bounds.width * 0.46, ofDividerAt: 0)
        }

        refreshPreview()
        restoreBackground()
        updateBackgroundControls()
    }

    private func makeScroll() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    private func makeTextView(forEditor editor: Bool = false) -> NSTextView {
        let tv: NSTextView = editor ? EditorTextView() : NSTextView()
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 6, height: 12)
        if editor, let ev = tv as? EditorTextView {
            ev.onPasteImage = { image in MediaStore.save(image) }
        }
        return tv
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        return b
    }

    // MARK: - 预览

    func textDidChange(_ notification: Notification) {
        if !isProgrammaticChange {
            isDirty = true
            hasPushedToNotes = false
            updateTitle()
        }
        updateWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshPreview() }
        updateWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)

        // 自动保存：文件已打开且停止输入 0.6 秒后静默保存
        if autoSaveEnabled {
            autoSaveWork?.cancel()
            let saveWork = DispatchWorkItem { [weak self] in
                guard let self, self.autoSaveEnabled, self.isDirty, let url = self.fileURL else { return }
                _ = self.save(to: url)
            }
            autoSaveWork = saveWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: saveWork)
        }
    }

    @objc func toggleAutoSave(_ sender: NSSwitch) {
        autoSaveEnabled = sender.state == .on
        UserDefaults.standard.set(autoSaveEnabled, forKey: Self.defaultKeyAutoSave)
        if !autoSaveEnabled {
            autoSaveWork?.cancel()
        }
    }

    private func refreshPreview() {
        // 窗口未布局完成时兜底 320，避免首帧表格被过度压缩
        let width = max(previewTextView.bounds.width - 24, 320)
        previewTextView.textStorage?.setAttributedString(
            MarkdownRenderer.render(editorTextView.string, contentWidth: width) { [weak self] in
                // 图床图片下载完成：重渲染（命中缓存，不再下载）
                self?.refreshPreview()
            })
        previewTextView.scrollToBeginningOfDocument(nil)
    }

    // MARK: - 文件操作

    private static let markdownTypes: [UTType] = {
        var types: [UTType] = []
        for ext in ["md", "markdown", "mdown"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        if types.isEmpty { types.append(UTType.plainText) }
        return types
    }()

    func updateTitle() {
        window?.isDocumentEdited = isDirty
        window?.title = fileURL.map { "NotesMD - \($0.lastPathComponent)" } ?? "NotesMD"
    }

    @objc func newDocument() {
        guard confirmDiscardIfDirty() else { return }
        fileURL = nil
        isDirty = false
        hasPushedToNotes = false
        isProgrammaticChange = true
        titleField.stringValue = ""
        editorTextView.string = ""
        isProgrammaticChange = false
        refreshPreview()
        updateTitle()
    }

    @objc func openDocument() {
        let panel = NSOpenPanel()
        panel.title = "打开 Markdown 文件"
        panel.allowedContentTypes = Self.markdownTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadFile(url)
    }

    func loadFile(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            setStatus("无法读取文件：\(url.lastPathComponent)")
            return
        }
        fileURL = url
        isDirty = false
        hasPushedToNotes = false
        isProgrammaticChange = true
        titleField.stringValue = ""
        editorTextView.string = text
        isProgrammaticChange = false
        refreshPreview()
        updateTitle()
        setStatus("已打开 \(url.lastPathComponent)")
    }

    func saveDocument() -> Bool {
        if let url = fileURL { return save(to: url) }
        return saveDocumentAs()
    }

    @objc func saveDocumentAction() { _ = saveDocument() }

    func saveDocumentAs() -> Bool {
        let panel = NSSavePanel()
        panel.title = "保存 Markdown 文件"
        panel.allowedContentTypes = Self.markdownTypes
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "未命名.md"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        fileURL = url
        return save(to: url)
    }

    private func save(to url: URL) -> Bool {
        do {
            try editorTextView.string.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            updateTitle()
            setStatus("已保存 \(url.lastPathComponent)")
            return true
        } catch {
            setStatus("保存失败：\(error.localizedDescription)")
            return false
        }
    }

    private func confirmDiscardIfDirty() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "有未保存的更改"
        alert.informativeText = "要离开当前文件吗？未保存的更改将丢失。"
        alert.addButton(withTitle: "放弃更改")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let hasContent = !editorTextView.string
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasContent && (isDirty || !hasPushedToNotes) else { return true }

        var pending: [String] = []
        if isDirty { pending.append("尚未保存为 Markdown 文件") }
        if !hasPushedToNotes { pending.append("尚未新建备忘录并粘贴") }
        let alert = NSAlert()
        alert.messageText = "内容还没有处理完"
        alert.informativeText = "当前：" + pending.joined(separator: "；") + "。\n请选择关闭前如何处理："
        alert.addButton(withTitle: fileURL == nil ? "另存为并关闭" : "保存并关闭")
        alert.addButton(withTitle: "新建备忘录并粘贴，然后关闭")
        alert.addButton(withTitle: "不处理直接关闭")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveDocument()
        case .alertSecondButtonReturn:
            return pushNowToNotes()
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: - 操作

    /// 推送/剪贴板用的 markdown：确保首个非空行是最终标题 H1。
    /// 备忘录会把正文首行渲染为加粗大标题并用作笔记名，正文保留该 H1 即可：
    /// 主标题加粗、不重复
    fileprivate var noteTitleMarkdown: String {
        let explicit = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return MarkdownRenderer.noteMarkdown(editorTextView.string, explicitTitle: explicit)
    }

    /// 新建备忘录并粘贴：AppleScript 创建带完整内容的备忘录（首行为加粗标题），
    /// 同时把富文本复制进剪贴板，方便再 ⌘V 到其他笔记
    @objc func createNoteAndPaste() {
        NotesService.copyRich(markdown: noteTitleMarkdown)
        let md = noteTitleMarkdown
        let html = MarkdownRenderer.html(from: md)
        let title = MarkdownRenderer.deriveTitle(from: md) ?? "未命名备忘录"
        setStatus("正在写入备忘录…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NotesService.createNote(html: html)
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.hasPushedToNotes = true
                    self.setStatus("已创建备忘录「\(title)」，富文本也已复制到剪贴板")
                case .failure(let error):
                    self.setStatus("创建失败：\(error.localizedDescription)（富文本已在剪贴板，可手动 ⌘V）")
                }
            }
        }
    }

    /// 同步写入备忘录（关闭确认弹窗用；osascript 约 1 秒）
    @discardableResult
    private func pushNowToNotes() -> Bool {
        let result = NotesService.createNote(html: MarkdownRenderer.html(from: noteTitleMarkdown))
        if case .success = result {
            hasPushedToNotes = true
            return true
        }
        if case .failure(let error) = result {
            setStatus("创建失败：\(error.localizedDescription)")
        }
        return false
    }

    @objc func copyRich() {
        NotesService.copyRich(markdown: noteTitleMarkdown)
        setStatus("已复制富文本，到备忘录中按 ⌘V 粘贴")
    }

    // MARK: - 背景图片

    private static let defaultKeyAutoSave = "notesmd.autosave"
    private static let defaultKeyBgURL = "notesmd.backgroundURL"
    private static let defaultKeyBgAlpha = "notesmd.backgroundOpacity"

    @objc func pickBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = "选择预览背景图片"
        panel.allowedContentTypes = [UTType.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }
        backgroundURL = url
        windowBackground.image = image
        windowBackground.imageAlpha = backgroundOpacity
        updateBackgroundControls()
        persistBackground()
    }

    @objc func clearBackgroundImage() {
        backgroundURL = nil
        backgroundOpacity = 1
        windowBackground.image = nil
        opacitySlider.doubleValue = 100
        updateBackgroundControls()
        persistBackground()
    }

    @objc func opacitySliderChanged(_ sender: NSSlider) {
        backgroundOpacity = sender.doubleValue / 100
        windowBackground.imageAlpha = backgroundOpacity
        persistBackground()
    }

    private func updateBackgroundControls() {
        let has = windowBackground.image != nil
        opacitySlider.isEnabled = has
        bgClearButton.isEnabled = has
    }

    private func persistBackground() {
        let d = UserDefaults.standard
        if let url = backgroundURL {
            d.set(url.path, forKey: Self.defaultKeyBgURL)
        } else {
            d.removeObject(forKey: Self.defaultKeyBgURL)
        }
        d.set(backgroundOpacity, forKey: Self.defaultKeyBgAlpha)
    }

    private func restoreBackground() {
        let d = UserDefaults.standard
        backgroundOpacity = (d.object(forKey: Self.defaultKeyBgAlpha) as? CGFloat) ?? 1
        opacitySlider.doubleValue = backgroundOpacity * 100
        if let path = d.string(forKey: Self.defaultKeyBgURL),
           let image = NSImage(contentsOfFile: path) {
            backgroundURL = URL(fileURLWithPath: path)
            windowBackground.image = image
            windowBackground.imageAlpha = backgroundOpacity
        }
    }

    var isDirtyForTest: Bool { isDirty }

    func setAutoSaveForTesting(_ on: Bool) {
        autoSaveEnabled = on
        autoSaveSwitch.state = on ? .on : .off
    }

    func simulateUserEdit(append text: String) {
        isProgrammaticChange = true
        editorTextView.string = editorTextView.string + text
        isProgrammaticChange = false
        textDidChange(Notification(name: NSText.didChangeNotification, object: editorTextView))
    }
    var filePathForTest: String? { fileURL?.path }

    func setTextForTesting(_ s: String) {
        isProgrammaticChange = true
        editorTextView.string = s
        isProgrammaticChange = false
        refreshPreview()
    }

    func setBackgroundForTesting(url: URL, alpha: CGFloat) {
        guard let image = NSImage(contentsOf: url) else { return }
        backgroundURL = url
        backgroundOpacity = alpha
        windowBackground.image = image
        windowBackground.imageAlpha = alpha
        opacitySlider.doubleValue = alpha * 100
        updateBackgroundControls()
    }

    private func setStatus(_ text: String) {
        statusClearWork?.cancel()
        statusLabel.stringValue = text
        let work = DispatchWorkItem { [weak self] in self?.statusLabel?.stringValue = "" }
        statusClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var editor: EditorWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        setupStatusItem()
        buildMainMenu()
        Hotkey.register()
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        showWindow()
        if let first = urls.first { editor?.loadFile(first) }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "NotesMD")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
        }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "显示 / 隐藏编辑器  (⌥⌘M)", action: #selector(toggleWindow), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        for item in [
            NSMenuItem(title: "打开文件…  (⌘O)", action: #selector(editorOpenDocument), keyEquivalent: ""),
            NSMenuItem(title: "保存  (⌘S)", action: #selector(editorSaveDocument), keyEquivalent: "")
        ] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for item in [
            NSMenuItem(title: "新建备忘录并粘贴", action: #selector(editorCreateNoteAndPaste), keyEquivalent: ""),
            NSMenuItem(title: "复制为富文本", action: #selector(editorCopyRich), keyEquivalent: ""),
            NSMenuItem(title: "背景图片…", action: #selector(editorPickBackground), keyEquivalent: ""),
            NSMenuItem(title: "清除背景图片", action: #selector(editorClearBackground), keyEquivalent: "")
        ] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let defaultApp = NSMenuItem(title: "设为 .md 默认打开程序", action: #selector(setDefaultMarkdownApp), keyEquivalent: "")
        defaultApp.target = self
        menu.addItem(defaultApp)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 NotesMD", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "关于 NotesMD", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 NotesMD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenuItem.submenu = fileMenu
        let newDoc = NSMenuItem(title: "新建", action: #selector(editorNewDocument), keyEquivalent: "n")
        newDoc.target = self
        fileMenu.addItem(newDoc)
        let openDoc = NSMenuItem(title: "打开…", action: #selector(editorOpenDocument), keyEquivalent: "o")
        openDoc.target = self
        fileMenu.addItem(openDoc)
        let saveDoc = NSMenuItem(title: "保存", action: #selector(editorSaveDocument), keyEquivalent: "s")
        saveDoc.target = self
        fileMenu.addItem(saveDoc)
        let saveAs = NSMenuItem(title: "另存为…", action: #selector(editorSaveDocumentAs), keyEquivalent: "S")
        saveAs.target = self
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAs)
        fileMenu.addItem(.separator())
        let defaultApp = NSMenuItem(title: "设为 .md 默认打开程序", action: #selector(setDefaultMarkdownApp), keyEquivalent: "")
        defaultApp.target = self
        fileMenu.addItem(defaultApp)
        fileMenu.addItem(.separator())
        let noteItem = NSMenuItem(title: "新建备忘录并粘贴", action: #selector(editorCreateNoteAndPaste), keyEquivalent: "r")
        noteItem.target = self
        fileMenu.addItem(noteItem)
        let copyItem = NSMenuItem(title: "复制为富文本", action: #selector(editorCopyRich), keyEquivalent: "C")
        copyItem.target = self
        copyItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(copyItem)

        let bgItem = NSMenuItem(title: "背景图片…", action: #selector(editorPickBackground), keyEquivalent: "")
        bgItem.target = self
        fileMenu.addItem(bgItem)
        let bgClearItem = NSMenuItem(title: "清除背景图片", action: #selector(editorClearBackground), keyEquivalent: "")
        bgClearItem.target = self
        fileMenu.addItem(bgClearItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - 窗口管理

    func showWindow() {
        if editor == nil {
            editor = EditorWindowController()
        }
        editor?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleWindow() {
        if let window = editor?.window, window.isVisible {
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    // MARK: - 菜单动作（转发到编辑器）

    @objc func editorNewDocument() { editor?.newDocument() }
    @objc func editorOpenDocument() { editor?.openDocument() }
    @objc func editorSaveDocument() { _ = editor?.saveDocument() }
    @objc func editorSaveDocumentAs() { _ = editor?.saveDocumentAs() }
    @objc func editorCreateNoteAndPaste() { editor?.createNoteAndPaste() }

    @objc func setDefaultMarkdownApp() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        // kLSRolesAll = kLSRoleViewer | kLSRoleEditor | kLSRoleShell = 7
        let status = LSSetDefaultRoleHandlerForContentType("net.daringfireball.markdown" as CFString,
                                                           LSRolesMask(rawValue: 7),
                                                           bundleID as CFString)
        let alert = NSAlert()
        if status == noErr {
            alert.messageText = "已设置"
            alert.informativeText = "NotesMD 已设为 .md 文件的默认打开程序。"
            alert.addButton(withTitle: "好")
        } else {
            alert.messageText = "设置失败"
            alert.informativeText = "你也可以在 Finder 中右键 .md 文件 → 显示简介 → 打开方式选择 NotesMD → 点「全部更改」。"
            alert.addButton(withTitle: "好")
        }
        alert.runModal()
    }
    @objc func editorCopyRich() { editor?.copyRich() }
    @objc func editorPickBackground() { editor?.pickBackgroundImage() }
    @objc func editorClearBackground() { editor?.clearBackgroundImage() }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - CLI（便于脚本与验证）
//   NotesMD --html <file>       输出该 markdown 文件的 HTML
//   NotesMD --png <file> [out]  把该 markdown 文件渲染为 PNG（out 可省略）
//   NotesMD --layout            打印窗口布局后退出
//   NotesMD --paste-md <file>   复制该文件内容为富文本并 ⌘V 到备忘录（测试用）
//   NotesMD --screenshot <file> <out.png> [bg.png] [alpha]  截图窗口（测试用）

func runCLI() -> Bool {
    let args = CommandLine.arguments
    if args.contains("--smoke") {
        let md = MarkdownRenderer.noteMarkdown(Sample.markdown, explicitTitle: "")
        let title = MarkdownRenderer.deriveTitle(from: md) ?? "smoke"
        print("title=", title)
        let html = MarkdownRenderer.html(from: md)
        let attr = MarkdownRenderer.render(Sample.markdown)
        print("render length=", attr.length)
        let r = NotesService.createNote(html: html)
        switch r {
        case .success: print("createNote=OK")
        case .failure(let e): print("createNote=ERR", e.localizedDescription)
        }
        return true
    }
    if let idx = args.firstIndex(of: "--paste-md"), idx + 1 < args.count {
        let md = (try? String(contentsOfFile: args[idx + 1], encoding: .utf8)) ?? ""
        let app2 = NSApplication.shared
        app2.setActivationPolicy(.accessory)
        let wc = EditorWindowController()
        wc.window?.makeKeyAndOrderFront(nil)
        wc.setTextForTesting(md)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotesService.copyRich(markdown: wc.noteTitleMarkdown)
            NotesService.pasteIntoNotes()
        }
        Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
            NSApp.terminate(nil)
        }
        app2.run()
        return true
    }
    if let idx = args.firstIndex(of: "--screenshot"), idx + 1 < args.count {
        let md = (try? String(contentsOfFile: args[idx + 1], encoding: .utf8)) ?? ""
        let outPath = (idx + 2 < args.count) ? args[idx + 2] : "/tmp/nmd-test/shot.png"
        var bgURL: URL?
        var bgAlpha: CGFloat = 1
        var pasteImgPath: String?
        if idx + 4 < args.count {
            bgURL = URL(fileURLWithPath: args[idx + 3])
            bgAlpha = (Double(args[idx + 4]) ?? 1)
        }
        if idx + 5 < args.count {
            pasteImgPath = args[idx + 5]
        }
        let app2 = NSApplication.shared
        app2.setActivationPolicy(.accessory)
        let wc = EditorWindowController()
        wc.window?.makeKeyAndOrderFront(nil)
        wc.setTextForTesting(md)
        if let bgURL {
            wc.setBackgroundForTesting(url: bgURL, alpha: bgAlpha)
        }
        if let pasteImgPath, let image = NSImage(contentsOfFile: pasteImgPath) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
            DispatchQueue.main.async {
                wc.editorTextView.window?.makeFirstResponder(wc.editorTextView)
                wc.editorTextView.setSelectedRange(NSRange(location: wc.editorTextView.string.count, length: 0))
                wc.editorTextView.paste(nil)
            }
        }
        let waitSec = ProcessInfo.processInfo.environment["NMD_SHOT_WAIT"].flatMap(Double.init) ?? 5
        Timer.scheduledTimer(withTimeInterval: waitSec, repeats: false) { _ in
            guard let content = wc.window?.contentView else {
                NSApp.terminate(nil); return
            }
            content.displayIfNeeded()
            if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    do {
                        try png.write(to: URL(fileURLWithPath: outPath))
                    } catch {
                        FileHandle.standardError.write(Data("截图失败：\(error)\n".utf8))
                    }
                }
            }
            NSApp.terminate(nil)
        }
        app2.run()
        return true
    }
    if let idx = args.firstIndex(of: "--close-test"), idx + 1 < args.count {
        let path = args[idx + 1]
        let outPath = (idx + 2 < args.count) ? args[idx + 2] : "/tmp/nmd-test/close-test.png"
        let app2 = NSApplication.shared
        app2.setActivationPolicy(.accessory)
        let wc = EditorWindowController()
        wc.window?.makeKeyAndOrderFront(nil)
        wc.loadFile(URL(fileURLWithPath: path))
        if ProcessInfo.processInfo.environment["NMD_EDIT"] == "1" {
            wc.simulateUserEdit(append: "\n\n自动保存测试\n")
        }
        FileHandle.standardError.write(Data("LOADED: \(wc.filePathForTest ?? "nil") dirty=\(wc.isDirtyForTest)\n".utf8))
        guard let win = wc.window else { FileHandle.standardError.write(Data("NO WIN\n".utf8)); app2.run(); return true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            win.performClose(nil)
        }
        // 模态弹窗会阻塞默认 runloop 模式，用 common 模式定时器截图并退出
        let timer = Timer(timeInterval: 2.5, repeats: false) { _ in
            var panelRep: NSBitmapImageRep?
            FileHandle.standardError.write(Data("CAPTURE: editorText=\(wc.editorTextView.string.count) wcWindowVisible=\(wc.window?.isVisible ?? false)\n".utf8))
            for w in NSApp.windows {
                guard w.isVisible, w != wc.window, let cv = w.contentView else { continue }
                guard let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) else { continue }
                cv.cacheDisplay(in: cv.bounds, to: rep)
                panelRep = rep
                FileHandle.standardError.write(Data("PANEL: \(String(describing: type(of: w))) frame=\(w.frame)\n".utf8))
            }
            if let png = panelRep?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: outPath))
            }
            NSApp.terminate(nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        app2.run()
        return true
    }
    if let idx = args.firstIndex(of: "--autosave-test"), idx + 1 < args.count {
        let path = args[idx + 1]
        let app2 = NSApplication.shared
        app2.setActivationPolicy(.accessory)
        let wc = EditorWindowController()
        wc.window?.makeKeyAndOrderFront(nil)
        wc.loadFile(URL(fileURLWithPath: path))
        wc.setAutoSaveForTesting(true)
        FileHandle.standardError.write(Data("AUTOSAVE: before tail=\((try? String(contentsOfFile: path, encoding: .utf8))?.suffix(20) ?? "nil") dirty=\(wc.isDirtyForTest)\n".utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            wc.simulateUserEdit(append: "\n\n自动保存测试\n")
        }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            let tail = (try? String(contentsOfFile: path, encoding: .utf8))?.suffix(20) ?? "读取失败"
            FileHandle.standardError.write(Data("AUTOSAVE: after tail=\(tail)\n".utf8))
            NSApp.terminate(nil)
        }
        app2.run()
        return true
    }
    if args.contains("--layout") {
        let app2 = NSApplication.shared
        let wc = EditorWindowController()
        app2.setActivationPolicy(.accessory)
        wc.window?.makeKeyAndOrderFront(nil)
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
            let dump = { (label: String, v: NSView?) in
                guard let v else { print(label, "nil"); return }
                print(label, v.frame.debugDescription, "hasSuper=", v.superview != nil, "alpha=", v.alphaValue)
            }
            dump("content", wc.window?.contentView)
            dump("split", wc.splitView)
            if let split = wc.splitView {
                for (i, sv) in split.subviews.enumerated() {
                    dump("subview[\(i)]", sv)
                }
                print("divider0=", NSRect(x: split.bounds.width * 0.46, y: 0, width: split.dividerThickness, height: split.bounds.height))
                print("previewTextLength=", wc.previewTextView.string.count)
                print("previewFirst30=", wc.previewTextView.string.prefix(30))
            }
            NSApp.terminate(nil)
        }
        app2.run()
        return true
    }
    if let idx = args.firstIndex(of: "--html"), idx + 1 < args.count {
        guard let md = try? String(contentsOfFile: args[idx + 1], encoding: .utf8) else {
            FileHandle.standardError.write(Data("读取文件失败\n".utf8))
            return true
        }
        print(MarkdownRenderer.html(from: md))
        return true
    }
    if let idx = args.firstIndex(of: "--png"), idx + 1 < args.count {
        let attr: NSAttributedString
        if args[idx + 1] == "-d" {
            attr = MarkdownRenderer.render(Sample.markdown)
        } else if let r = try? String(contentsOfFile: args[idx + 1], encoding: .utf8) {
            attr = MarkdownRenderer.render(r)
        } else {
            FileHandle.standardError.write(Data("读取文件失败\n".utf8)); return true
        }
        let width: CGFloat = 720
        let rect = attr.boundingRect(
            with: NSSize(width: width, height: 10_000),
            options: [.usesLineFragmentOrigin], context: nil)
        let size = NSSize(width: width + 48, height: ceil(rect.height) + 48)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        attr.draw(with: NSRect(x: 24, y: size.height - 24 - ceil(rect.height), width: width, height: ceil(rect.height)),
                  options: [.usesLineFragmentOrigin], context: nil)
        image.unlockFocus()
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]),
           idx + 2 < args.count {
            do {
                try png.write(to: URL(fileURLWithPath: args[idx + 2]))
            } catch {
                FileHandle.standardError.write(Data("写入 PNG 失败：\(error)\n".utf8))
                return true
            }
        }
        return true
    }
    return false
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
if !runCLI() {
    app.run()
}
