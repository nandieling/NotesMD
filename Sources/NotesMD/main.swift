import AppKit
import Carbon.HIToolbox

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
    1. 新建备忘录：生成一条原生排版的备忘录
    2. 粘贴到当前备忘录：对已打开的笔记直接 ⌘V
    3. 复制富文本：自行选择粘贴位置

    ---
    全局快捷键：⌥⌘M 打开 / 隐藏窗口
    """
}

// MARK: - 主窗口

final class EditorWindowController: NSWindowController, NSTextViewDelegate, NSWindowDelegate {
    private var editorTextView: NSTextView!
    private var previewTextView: NSTextView!
    private var titleField: NSTextField!
    private var statusLabel: NSTextField!
    private var updateWorkItem: DispatchWorkItem?
    private var statusClearWork: DispatchWorkItem?

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
    }

    private func buildViews() {
        guard let content = window?.contentView else { return }

        // 底部操作栏
        let bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: content.bounds.width, height: 48))
        bottomBar.autoresizingMask = [.width]

        let createButton = makeButton("新建备忘录", action: #selector(createNote))
        createButton.keyEquivalent = "r"
        let pasteButton = makeButton("粘贴到当前备忘录", action: #selector(pasteToNotes))
        pasteButton.keyEquivalent = "v"
        pasteButton.keyEquivalentModifierMask = [.command, .shift]
        let copyButton = makeButton("复制富文本", action: #selector(copyRich))
        copyButton.keyEquivalent = "c"
        copyButton.keyEquivalentModifierMask = [.command, .shift]

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let bar = NSStackView(views: [createButton, pasteButton, copyButton, statusLabel])
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
        NSLayoutConstraint.activate([
            titleHint.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 14),
            titleHint.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: titleHint.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleField.widthAnchor.constraint(equalToConstant: 320)
        ])
        content.addSubview(topBar)

        // 中间：左编辑 右预览
        let split = NSSplitView(frame: NSRect(x: 0, y: 48,
                                              width: content.bounds.width,
                                              height: content.bounds.height - 48 - 36))
        split.autoresizingMask = [.width, .height]
        split.isVertical = true
        split.dividerStyle = .thin

        let editorScroll = makeScroll()
        editorTextView = makeTextView()
        editorTextView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        editorTextView.delegate = self
        editorTextView.string = Sample.markdown
        editorScroll.documentView = editorTextView

        let previewScroll = makeScroll()
        previewTextView = makeTextView()
        previewTextView.isEditable = false
        previewTextView.isSelectable = true
        previewScroll.documentView = previewTextView

        split.addArrangedSubview(editorScroll)
        split.addArrangedSubview(previewScroll)
        split.setPosition(split.bounds.width * 0.46, ofDividerAt: 0)
        content.addSubview(split)

        refreshPreview()
    }

    private func makeScroll() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    private func makeTextView() -> NSTextView {
        let tv = NSTextView()
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
        updateWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshPreview() }
        updateWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func refreshPreview() {
        let html = MarkdownRenderer.html(from: editorTextView.string)
        previewTextView.textStorage?.setAttributedString(MarkdownRenderer.attributed(fromHTML: html))
        previewTextView.scrollToBeginningOfDocument(nil)
    }

    // MARK: - 操作

    private var currentHTML: String { MarkdownRenderer.html(from: editorTextView.string) }

    private var currentTitle: String {
        let t = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return MarkdownRenderer.deriveTitle(from: editorTextView.string) ?? "未命名备忘录"
    }

    @objc func createNote() {
        let html = currentHTML
        let title = currentTitle
        setStatus("正在写入备忘录…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NotesService.createNote(title: title, html: html)
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.setStatus("已创建备忘录「\(title)」")
                case .failure(let error):
                    self.setStatus("创建失败：\(error.localizedDescription)")
                }
            }
        }
    }

    @objc func pasteToNotes() {
        NotesService.copyRich(html: currentHTML)
        NotesService.pasteIntoNotes()
        setStatus("已复制并尝试粘贴到备忘录（若未生效，请在备忘录中按 ⌘V）")
    }

    @objc func copyRich() {
        NotesService.copyRich(html: currentHTML)
        setStatus("已复制富文本，到备忘录中按 ⌘V 粘贴")
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
        setupStatusItem()
        buildMainMenu()
        Hotkey.register()
        showWindow()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "NotesMD") {
                button.image = image
            } else {
                button.title = "MD"
            }
        }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "显示 / 隐藏编辑器  (⌥⌘M)", action: #selector(toggleWindow), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        for item in [
            NSMenuItem(title: "新建备忘录", action: #selector(editorCreateNote), keyEquivalent: ""),
            NSMenuItem(title: "粘贴到当前备忘录", action: #selector(editorPasteToNotes), keyEquivalent: ""),
            NSMenuItem(title: "复制富文本", action: #selector(editorCopyRich), keyEquivalent: "")
        ] {
            item.target = self
            menu.addItem(item)
        }
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
        let newItem = NSMenuItem(title: "新建备忘录", action: #selector(editorCreateNote), keyEquivalent: "r")
        newItem.target = self
        fileMenu.addItem(newItem)
        let pasteItem = NSMenuItem(title: "粘贴到当前备忘录", action: #selector(editorPasteToNotes), keyEquivalent: "V")
        pasteItem.target = self
        pasteItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(pasteItem)
        let copyItem = NSMenuItem(title: "复制富文本", action: #selector(editorCopyRich), keyEquivalent: "C")
        copyItem.target = self
        copyItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(copyItem)

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

    @objc func editorCreateNote() { editor?.createNote() }
    @objc func editorPasteToNotes() { editor?.pasteToNotes() }
    @objc func editorCopyRich() { editor?.copyRich() }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - CLI（便于脚本与验证）
//   NotesMD --html <file>   输出该 markdown 文件的 HTML
//   NotesMD --png <file>    把示例内容渲染为 PNG

func runCLI() -> Bool {
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--html"), idx + 1 < args.count {
        guard let md = try? String(contentsOfFile: args[idx + 1], encoding: .utf8) else {
            FileHandle.standardError.write(Data("读取文件失败\n".utf8))
            return true
        }
        print(MarkdownRenderer.html(from: md))
        return true
    }
    if let idx = args.firstIndex(of: "--png"), idx + 1 < args.count {
        let html = MarkdownRenderer.html(from: Sample.markdown)
        let attr = MarkdownRenderer.attributed(fromHTML: html)
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
           let png = rep.representation(using: .png, properties: [:]) {
            do {
                try png.write(to: URL(fileURLWithPath: args[idx + 1]))
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
    app.setActivationPolicy(.accessory)
    app.run()
}
