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

    ## 表格（带框线）
    | 功能 | 快捷键 | 说明 |
    | --- | :---: | ---: |
    | 新建备忘录并粘贴 | ⌘R | 创建并关联 |
    | **更新备忘录** | — | 写入关联的笔记 |
    | 转义竖线 | \\| 不切分列 | 列对齐 |

    ## 三种用法
    1. 新建备忘录并粘贴：生成一条原生排版的备忘录，富文本同时进剪贴板
    2. 复制为富文本：自行选择粘贴位置
    3. 右上角「自动保存md」：打开 md 文件后停顿 0.6 秒自动保存

    ---
    全局快捷键：⌥⌘M 打开 / 隐藏窗口
    """
}

// MARK: - 可自定义右键菜单的文本视图

/// 支持注入自定义右键菜单（全中文 + 查找/替换），覆盖系统默认英文菜单
class LocalMenuTextView: NSTextView {
    var buildContextMenu: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        return buildContextMenu?() ?? super.menu(for: event)
    }
}

// MARK: - 编辑区文本视图（粘贴图片/图床链接时自动转 ![](链接)）

final class EditorTextView: LocalMenuTextView {
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
/// 不绘制自身背景的分割视图：NSSplitView 默认填充不透明底色，
/// 会把窗口最底层的背景图完全盖住；这里不画背景，只按子视图布局补画分隔线
final class TransparentSplitView: NSSplitView {
    override func draw(_ dirtyRect: NSRect) {
        guard dividerStyle != .thick else { return }
        NSColor.separatorColor.setFill()
        let subs = arrangedSubviews.isEmpty ? subviews : arrangedSubviews
        guard subs.count >= 2 else { return }
        let t = dividerThickness
        for i in 0..<(subs.count - 1) {
            let a = subs[i].frame, b = subs[i + 1].frame
            let x = (a.maxX + b.minX) / 2 - t / 2
            NSRect(x: x, y: 0, width: t, height: bounds.height).intersection(dirtyRect).fill()
        }
    }
}

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
/// 与系统 NSSwitch 等尺寸（54x24）的开关；开启态轨道为灰色（系统开关只支持强调色/蓝色）
final class GraySwitch: NSControl {
    var state: NSControl.StateValue = .off {
        didSet {
            guard state != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.checkBox)
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityRole(.checkBox)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 54, height: 24) }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        let r = h / 2
        let on = state == .on
        (on ? NSColor.systemGreen : NSColor.systemGray.withAlphaComponent(0.28)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        // 白色旋钮（开启时靠右）
        let knobR: CGFloat = 20
        let cx = on ? bounds.maxX - r : bounds.minX + r
        let knob = NSRect(x: cx - knobR / 2, y: (h - knobR) / 2, width: knobR, height: knobR)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        // 按下即预览切换，在框内松开才生效
        state = (state == .on) ? .off : .on
        needsDisplay = true
        var releasedInside = false
        while true {
            guard let e = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                           until: .distantFuture, inMode: .eventTracking, dequeue: true)
            else { break }
            if e.type == .leftMouseUp {
                releasedInside = bounds.contains(convert(e.locationInWindow, from: nil))
                break
            }
        }
        if !releasedInside {
            state = (state == .on) ? .off : .on
            needsDisplay = true
            return
        }
        if let action { sendAction(action, to: target) }
    }

    override func accessibilityValue() -> Any? { state == .on ? 1.0 : 0.0 }
}

// MARK: - 背景图共享管理（主窗口 + 各弹窗铺同一张背景图，透明度联动）

final class BackgroundOverlay {
    static let shared = BackgroundOverlay()
    private init() {}

    var image: NSImage? { didSet { refresh() } }
    var alpha: CGFloat = 1 { didSet { refresh() } }

    private var views: [BackgroundImageView] = []
    private var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// 把背景视图挂到 view 最底层（随窗口缩放）；已挂则复用；窗口关闭时自动移除
    @discardableResult
    func attach(to view: NSView) -> BackgroundImageView {
        if let first = view.subviews.first as? BackgroundImageView {
            return first
        }
        let bv = BackgroundImageView()
        bv.autoresizingMask = [.width, .height]
        bv.frame = view.bounds
        bv.image = image
        bv.imageAlpha = alpha
        view.addSubview(bv, positioned: .below, relativeTo: nil)
        views.append(bv)
        if let win = view.window {
            let obs = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
                    if let v = win.contentView?.subviews.first as? BackgroundImageView {
                        self?.detach(v)
                    }
                }
            observers[ObjectIdentifier(bv)] = obs
        }
        return bv
    }

    func detach(_ bv: BackgroundImageView) {
        bv.removeFromSuperview()
        views.removeAll { $0 === bv }
        if let obs = observers.removeValue(forKey: ObjectIdentifier(bv)) {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func refresh() {
        for v in views {
            v.image = image
            v.imageAlpha = alpha
        }
    }
}

// MARK: - 主窗口

final class EditorWindowController: NSWindowController, NSTextViewDelegate, NSWindowDelegate,
                                        NSTextFieldDelegate {
    fileprivate var editorTextView: NSTextView!
    fileprivate var previewTextView: NSTextView!
    fileprivate var splitView: NSSplitView!
    private var titleField: NSTextField?
    /// 调试用：NMD_TITLE 预设的备忘录标题
    private var testTitleOverride: String?
    private var statusLabel: NSTextField!
    private var updateWorkItem: DispatchWorkItem?
    private var statusClearWork: DispatchWorkItem?
    private var fileURL: URL?
    private var isDirty = false
    private var isProgrammaticChange = false

    private var windowBackground: BackgroundImageView!
    private var opacitySlider: NSSlider?
    private var bgClearButton: NSButton?
    private var bgButton: NSButton!
    private var bgMenuButton: NSButton!
    private var bgSettingsWindow: NSPanel?
    private var bgCloseObserver: NSObjectProtocol?
    private var backgroundURL: URL?
    private var backgroundOpacity: CGFloat = 1
    /// 当前主工作模式，由「新建md / 打开md / 新建备忘录并粘贴 / 打开备忘录」切换：
    /// 关闭确认只检查对应一侧——md 模式看 md 是否保存，备忘录模式看新增内容是否已写回
    enum DocMode { case md, note }
    private var mode: DocMode = .md
    private var autoSaveSwitch: GraySwitch!
    private var autoSaveEnabled = false
    private var autoSaveWork: DispatchWorkItem?
    private var hasPushedToNotes = false

    // 图床（pixhost）
    private var pixUploadButton: NSButton!
    private var pixHistoryButton: NSButton!
    private var pixHistoryWC: PixHistoryWindowController?
    private var pixResultSheet: PixResultSheet?
    // 备忘录关联（关联修改）
    private var updateNoteButton: NSButton!
    private var pickNoteButton: NSButton!
    private var notePickerWC: NotePickerWindowController?
    private var boundNoteName: String? = NoteBinding.name

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 600),
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

        // 窗口级背景图：由 BackgroundOverlay 统一管理（主窗口 + 各弹窗共用同一张图与透明度），
        // 先加入即位于最底层，覆盖编辑区与预览区；不改动窗口 frame，
        // 因此添加背景图不会改变窗口大小与比例
        windowBackground = BackgroundOverlay.shared.attach(to: content)

        // 底部：仅状态栏（操作按钮已移到顶栏左侧，「复制为富文本」按钮已移除，菜单中仍可用 ⇧⌘C）
        let bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: content.bounds.width, height: 48))
        bottomBar.autoresizingMask = [.width]
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -14),
            statusLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor)
        ])
        content.addSubview(bottomBar)

        // 顶行：左侧文档/备忘录操作，右侧自动保存md + 背景设置 + 图床；
        // 标题输入已移除，备忘录标题统一取正文首个非空行
        let topBar = NSView(frame: NSRect(x: 0, y: content.bounds.height - 40,
                                          width: content.bounds.width, height: 40))
        topBar.autoresizingMask = [.width, .minYMargin]

        let newButton = makeTopBarButton("新建md", action: #selector(newDocument))
        let openFileButton = makeTopBarButton("打开md", action: #selector(openDocument))
        let saveButton = makeTopBarButton("保存md", action: #selector(saveDocumentAction))
        let noteButton = makeTopBarButton("新建备忘录并粘贴", action: #selector(createNoteAndPaste))
        noteButton.keyEquivalent = "r"
        pickNoteButton = makeTopBarButton("打开备忘录", action: #selector(pickNoteToBind))
        updateNoteButton = makeTopBarButton("更新备忘录", action: #selector(updateBoundNote))
        let copyButton = makeTopBarButton("复制为富文本", action: #selector(copyRich))
        copyButton.keyEquivalent = "c"
        copyButton.keyEquivalentModifierMask = [.command, .shift]
        let leftStack = NSStackView(views: [newButton, openFileButton, saveButton,
                                            noteButton, pickNoteButton, updateNoteButton, copyButton])
        leftStack.orientation = .horizontal
        leftStack.spacing = 6
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(leftStack)
        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 14),
            leftStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor)
        ])
        // 顶栏右侧：自动保存md + 背景设置（弹窗）+ 图床
        let autoSaveHint = NSTextField(labelWithString: "自动保存md")
        autoSaveHint.font = NSFont.systemFont(ofSize: 11)
        autoSaveHint.textColor = .secondaryLabelColor
        autoSaveSwitch = GraySwitch()
        autoSaveSwitch.state = autoSaveEnabled ? .on : .off
        autoSaveSwitch.target = self
        autoSaveSwitch.action = #selector(toggleAutoSave(_:))
        autoSaveSwitch.toolTip = "开启后：打开 md 文件时，停顿 0.6 秒自动保存该 md 文件"
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.heightAnchor.constraint(equalToConstant: 18).isActive = true
        // 背景图片/透明度/清除背景收进「背景设置」弹窗，给标题框和自动保存md留出空间
        bgMenuButton = iconTopButton("photo", action: #selector(showBackgroundMenu),
                                     title: "背景设置", tooltip: "背景图片、透明度、清除背景")
        let sep2 = NSBox()
        sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false
        sep2.heightAnchor.constraint(equalToConstant: 18).isActive = true
        pixUploadButton = iconTopButton("photo.badge.plus", action: #selector(uploadImagesToPixhost),
                                        title: "上传图床", tooltip: "上传图片到 pixhost 图床，可复制原图链接")
        pixHistoryButton = iconTopButton("photo.stack", action: #selector(showPixHistory),
                                         title: "历史图片", tooltip: "查看之前上传的所有图片")
        let rightStack = NSStackView(views: [autoSaveHint, autoSaveSwitch, sep, bgMenuButton,
                                             sep2, pixUploadButton, pixHistoryButton])
        rightStack.orientation = .horizontal
        rightStack.spacing = 8
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(rightStack)
        NSLayoutConstraint.activate([
            rightStack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -14),
            rightStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor)
        ])
        content.addSubview(topBar)

        // 中间：左编辑 右预览
        let split = TransparentSplitView(frame: NSRect(x: 0, y: 48,
                                                       width: content.bounds.width,
                                                       height: content.bounds.height - 48 - 40))
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
        updateNoteBindingsUI()
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
        let tv: NSTextView
        if editor {
            tv = EditorTextView()
        } else {
            // 预览用自定义 layoutManager：代码块底色整块填充（原生只逐行填充，行间有缝）
            let storage = NSTextStorage()
            let lm = CodeBlockLayoutManager()
            storage.addLayoutManager(lm)
            let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 0 // 与 NSTextView 默认一致
            lm.addTextContainer(container)
            tv = LocalMenuTextView(frame: .zero, textContainer: container)
        }
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
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 6, height: 12)
        // 全中文右键菜单（含查找/替换），覆盖系统默认英文菜单
        let ltv = tv as! LocalMenuTextView
        ltv.buildContextMenu = editor
            ? { [weak self] in self?.makeEditorContextMenu() }
            : { [weak self] in self?.makePreviewContextMenu() }
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

    /// 顶栏操作按钮（小号，适配顶栏高度）
    private func makeTopBarButton(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }

    // MARK: - 右键菜单（全中文，含查找/替换）

    // 调试入口
    func ctxMenuForTesting(_ editor: Bool) -> NSMenu { editor ? makeEditorContextMenu() : makePreviewContextMenu() }

    /// 编辑区右键菜单：中文 + 查找/替换 + 复制为富文本
    private func makeEditorContextMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, _ key: String = "",
                 mods: NSEvent.ModifierFlags = .command) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            if !key.isEmpty { it.keyEquivalentModifierMask = mods }
            m.addItem(it)
        }
        add("撤销", Selector(("undo:")), "z")
        add("重做", Selector(("redo:")), "Z", mods: [.command, .shift])
        m.addItem(.separator())
        add("剪切", #selector(NSText.cut(_:)), "x")
        add("拷贝", #selector(NSText.copy(_:)), "c")
        add("粘贴", #selector(NSText.paste(_:)), "v")
        add("粘贴并匹配样式", Selector(("pasteAsPlainText:")), "V", mods: [.command, .option, .shift])
        add("删除", #selector(NSText.delete(_:)))
        add("全选", #selector(NSText.selectAll(_:)), "a")
        m.addItem(.separator())
        add("查找…", #selector(NSText.performTextFinderAction(_:)), "f")
        m.item(withTitle: "查找…")?.tag = 1
        let findReplace = NSMenuItem(title: "查找并替换…",
                                     action: #selector(NSText.performTextFinderAction(_:)), keyEquivalent: "f")
        findReplace.keyEquivalentModifierMask = [.command, .option]
        findReplace.tag = 12
        m.addItem(findReplace)
        m.addItem(.separator())
        let copyRich = NSMenuItem(title: "复制为富文本", action: #selector(copyRich), keyEquivalent: "C")
        copyRich.keyEquivalentModifierMask = [.command, .shift]
        copyRich.target = self          // 窗口控制器不在响应链上，需显式指定 target
        m.addItem(copyRich)
        return m
    }

    /// 预览区右键菜单：中文（只读：拷贝/全选/查找）
    private func makePreviewContextMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, _ key: String = "",
                 mods: NSEvent.ModifierFlags = .command) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            if !key.isEmpty { it.keyEquivalentModifierMask = mods }
            m.addItem(it)
        }
        add("拷贝", #selector(NSText.copy(_:)), "c")
        add("全选", #selector(NSText.selectAll(_:)), "a")
        m.addItem(.separator())
        add("查找…", #selector(NSText.performTextFinderAction(_:)), "f")
        m.item(withTitle: "查找…")?.tag = 1
        return m
    }

    private func iconTopButton(_ symbol: String, action: Selector, title: String, tooltip: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.toolTip = tooltip
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            b.image = img
            b.imagePosition = .imageLeading
        }
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

        // 自动保存md：文件已打开且停止输入 0.6 秒后静默保存
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

    @objc func toggleAutoSave(_ sender: GraySwitch) {
        autoSaveEnabled = sender.state == .on
        UserDefaults.standard.set(autoSaveEnabled, forKey: Self.defaultKeyAutoSave)
        if !autoSaveEnabled {
            autoSaveWork?.cancel()
        }
    }

    private func refreshPreview() {
        // 窗口未布局完成时兜底 320，避免首帧表格被过度压缩
        let width = max(previewTextView.bounds.width - 24, 320)
        // 预览按「推送备忘录」的最终 markdown 渲染：标题输入框有内容时预览同步显示标题
        let rendered = MarkdownRenderer.render(noteTitleMarkdown, contentWidth: width) { [weak self] in
            // 图床图片下载完成：重渲染（命中缓存，不再下载）
            self?.refreshPreview()
        }
        // 代码块的底色由 CodeBlockLayoutManager 按「块内最宽行」整块填充；
        // 这里去掉代码块区间的整行 .backgroundColor，避免原生填充把右侧空白也填上
        //（.backgroundColor 仅保留给不走文本视图的 CLI --png 路径）
        let stripped = rendered.mutableCopy() as! NSMutableAttributedString
        stripped.enumerateAttribute(CodeBlockAttributes.background,
                                    in: NSRange(location: 0, length: stripped.length)) { value, range, _ in
            if value != nil {
                stripped.removeAttribute(NSAttributedString.Key.backgroundColor, range: range)
            }
        }
        previewTextView.textStorage?.setAttributedString(stripped)
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
        mode = .md
        fileURL = nil
        ImageStore.baseDirectory = FileManager.default.homeDirectoryForCurrentUser
        isDirty = false
        hasPushedToNotes = false
        isProgrammaticChange = true
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
        mode = .md
        fileURL = url
        ImageStore.baseDirectory = url.deletingLastPathComponent()
        isDirty = false
        hasPushedToNotes = false
        isProgrammaticChange = true
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
        ImageStore.baseDirectory = url.deletingLastPathComponent()
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
        if mode == .note {
            alert.messageText = "有尚未写入备忘录的更改"
            alert.informativeText = "要离开当前内容吗？尚未写入关联备忘录的更改将丢失。"
        } else {
            alert.messageText = "有未保存的更改"
            alert.informativeText = "要离开当前内容吗？未保存的 md 更改将丢失。"
        }
        alert.addButton(withTitle: "放弃更改")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 关闭确认（红点关窗 / ⌘Q 退出共用）。按当前模式区分：
    /// - md 模式（新建md / 打开md）：已保存或无新增内容时直接关闭不提醒；
    ///   有未保存更改时提醒保存 md；「自动保存md」开启且已打开文件时直接保存，不弹窗
    /// - 备忘录模式（新建备忘录 / 打开备忘录）：新增内容已写回关联备忘录时直接关闭不提醒；
    ///   未写回时提醒更新备忘录
    func confirmCloseContent() -> Bool {
        let hasContent = !editorTextView.string
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch mode {
        case .md:
            guard hasContent, isDirty else { return true }
            if autoSaveEnabled, let url = fileURL {
                // 自动保存md：把停止输入后未及写盘的更改直接落盘，不弹窗
                autoSaveWork?.cancel()
                return save(to: url)
            }
            let alert = NSAlert()
            if let url = fileURL {
                alert.messageText = "md 有未保存的更改"
                alert.informativeText = "当前内容还没有保存到「\(url.lastPathComponent)」。\n关闭前是否保存？"
                alert.addButton(withTitle: "保存并关闭")
            } else {
                alert.messageText = "md 还没有保存"
                alert.informativeText = "当前内容还没有保存为 md 文件。\n关闭前是否保存？"
                alert.addButton(withTitle: "另存为并关闭")
            }
            alert.addButton(withTitle: "不保存直接关闭")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return saveDocument()
            case .alertSecondButtonReturn:
                return true
            default:
                return false
            }
        case .note:
            guard hasContent, !hasPushedToNotes else { return true }
            let bound = NoteBinding.id != nil
            let alert = NSAlert()
            if bound, let name = boundNoteName {
                alert.messageText = "新增内容还没有更新到备忘录"
                alert.informativeText = "当前内容还没有写入关联的备忘录「\(name)」。\n关闭前是否更新？"
                alert.addButton(withTitle: "更新备忘录并关闭")
            } else {
                alert.messageText = "内容还没有写入备忘录"
                alert.informativeText = "关闭前是否新建备忘录并写入当前内容？"
                alert.addButton(withTitle: "新建备忘录并粘贴，然后关闭")
            }
            alert.addButton(withTitle: bound ? "不更新直接关闭" : "不写入直接关闭")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return pushNowToNotes()
            case .alertSecondButtonReturn:
                return true
            default:
                return false
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmCloseContent()
    }

    // 关窗已确认（NSWindowDelegate 只有 willClose，没有 didClose）：CLI 测试用标记
    func windowWillClose(_ notification: Notification) {
        FileHandle.standardError.write(Data("WINDOW-CLOSED\n".utf8))
    }

    // MARK: - 操作

    /// 推送/剪贴板用的 markdown：确保首个非空行是最终标题 H1。
    /// 备忘录会把正文首行渲染为加粗大标题并用作笔记名，正文保留该 H1 即可：
    /// 主标题加粗、不重复
    fileprivate var noteTitleMarkdown: String {
        let explicit = (testTitleOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return MarkdownRenderer.noteMarkdown(editorTextView.string, explicitTitle: explicit)
    }

    /// 新建备忘录并粘贴：AppleScript 创建带完整内容的备忘录（首行为加粗标题），
    /// 同时把富文本复制进剪贴板，方便再 ⌘V 到其他笔记
    @objc func createNoteAndPaste() {
        mode = .note
        NotesService.copyRich(markdown: noteTitleMarkdown)
        let md = noteTitleMarkdown
        let html = MarkdownRenderer.html(from: md)
        let title = MarkdownRenderer.deriveTitle(from: md) ?? "未命名备忘录"
        setStatus("正在写入备忘录…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NotesService.createNote(html: html)
            DispatchQueue.main.async {
                switch result {
                case .success(let noteID):
                    self.hasPushedToNotes = true
                    NotePushCache.store(md, noteID: noteID)
                    self.bindNote(id: noteID, name: title, silent: true)
                    self.setStatus("已创建并关联备忘录「\(title)」，富文本也已复制到剪贴板")
                case .failure(let error):
                    self.setStatus("创建失败：\(error.localizedDescription)（富文本已在剪贴板，可手动 ⌘V）")
                }
            }
        }
    }

    /// 创建一条新备忘录（写入当前内容）并自动关联，返回是否成功。
    /// 「新建备忘录并粘贴」与「更新备忘录」的未关联引导共用此流程。
    @discardableResult
    private func createNoteAndBind() -> Bool {
        mode = .note
        let md = noteTitleMarkdown
        let html = MarkdownRenderer.html(from: md)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NotesService.createNote(html: html)
            DispatchQueue.main.async {
                switch result {
                case .success(let noteID):
                    self.hasPushedToNotes = true
                    NotePushCache.store(md, noteID: noteID)
                    self.bindNote(id: noteID, name: MarkdownRenderer.deriveTitle(from: md) ?? "未命名备忘录", silent: true)
                case .failure(let error):
                    self.setStatus("新建备忘录失败：\(error.localizedDescription)")
                }
            }
        }
        return true
    }

    /// 同步写入备忘录（关闭确认弹窗用；osascript 约 1 秒）。
    /// 已关联笔记时直接更新该笔记，否则新建一条并自动关联。
    @discardableResult
    private func pushNowToNotes() -> Bool {
        let md = noteTitleMarkdown
        let html = MarkdownRenderer.html(from: md)
        if let id = NoteBinding.id {
            switch NotesService.updateNote(id: id, html: html) {
            case .success:
                hasPushedToNotes = true
                NotePushCache.store(md, noteID: id)
                return true
            case .failure(let error):
                unbindNote(silent: true)
                setStatus("更新失败：\(error.localizedDescription)")
                return false
            }
        }
        switch NotesService.createNote(html: html) {
        case .success(let id):
            hasPushedToNotes = true
            NotePushCache.store(md, noteID: id)
            let title = MarkdownRenderer.deriveTitle(from: md) ?? "未命名备忘录"
            bindNote(id: id, name: title, silent: true)
            return true
        case .failure(let error):
            setStatus("创建失败：\(error.localizedDescription)")
            return false
        }
    }

    @objc func copyRich() {
        NotesService.copyRich(markdown: noteTitleMarkdown)
        setStatus("已复制富文本，到备忘录中按 ⌘V 粘贴")
    }

    // MARK: - 备忘录关联（关联修改）

    /// 把当前内容写入关联的备忘录。
    /// 未关联：先引导新建一条或打开一条已有备忘录；
    /// 已关联：写入前二次确认，明确会整体覆盖该备忘录的现有内容。
    @objc func updateBoundNote() {
        let md = noteTitleMarkdown
        guard !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setStatus("内容为空，没有可写入的正文")
            return
        }
        guard let id = NoteBinding.id else {
            let alert = NSAlert()
            alert.messageText = "尚未关联备忘录"
            alert.informativeText = "更新前需要先确定写入哪条备忘录：新建一条备忘录，或打开一条已有备忘录进行关联。"
            alert.addButton(withTitle: "新建备忘录")
            alert.addButton(withTitle: "打开备忘录…")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                createNoteAndBind()
            case .alertSecondButtonReturn:
                pickNoteToBind()
            default:
                break
            }
            return
        }
        let title = MarkdownRenderer.deriveTitle(from: md) ?? (boundNoteName ?? "未命名备忘录")
        let html = MarkdownRenderer.html(from: md)
        let bound = boundNoteName ?? "未命名备忘录"
        let alert = NSAlert()
        alert.messageText = "更新会覆盖备忘录现有内容"
        alert.informativeText = "将用当前编辑区内容整体替换备忘录「\(bound)」的现有内容，不可撤销。"
        alert.addButton(withTitle: "确认更新")
        alert.addButton(withTitle: "新建备忘录")
        alert.addButton(withTitle: "打开备忘录…")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            break
        case .alertSecondButtonReturn:
            createNoteAndBind(); return
        case .alertThirdButtonReturn:
            pickNoteToBind(); return
        default:
            return
        }
        setStatus("正在更新备忘录「\(bound)」…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NotesService.updateNote(id: id, html: html)
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.hasPushedToNotes = true
                    NotePushCache.store(md, noteID: id)
                    self.setStatus("已更新备忘录「\(title)」")
                case .failure(let error):
                    self.unbindNote()
                    self.setStatus("更新失败：\(error.localizedDescription)（已解除关联，可重新选择）")
                }
            }
        }
    }

    /// 打开笔记选择窗口，选择一条备忘录：其正文以 Markdown 加载进编辑区并关联
    @objc func pickNoteToBind() {
        // 当前编辑区内容若尚未保存为 md、也尚未「新建备忘录并粘贴」写入备忘录，
        // 加载会把内容整体替换，先确认
        let text = editorTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedToFile = !isDirty && fileURL != nil
        if !text.isEmpty && !savedToFile && !hasPushedToNotes {
            let alert = NSAlert()
            alert.messageText = "加载备忘录会替换当前内容"
            alert.informativeText = "当前编辑区内容还没有保存为 md 文件，也没有写入备忘录（新建备忘录并粘贴）。\n加载所选备忘录后，当前内容将被替换。"
            alert.addButton(withTitle: "仍然加载")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if notePickerWC == nil {
            let wc = NotePickerWindowController()
            wc.onPick = { [weak self] id, name in
                guard let self else { return }
                self.mode = .note
                self.bindNote(id: id, name: name, silent: false, loadContent: true)
                self.hasPushedToNotes = false
            }
            notePickerWC = wc
        }
        notePickerWC?.showWindowAndLoad()
    }

    func bindNote(id: String, name: String, silent: Bool, loadContent: Bool = false) {
        NoteBinding.bind(id: id, name: name)
        boundNoteName = name
        updateNoteBindingsUI()
        if loadContent {
            loadBoundNoteIntoEditor(name: name)
        }
        if !silent {
            setStatus(loadContent
                      ? "已打开备忘录「\(name)」，内容已加载进编辑区；点「更新备忘录」可写回"
                      : "已关联备忘录「\(name)」，点「更新备忘录」即可写入")
        }
    }

    /// 关联时把该备忘录正文读回并转成 Markdown 装入编辑区（源文件与笔记内容一致）
    private func loadBoundNoteIntoEditor(name: String) {
        setStatus("正在读取备忘录内容…")
        DispatchQueue.global(qos: .userInitiated).async {
            var markdown = ""
            if let id = NoteBinding.id,
               case .success(let html) = NotesService.noteHTML(id: id) {
                markdown = MarkdownFromHTML.convert(html)
                // Notes 读回的 HTML 丢失表格列对齐：用最近一次写入该备忘录的
                // markdown 恢复 :---: / ---: 对齐行（表头一致才匹配）
                if let cached = NotePushCache.markdown(for: id) {
                    markdown = MarkdownFromHTML.restoreTableAlignments(markdown, from: cached)
                }
            }
            DispatchQueue.main.async {
                // 期间用户已换绑其他笔记时丢弃过期结果
                guard NoteBinding.name == name else { return }
                self.isProgrammaticChange = true
                self.editorTextView.string = markdown
                self.isProgrammaticChange = false
                self.refreshPreview()
                // 读回的内容与备忘录一致，视为已同步：关闭时不再提醒更新
                self.hasPushedToNotes = true
                // 读取备忘录时 AppleScript 会把「备忘录」App 带到前台，
                // 内容加载完成后自动跳回 NotesMD 主窗口
                NSApp.activate(ignoringOtherApps: true)
                self.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc func unbindNote() {
        unbindNote(silent: false)
    }

    private func unbindNote(silent: Bool) {
        NoteBinding.unbind()
        boundNoteName = nil
        updateNoteBindingsUI()
        if !silent {
            setStatus("已解除关联")
        }
    }

    private func updateNoteBindingsUI() {
        if let name = NoteBinding.name {
            pickNoteButton.toolTip = "打开（替换为）一条已有备忘录的 Markdown 内容，并关联到「\(name)」"
        } else {
            pickNoteButton.toolTip = "打开一条已有备忘录：其内容以 Markdown 加载进编辑区并关联"
        }
        updateNoteButton.isEnabled = true
        if let name = NoteBinding.name {
            updateNoteButton.toolTip = "把当前内容整体覆盖关联的备忘录「\(name)」，写入前会再次确认"
        } else {
            updateNoteButton.toolTip = "尚未关联备忘录：点「打开备忘录」加载一条已有笔记，或先「新建备忘录并粘贴」"
        }
    }

    // MARK: - pixhost 图床

    @objc func uploadImagesToPixhost() {
        let panel = NSOpenPanel()
        panel.title = "选择要上传到 pixhost 的图片"
        panel.allowedContentTypes = [UTType.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        pixUploadButton.isEnabled = false
        var results: [Result<PixImage, Error>] = []
        var idx = 0
        func step() {
            guard idx < urls.count else {
                pixUploadButton.isEnabled = true
                self.showPixResult(results)
                return
            }
            let url = urls[idx]
            PixhostAPI.upload(fileURL: url) { [weak self] result in
                results.append(result)
                if case .success(let img) = result { PixHistory.add(img) }
                idx += 1
                self?.setStatus("正在上传到 pixhost（\(idx)/\(urls.count)）…")
                step()
            }
        }
        step()
    }

    private func showPixResult(_ results: [Result<PixImage, Error>]) {
        let okCount = results.filter {
            if case .success = $0 { return true } else { return false }
        }.count
        if okCount > 0 {
            setStatus("已上传 \(okCount) 张图片到 pixhost")
        }
        guard let window else { return }
        let sheetObj = PixResultSheet(results: results) { [weak self] text in
            guard let self else { return }
            self.editorTextView.insertText(text, replacementRange: self.editorTextView.selectedRange())
        }
        let sheetView = sheetObj.makeView()
        let sheetWin = NSWindow(contentRect: sheetView.frame, styleMask: [.titled],
                                backing: .buffered, defer: false)
        sheetWin.contentView = sheetView
        pixResultSheet = sheetObj
        window.beginSheet(sheetWin) { [weak self] _ in
            self?.pixResultSheet = nil
        }
    }

    @objc func showPixHistory() {
        if pixHistoryWC == nil {
            let wc = PixHistoryWindowController()
            wc.window?.center()
            pixHistoryWC = wc
        }
        pixHistoryWC?.showWindowAndReload()
    }

    // MARK: - 背景图片

    private static let defaultKeyAutoSave = "notesmd.autosave"
    private static let defaultKeyBgURL = "notesmd.backgroundURL"
    private static let defaultKeyBgAlpha = "notesmd.backgroundOpacity"

    // 调试入口
    func showBackgroundMenuForTesting() { showBackgroundMenu() }
    var bgSettingsWindowForTesting: NSPanel? { bgSettingsWindow }

    /// 「背景设置」弹窗：背景图片、透明度、清除背景（顶栏只留入口按钮）
    @objc func showBackgroundMenu() {
        if bgSettingsWindow == nil { buildBgSettingsPanel() }
        guard let panel = bgSettingsWindow else { return }
        updateBackgroundControls()
        if let anchor = bgMenuButton, let win = anchor.window {
            let rectOnScreen = win.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            // 面板顶部对齐按钮底边 + 6pt（屏幕坐标 y 轴向上，故取 minY - 6）
            panel.setFrameTopLeftPoint(NSPoint(x: rectOnScreen.minX, y: rectOnScreen.minY - 6))
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildBgSettingsPanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 186),
                            styleMask: [.titled, .closable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "背景设置"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false

        guard let content = panel.contentView else { return }
        // 弹窗自身也铺同一张背景图（跟随透明度设置）
        _ = BackgroundOverlay.shared.attach(to: content)
        let bgLabel = NSTextField(labelWithString: "背景图片")
        bgLabel.font = NSFont.systemFont(ofSize: 12)
        bgLabel.textColor = .secondaryLabelColor
        let pickBtn = makeButton("选择背景图片…", action: #selector(pickBackgroundImage))
        pickBtn.controlSize = .small
        let clearBtn = makeButton("清除背景", action: #selector(clearBackgroundImage))
        clearBtn.controlSize = .small
        let opacityHint = NSTextField(labelWithString: "透明度")
        opacityHint.font = NSFont.systemFont(ofSize: 11)
        opacityHint.textColor = .secondaryLabelColor
        let slider = NSSlider(value: backgroundOpacity * 100, minValue: 0, maxValue: 100,
                              target: self, action: #selector(opacitySliderChanged(_:)))
        slider.controlSize = .small
        slider.toolTip = "背景图片不透明度"
        bgButton = pickBtn
        bgClearButton = clearBtn
        opacitySlider = slider
        for v: NSView in [bgLabel, pickBtn, clearBtn, opacityHint, slider] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bgLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            bgLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            pickBtn.topAnchor.constraint(equalTo: bgLabel.bottomAnchor, constant: 6),
            pickBtn.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            clearBtn.topAnchor.constraint(equalTo: pickBtn.bottomAnchor, constant: 8),
            clearBtn.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            opacityHint.topAnchor.constraint(equalTo: clearBtn.bottomAnchor, constant: 14),
            opacityHint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            slider.topAnchor.constraint(equalTo: opacityHint.bottomAnchor, constant: 6),
            slider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            slider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16)
        ])
        bgSettingsWindow = panel
        bgCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            self?.bgSettingsWindow = nil
            self?.bgCloseObserver = nil
        }
    }

    @objc func pickBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = "选择预览背景图片"
        panel.allowedContentTypes = [UTType.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }
        backgroundURL = url
        BackgroundOverlay.shared.image = image
        BackgroundOverlay.shared.alpha = backgroundOpacity
        updateBackgroundControls()
        persistBackground()
    }

    @objc func clearBackgroundImage() {
        backgroundURL = nil
        backgroundOpacity = 1
        BackgroundOverlay.shared.image = nil
        opacitySlider?.doubleValue = 100
        updateBackgroundControls()
        persistBackground()
    }

    @objc func opacitySliderChanged(_ sender: NSSlider) {
        backgroundOpacity = sender.doubleValue / 100
        BackgroundOverlay.shared.alpha = backgroundOpacity
        persistBackground()
    }

    private func updateBackgroundControls() {
        let has = windowBackground.image != nil
        opacitySlider?.isEnabled = has
        bgClearButton?.isEnabled = has
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
        opacitySlider?.doubleValue = backgroundOpacity * 100
        if let path = d.string(forKey: Self.defaultKeyBgURL),
           let image = NSImage(contentsOfFile: path) {
            backgroundURL = URL(fileURLWithPath: path)
            BackgroundOverlay.shared.image = image
            BackgroundOverlay.shared.alpha = backgroundOpacity
        }
    }

    var isDirtyForTest: Bool { isDirty }

    func setAutoSaveForTesting(_ on: Bool) {
        autoSaveEnabled = on
        autoSaveSwitch.state = on ? .on : .off
    }

    func setModeForTesting(_ m: DocMode) { mode = m }
    func setPushedForTesting(_ v: Bool) { hasPushedToNotes = v }
    func setFileURLForTesting(_ url: URL?) { fileURL = url }

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

    func setTitleForTesting(_ t: String) {
        testTitleOverride = t
        refreshPreview()
    }

    func setBackgroundForTesting(url: URL, alpha: CGFloat) {
        guard let image = NSImage(contentsOf: url) else { return }
        backgroundURL = url
        backgroundOpacity = alpha
        BackgroundOverlay.shared.image = image
        BackgroundOverlay.shared.alpha = alpha
        opacitySlider?.doubleValue = alpha * 100
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
    /// CLI 测试：跳过启动时的状态栏/菜单/窗口创建
    var skipLaunchSetupForTesting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if skipLaunchSetupForTesting { return }
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        setupStatusItem()
        buildMainMenu()
        Hotkey.register()
        showWindow()
    }

    /// CLI 测试：直接注入编辑器窗口控制器
    func attachEditorForTesting(_ wc: EditorWindowController) { editor = wc }

    /// 调试：供 --menu-dump 调用构建主菜单
    func buildMainMenuForTesting() { buildMainMenu() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        showWindow()
        if let first = urls.first { editor?.loadFile(first) }
    }

    /// ⌘Q / 菜单「退出」：NSApp.terminate 不会调用 windowShouldClose，
    /// 这里走同一套关闭确认；窗口已关闭（关窗时已确认过）则直接退出
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let editor, editor.window?.isVisible == true, !editor.confirmCloseContent() else {
            return .terminateNow
        }
        return .terminateCancel
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
            NSMenuItem(title: "更新关联备忘录", action: #selector(editorUpdateBoundNote), keyEquivalent: ""),
            NSMenuItem(title: "打开备忘录", action: #selector(editorPickNote), keyEquivalent: ""),
            NSMenuItem(title: "上传图片到 pixhost…", action: #selector(editorUploadPixhost), keyEquivalent: ""),
            NSMenuItem(title: "pixhost 历史图片", action: #selector(editorShowPixHistory), keyEquivalent: ""),
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
        editMenuItem.title = "编辑"   // 菜单栏显示中文标题
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        let pastePlain = NSMenuItem(title: "粘贴并匹配样式",
                                    action: Selector(("pasteAsPlainText:")), keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        editMenu.addItem(pastePlain)
        editMenu.addItem(NSMenuItem(title: "删除", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())

        // 查找 / 替换（NSTextFinder，配合编辑器 usesFindBar）
        let findItem = NSMenuItem(title: "查找", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "查找")
        findItem.submenu = findMenu
        func finderItem(_ title: String, _ tag: Int, _ key: String,
                        mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let it = NSMenuItem(title: title,
                                action: #selector(NSText.performTextFinderAction(_:)), keyEquivalent: key)
            it.tag = tag
            it.keyEquivalentModifierMask = mods
            findMenu.addItem(it)
            return it
        }
        finderItem("查找…", 1, "f")                                   // showFindInterface
        let findReplace = finderItem("查找并替换…", 12, "f",
                                     mods: [.command, .option])       // showReplaceInterface
        finderItem("查找下一个", 2, "g")                                // nextMatch
        finderItem("查找上一个", 3, "g", mods: [.command, .shift])      // previousMatch
        finderItem("替换下一个", 5, "")                                 // replace
        finderItem("全部替换", 4, "")                                   // replaceAll
        finderItem("替换并查找", 6, "")                                 // replaceAndFind
        finderItem("用所选文字查找", 7, "e")                             // setSearchString
        editMenu.addItem(findItem)
        let selectItem = NSMenuItem(title: "定位", action: nil, keyEquivalent: "")
        let selectMenu = NSMenu(title: "定位")
        selectItem.submenu = selectMenu
        selectMenu.addItem(NSMenuItem(title: "定位选区",
                                      action: #selector(NSResponder.centerSelectionInVisibleArea(_:)),
                                      keyEquivalent: "j"))
        editMenu.addItem(selectItem)

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenuItem.submenu = fileMenu
        fileMenuItem.title = "文件"   // 菜单栏显示中文标题
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
        let updateItem = NSMenuItem(title: "更新关联备忘录", action: #selector(editorUpdateBoundNote), keyEquivalent: "U")
        updateItem.target = self
        updateItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(updateItem)
        let pickItem = NSMenuItem(title: "打开备忘录（加载内容并关联）", action: #selector(editorPickNote), keyEquivalent: "")
        pickItem.target = self
        fileMenu.addItem(pickItem)
        let unbindItem = NSMenuItem(title: "解除关联备忘录", action: #selector(editorUnbindNote), keyEquivalent: "")
        unbindItem.target = self
        fileMenu.addItem(unbindItem)
        fileMenu.addItem(.separator())
        let uploadItem = NSMenuItem(title: "上传图片到 pixhost…", action: #selector(editorUploadPixhost), keyEquivalent: "")
        uploadItem.target = self
        fileMenu.addItem(uploadItem)
        let historyItem = NSMenuItem(title: "pixhost 历史图片", action: #selector(editorShowPixHistory), keyEquivalent: "")
        historyItem.target = self
        fileMenu.addItem(historyItem)
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
        // 主窗口关闭后重新打开时，背景视图已被自动移除，需重新挂载（已挂则复用）
        if let content = editor?.window?.contentView {
            _ = BackgroundOverlay.shared.attach(to: content)
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
    @objc func editorUpdateBoundNote() { editor?.updateBoundNote() }
    @objc func editorPickNote() { editor?.pickNoteToBind() }
    @objc func editorUnbindNote() { editor?.unbindNote() }
    @objc func editorUploadPixhost() { editor?.uploadImagesToPixhost() }
    @objc func editorShowPixHistory() { editor?.showPixHistory() }
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
        case .success(let noteID): print("createNote=OK id=", noteID)
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
        // 相对图片路径按该 md 文件所在目录解析（与打开文件后的行为一致；NMD_BASE_DIR 可覆盖）
        if let envBase = ProcessInfo.processInfo.environment["NMD_BASE_DIR"] {
            ImageStore.baseDirectory = URL(fileURLWithPath: (envBase as NSString).expandingTildeInPath)
        } else {
            let srcURL = URL(fileURLWithPath: (args[idx + 1] as NSString).expandingTildeInPath)
            if srcURL.isFileURL, srcURL.path.hasPrefix("/") {
                ImageStore.baseDirectory = srcURL.deletingLastPathComponent()
            }
        }
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
        if let sizeStr = ProcessInfo.processInfo.environment["NMD_SHOT_SIZE"] {
            let parts = sizeStr.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { wc.window?.setContentSize(NSSize(width: parts[0], height: parts[1])) }
        }
        wc.setTextForTesting(md)
        if ProcessInfo.processInfo.environment["NMD_AUTOSAVE"] == "1" {
            wc.setAutoSaveForTesting(true)
        }
        // 测试：预设标题输入框内容并触发预览刷新，验证「标题进预览」
        if let titleEnv = ProcessInfo.processInfo.environment["NMD_TITLE"] {
            wc.setTitleForTesting(titleEnv)
        }
        // 测试：绑定一条真实备忘录并加载其内容（验证「打开备忘录」加载表格等）
        if let bindID = ProcessInfo.processInfo.environment["NMD_BIND_ID"],
           let bindName = ProcessInfo.processInfo.environment["NMD_BIND_NAME"] {
            wc.bindNote(id: bindID, name: bindName, silent: true, loadContent: true)
        }
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
            // 测试：滚动预览到指定 y（验证折叠线下方代码块底色等）
            if let scrollY = ProcessInfo.processInfo.environment["NMD_SHOT_SCROLL"].flatMap(Double.init) {
                wc.previewTextView.scroll(NSPoint(x: 0, y: scrollY))
                wc.previewTextView.window?.display()
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
    if args.contains("--ctx-dump") {
        let app2 = NSApplication.shared
        app2.setActivationPolicy(.accessory)
        let wc = EditorWindowController()
        func dump(_ m: NSMenu, _ depth: Int) {
            for it in m.items {
                let t = it.isSeparatorItem ? "---" : it.title
                let key = it.keyEquivalent.isEmpty ? "" : " [\(it.keyEquivalentModifierMask.rawValue)\(it.keyEquivalent)]"
                let tag = it.tag != 0 ? " tag=\(it.tag)" : ""
                print(String(repeating: "  ", count: depth) + "- " + t + key + tag)
            }
        }
        print("EDITOR-CTX:")
        dump(wc.ctxMenuForTesting(true), 1)
        print("PREVIEW-CTX:")
        dump(wc.ctxMenuForTesting(false), 1)
        FileHandle.standardError.write(Data("CTX-DONE\n".utf8))
        NSApp.terminate(nil)
        return true
    }
    if args.contains("--menu-dump") {
        // 调试：构建主菜单后打印结构，用于验证菜单汉化与查找/替换项
        let app2 = NSApplication.shared
        app2.setActivationPolicy(.accessory)
        let d = AppDelegate()
        d.buildMainMenuForTesting()
        func dump(_ m: NSMenu, _ depth: Int) {
            for it in m.items {
                let t = it.isSeparatorItem ? "---" : it.title
                let key = it.keyEquivalent.isEmpty ? "" : " [\(it.keyEquivalentModifierMask.rawValue)\(it.keyEquivalent)]"
                print(String(repeating: "  ", count: depth) + "- " + t + key)
                if let sub = it.submenu { dump(sub, depth + 1) }
            }
        }
        dump(NSApp.mainMenu ?? NSMenu(), 0)
        FileHandle.standardError.write(Data("MENU-DUMP-DONE\n".utf8))
        NSApp.terminate(nil)
        return true
    }
    if args.contains("--bgpanel") {
        // 调试：打开「背景设置」面板，截图后退出
        let outPath = args.first { !$0.hasPrefix("-") && $0.hasSuffix(".png") } ?? "/tmp/nmd-test/bgpanel.png"
        let app2 = NSApplication.shared
        app2.setActivationPolicy(.accessory)
        let wc = EditorWindowController()
        if let bgPath = ProcessInfo.processInfo.environment["NMD_BG"],
           let img = NSImage(contentsOfFile: bgPath) {
            let alpha = (ProcessInfo.processInfo.environment["NMD_BG_ALPHA"].flatMap(Double.init)) ?? 1
            BackgroundOverlay.shared.image = img
            BackgroundOverlay.shared.alpha = CGFloat(alpha)
        }
        wc.showBackgroundMenuForTesting()
        let timer = Timer(timeInterval: 1.5, repeats: false) { _ in
            if let panel = wc.bgSettingsWindowForTesting, let cv = panel.contentView {
                cv.displayIfNeeded()
                if let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
                    cv.cacheDisplay(in: cv.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: outPath))
                    }
                }
            }
            NSApp.terminate(nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        app2.run()
        return true
    }
    if args.contains("--confirm-dlg") {
        // 调试：未保存内容点「打开备忘录」时弹出确认框，截图弹窗后退出
        let outPath = args.contains("--confirm-dlg") ?
            (args.first { !$0.hasPrefix("-") && $0.hasSuffix(".png") }) ?? "/tmp/nmd-test/confirm.png" : "/tmp/nmd-test/confirm.png"
        let app2 = NSApplication.shared
        app2.setActivationPolicy(.accessory)
        let wc = EditorWindowController()
        wc.window?.makeKeyAndOrderFront(nil)
        wc.setTextForTesting("未保存的测试内容，加载前应先确认")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            wc.pickNoteToBind()
        }
        let timer = Timer(timeInterval: 2.8, repeats: false) { _ in
            for w in NSApp.windows where w.isVisible && w != wc.window {
                guard let cv = w.contentView else { continue }
                let first = cv.subviews.first
                let isAlert = (first as? NSImageView) != nil
                FileHandle.standardError.write(Data("CAND: \(type(of: w)) frame=\(w.frame) alert=\(isAlert)\n".utf8))
                if isAlert {
                    cv.displayIfNeeded()
                    if let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
                        cv.cacheDisplay(in: cv.bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: outPath))
                            FileHandle.standardError.write(Data("SAVED: \(outPath)\n".utf8))
                        }
                    }
                }
            }
            NSApp.terminate(nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        app2.run()
        return true
    }
    if let idx = args.firstIndex(of: "--close-test"), idx + 1 < args.count {
        let path = args[idx + 1]
        let outPath = (idx + 2 < args.count) ? args[idx + 2] : "/tmp/nmd-test/close-test.png"
        let env = ProcessInfo.processInfo.environment
        let app2 = NSApplication.shared
        app2.setActivationPolicy(.accessory)
        let d = AppDelegate()
        d.skipLaunchSetupForTesting = true
        app2.delegate = d
        let wc = EditorWindowController()
        d.attachEditorForTesting(wc)
        wc.window?.makeKeyAndOrderFront(nil)
        if env["NMD_NOFILE"] == "1" {
            // 新建md：无文件关联
            wc.setFileURLForTesting(nil)
            wc.setTextForTesting("新建md测试内容")
        } else {
            wc.loadFile(URL(fileURLWithPath: path))
        }
        if env["NMD_MODE"] == "note" { wc.setModeForTesting(.note) }
        if env["NMD_PUSHED"] == "1" { wc.setPushedForTesting(true) }
        if env["NMD_AUTOSAVE"] == "1" { wc.setAutoSaveForTesting(true) }
        if env["NMD_EDIT"] == "1" {
            wc.simulateUserEdit(append: "\n\n自动保存测试\n")
        }
        FileHandle.standardError.write(Data("LOADED: file=\(wc.filePathForTest ?? "nil") dirty=\(wc.isDirtyForTest) mode=\(env["NMD_MODE"] ?? "md")\n".utf8))
        guard let win = wc.window else { FileHandle.standardError.write(Data("NO WIN\n".utf8)); app2.run(); return true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if env["NMD_QUIT"] == "1" {
                FileHandle.standardError.write(Data("CALL-TERM\n".utf8))
                NSApp.terminate(nil)
            } else {
                win.performClose(nil)
            }
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
            FileHandle.standardError.write(Data("RESULT: windowVisible=\(wc.window?.isVisible ?? false)\n".utf8))
            exit(0)
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
    if let idx = args.firstIndex(of: "--pixhost-upload"), idx + 1 < args.count {
        // 调试/脚本：上传一张图片到 pixhost，打印链接信息并写入历史
        let path = args[idx + 1]
        let app2 = NSApplication.shared
        app2.setActivationPolicy(.accessory)
        var done = false
        PixhostAPI.upload(fileURL: URL(fileURLWithPath: path)) { result in
            switch result {
            case .success(let img):
                PixHistory.add(img)
                print("direct=", img.direct)
                print("show=", img.show)
                print("thumb=", img.thumb)
                print("manage=", img.manage ?? "nil")
            case .failure(let e):
                FileHandle.standardError.write(Data("upload failed: \(e.localizedDescription)\n".utf8))
            }
            done = true
        }
        let deadline = Date().addingTimeInterval(120)
        while !done && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return true
    }
    if let idx = args.firstIndex(of: "--note-update"), idx + 2 < args.count {
        // 调试/脚本：把 markdown 文件内容更新进指定 id 的已有备忘录
        let id = args[idx + 1]
        let path = args[idx + 2]
        guard let md = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write(Data("读取文件失败\n".utf8))
            return true
        }
        let html = MarkdownRenderer.html(from: md)
        switch NotesService.updateNote(id: id, html: html) {
        case .success: print("updateNote=OK")
        case .failure(let e): print("updateNote=ERR", e.localizedDescription)
        }
        return true
    }
    if let idx = args.firstIndex(of: "--note-md"), idx + 1 < args.count {
        // 调试/脚本：读取指定 id 的备忘录正文，转成 Markdown 后输出；
        // 有推送缓存时与 GUI「打开备忘录」一致地恢复表格列对齐
        switch NotesService.noteHTML(id: args[idx + 1]) {
        case .success(let html):
            var md = MarkdownFromHTML.convert(html)
            if let cached = NotePushCache.markdown(for: args[idx + 1]) {
                md = MarkdownFromHTML.restoreTableAlignments(md, from: cached)
            }
            print(md)
        case .failure(let e):
            FileHandle.standardError.write(Data("noteHTML=ERR \(e.localizedDescription)\n".utf8))
        }
        return true
    }
    if let idx = args.firstIndex(of: "--push-cache"), idx + 2 < args.count {
        // 调试/脚本：为指定 note id 写入推送缓存（模拟软件最近一次写入的内容）
        let md = (try? String(contentsOfFile: args[idx + 2], encoding: .utf8)) ?? ""
        NotePushCache.store(md, noteID: args[idx + 1])
        FileHandle.standardError.write(Data("CACHED \(args[idx + 1]) bytes=\(md.count)\n".utf8))
        return true
    }
    if args.contains("--note-list") {
        switch NotesService.listNotes() {
        case .success(let notes):
            print("notes=", notes.count)
            for n in notes.prefix(10) { print(n.id, "|", n.name) }
        case .failure(let e):
            FileHandle.standardError.write(Data("listNotes=ERR \(e.localizedDescription)\n".utf8))
        }
        return true
    }
    if let idx = args.firstIndex(of: "--pix-result-sheet"), idx + 1 < args.count {
        // 调试：用最近的历史记录渲染上传结果 sheet 成 PNG 后退出
        let outPath = args[idx + 1]
        let app2 = NSApplication.shared
        app2.setActivationPolicy(.accessory)
        let items = Array(PixHistory.load().prefix(3))
            .map { Result.success($0) as Result<PixImage, Error> }
        let sheetObj = PixResultSheet(results: items) { _ in }
        let sheetView = sheetObj.makeView()
        let win = NSWindow(contentRect: sheetView.frame, styleMask: [.titled],
                           backing: .buffered, defer: false)
        win.contentView = sheetView
        win.center()
        win.makeKeyAndOrderFront(nil)
        Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            if let content = win.contentView {
                content.displayIfNeeded()
                if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: outPath))
                    }
                }
            }
            NSApp.terminate(nil)
        }
        app2.run()
        return true
    }
    if args.contains("--note-picker") {
        // 调试：打开笔记选择窗口；带参数时渲染成 PNG 后退出
        let outPath = args.contains("--note-picker") ?
            (args.first { !$0.hasPrefix("-") && $0.hasSuffix(".png") }) ?? "" : ""
        let app2 = NSApplication.shared
        app2.setActivationPolicy(.accessory)
        let wc = NotePickerWindowController()
        if let bgPath = ProcessInfo.processInfo.environment["NMD_BG"],
           let img = NSImage(contentsOfFile: bgPath) {
            let alpha = (ProcessInfo.processInfo.environment["NMD_BG_ALPHA"].flatMap(Double.init)) ?? 1
            BackgroundOverlay.shared.image = img
            BackgroundOverlay.shared.alpha = CGFloat(alpha)
        }
        wc.showWindowAndLoad()
        wc.onPick = { id, name in
            FileHandle.standardError.write(Data("PICKED \(id) \(name)\n".utf8))
        }
        if ProcessInfo.processInfo.environment["NMD_MOCK"] == "1" {
            let mock = (1...8).map { i in
                NotePickerWindowController.NoteRef(id: "mock-\(i)", name: "备忘录标题 \(i) — 用于键盘导航测试")
            }
            let sel = ProcessInfo.processInfo.environment["NMD_SELECT"].flatMap(Int.init) ?? 0
            wc.setMockNotes(mock, select: sel)
        }
        // NMD_KEYS=125,125,36：截图前依次发送按键（125 下 / 126 上 / 123 左 / 124 右 / 36 回车）
        if let keys = ProcessInfo.processInfo.environment["NMD_KEYS"], !keys.isEmpty {
            let codes = keys.split(separator: ",").compactMap { Int($0) }
            let gap = ProcessInfo.processInfo.environment["NMD_KEYS_GAP"].flatMap(Double.init) ?? 0.6
            let focus = ProcessInfo.processInfo.environment["NMD_FOCUS_SEARCH"] == "1"
            for (i, code) in codes.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2 + Double(i) * gap) {
                    if focus { wc.focusSearchAndSendKey(code) } else { wc.invokeKey(code) }
                }
            }
            if focus {
                let last = codes.last ?? 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0 + Double(codes.count) * gap) {
                    FileHandle.standardError.write(Data("SELIDX \(wc.selectedIndexForTest)\n".utf8))
                    _ = last
                }
            }
        }
        let shotWait = ProcessInfo.processInfo.environment["NMD_SHOT_WAIT"].flatMap(Double.init) ?? 8
        Timer.scheduledTimer(withTimeInterval: shotWait, repeats: false) { _ in
            if !outPath.isEmpty, let content = wc.window?.contentView {
                content.displayIfNeeded()
                if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: outPath))
                    }
                }
            }
            NSApp.terminate(nil)
        }
        app2.run()
        return true
    }
    if let idx = args.firstIndex(of: "--pixhistory") {
        // 调试：打开历史图片窗口（仅卡片模式）；带参数时把窗口渲染成 PNG 后退出
        //   --pixhistory [out.png]
        let outPath = idx + 1 < args.count && !args[idx + 1].hasPrefix("-") ? args[idx + 1] : ""
        let app2 = NSApplication.shared
        app2.setActivationPolicy(.accessory)
        let wc = PixHistoryWindowController()
        wc.window?.center()
        wc.showWindowAndReload()
        NSApp.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in
            if !outPath.isEmpty, let content = wc.window?.contentView {
                content.displayIfNeeded()
                if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: outPath))
                    }
                }
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
            let inPath = (args[idx + 1] as NSString).expandingTildeInPath
            let inURL = URL(fileURLWithPath: inPath)
            ImageStore.baseDirectory = (inURL.isFileURL && inURL.path.hasPrefix("/"))
                ? inURL.deletingLastPathComponent()
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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
