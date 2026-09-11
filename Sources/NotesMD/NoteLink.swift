import AppKit
import Foundation

// MARK: - 备忘录关联（把编辑内容与某条已有备忘录绑定，随时整体更新）

enum NoteBinding {
    private static let idKey = "notesmd.boundNoteID"
    private static let nameKey = "notesmd.boundNoteName"

    static var id: String? {
        get { UserDefaults.standard.string(forKey: idKey) }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: idKey) }
            else { UserDefaults.standard.removeObject(forKey: idKey) }
        }
    }

    static var name: String? {
        get { UserDefaults.standard.string(forKey: nameKey) }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: nameKey) }
            else { UserDefaults.standard.removeObject(forKey: nameKey) }
        }
    }

    static func bind(id: String, name: String) {
        self.id = id
        self.name = name
    }

    static func unbind() {
        id = nil
        name = nil
    }
}

// MARK: - 推送备忘录内容缓存（读回时恢复表格列对齐）

/// Notes 读回的 HTML 会丢失表格列对齐（align / text-align 均不保留，实测确认），
/// 而备忘录里居中表格的视觉效果还在。本软件写入 markdown 时按 note id 记住
/// 最后一次写入的内容；「打开备忘录」读回后据此恢复各表格的 :---: / ---: 对齐行。
enum NotePushCache {
    private static let key = "notesmd.pushedMarkdown"

    static func store(_ markdown: String, noteID: String) {
        guard !markdown.isEmpty else { return }
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        map[noteID] = markdown
        UserDefaults.standard.set(map, forKey: key)
    }

    static func markdown(for noteID: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[noteID]
    }
}

// MARK: - 笔记选择窗口

/// 支持把方向键/回车交给控制器处理的选择窗口
final class PickerKeyWindow: NSWindow {
    var onKeyHandler: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKeyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// 搜索框的 field editor：编辑焦点在搜索框里时，方向键/回车仍走卡片导航
final class PickerFieldEditor: NSTextView {
    var onNavigate: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        let nav: Set<UInt16> = [123, 124, 125, 126, 36, 76]  // ← → ↓ ↑ 回车 小键盘回车
        if nav.contains(event.keyCode), onNavigate?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// 搜索框：处于第一响应者时方向键/回车也优先用于切换/打开备忘录
final class PickerSearchField: NSTextField {
    var onNavigate: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        let nav: Set<UInt16> = [123, 124, 125, 126, 36, 76]  // ← → ↓ ↑ 回车 小键盘回车
        if nav.contains(event.keyCode), onNavigate?(event) == true { return }
        super.keyDown(with: event)
    }
}

final class NotePickerWindowController: NSWindowController, NSWindowDelegate,
                                        NSTextFieldDelegate {

    struct NoteRef {
        let id: String
        let name: String
    }

    var onPick: ((_ id: String, _ name: String) -> Void)?

    private var all: [NoteRef] = []
    private var filtered: [NoteRef] = []
    private var loading = false
    private var cardScroll: NSScrollView!
    private var searchField: NSTextField!
    private var refreshButton: NSButton!
    private var statusLabel: NSTextField!
    private var emptyLabel: NSTextField!
    /// 当前选中项（列表/卡片共用；方向键切换、回车打开）
    private var selectedIndex: Int = 0
    private var cardCols: Int = 1

    convenience init() {
        let win = PickerKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                                  styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
        win.title = "打开备忘录"
        win.minSize = NSSize(width: 400, height: 300)
        win.center()
        self.init(window: win)
        win.delegate = self
        win.onKeyHandler = { [weak self] event in
            self?.handleKey(event) ?? false
        }
        build()
    }

    // MARK: - 键盘导航（方向键切换，回车打开）

    /// 当前网格列数：与 makeCardDoc 用同一宽度公式实时计算，
    /// 保证方向键步长与屏幕上的网格一致（不依赖上一次重建时的缓存值）。
    /// 布局未完成时回退到窗口宽度（cardScroll 左右各留 10pt）
    private var currentCols: Int {
        var w = cardScroll.contentSize.width
        if w <= 0, let cw = window?.contentView?.bounds.width { w = cw - 20 }
        let width = max(w, 320)
        let cardW: CGFloat = 158, spacing: CGFloat = 10
        return max(1, Int((width - 8 + spacing) / (cardW + spacing)))
    }

    @discardableResult
    private func handleKey(_ event: NSEvent) -> Bool {
        guard !filtered.isEmpty else { return false }
        let down: Int? = event.keyCode == 125 ? currentCols : nil    // 下：同列下一行
        let up: Int? = event.keyCode == 126 ? -currentCols : nil     // 上：同列上一行
        let left: Int? = event.keyCode == 123 ? -1 : nil             // 左：同行上一张
        let right: Int? = event.keyCode == 124 ? 1 : nil             // 右：同行下一张
        if event.keyCode == 36 {          // 回车（主键盘）
            pickSelected()
            return true
        }
        if event.keyCode == 76 {          // 小键盘回车
            pickSelected()
            return true
        }
        if let d = (right ?? left ?? down ?? up) {
            moveSelection(by: d)
            return true
        }
        return false
    }

    private func moveSelection(by delta: Int) {
        let n = filtered.count
        guard n > 0 else { return }
        let target = min(max(selectedIndex + delta, 0), n - 1)
        guard target != selectedIndex else { return }
        selectedIndex = target
        rebuildCards()
    }

    func showWindowAndLoad() {
        // 弹窗关闭时背景视图会被自动移除，重新显示时补挂（已挂则复用）
        if let content = window?.contentView {
            _ = BackgroundOverlay.shared.attach(to: content)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 每次打开都重新读取，保证软件启动后新建的备忘录能显示出来
        load()
    }

    // 读取备忘录时 osascript 会把「备忘录」App 带到前台；
    // 结果返回后本窗口重新成为 key，再激活应用，实现选择后自动跳回
    func windowDidBecomeKey(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private var navFieldEditor: PickerFieldEditor?

    // 搜索框进入编辑状态时，系统创建 field editor 处理按键；
    // 返回导航感知的实例，方向键/回车就不会被用来移动光标。
    // client 为 nil 表示 field editor 自身在询问，同样必须返回导航实例，
    // 否则 AppKit 会换成默认 NSTextView，方向键就只移动光标、切不了卡片
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        if client != nil, !(client is PickerSearchField) { return nil }
        let fe = navFieldEditor ?? PickerFieldEditor()
        navFieldEditor = fe
        fe.onNavigate = { [weak self] e in self?.handleKey(e) ?? false }
        return fe
    }

    private func build() {
        guard let content = window?.contentView else { return }
        // 弹窗自身也铺背景图（跟随主窗口设置）
        _ = BackgroundOverlay.shared.attach(to: content)

        let sf = PickerSearchField(string: "")
        sf.placeholderString = "搜索备忘录标题…（↑↓←→ 切换，回车打开）"
        sf.font = NSFont.systemFont(ofSize: 13)
        sf.translatesAutoresizingMaskIntoConstraints = false
        sf.delegate = self
        // 注意：不要设置 action —— 编辑结束时系统会自动触发 action，
        // 会在卡片被点击前就按当前选中项关闭窗口；回车/方向键由 keyDown 拦截处理
        sf.onNavigate = { [weak self] event in self?.handleKey(event) ?? false }
        searchField = sf
        content.addSubview(searchField)

        // 刷新按钮：就地重读笔记列表，无需关闭弹窗
        let refreshBtn = NSButton(title: "刷新", target: self, action: #selector(refresh))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.controlSize = .small
        refreshBtn.toolTip = "刷新备忘录列表"
        if let img = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新") {
            refreshBtn.image = img
            refreshBtn.imagePosition = .imageOnly
        }
        refreshBtn.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(refreshBtn)
        refreshButton = refreshBtn

        // 卡片网格
        cardScroll = NSScrollView()
        cardScroll.translatesAutoresizingMaskIntoConstraints = false
        cardScroll.hasVerticalScroller = true
        cardScroll.autohidesScrollers = true
        cardScroll.borderType = .noBorder
        cardScroll.drawsBackground = false
        content.addSubview(cardScroll)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)

        emptyLabel = NSTextField(labelWithString: "")
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        content.addSubview(emptyLabel)

        let pickBtn = NSButton(title: "打开所选", target: self, action: #selector(pickSelected))
        pickBtn.bezelStyle = .rounded
        pickBtn.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pickBtn)

        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cancelBtn)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),
            refreshButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            refreshButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 34),

            cardScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            cardScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            cardScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            cardScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -56),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: cardScroll.centerYAnchor),

            pickBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            pickBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            pickBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),

            cancelBtn.trailingAnchor.constraint(equalTo: pickBtn.leadingAnchor, constant: -8),
            cancelBtn.centerYAnchor.constraint(equalTo: pickBtn.centerYAnchor),
            cancelBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])
    }

    /// 测试用：注入 mock 数据（跳过 osascript）
    func setMockNotes(_ refs: [NoteRef], select: Int = 0) {
        all = refs
        selectedIndex = min(max(select, 0), max(refs.count - 1, 0))
        applyFilter()
    }

    /// 测试用：模拟一个方向键/回车事件（CGEvent 发送）
    func sendTestKey(_ keyCode: Int) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let d = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true)!
        let u = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false)!
        d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
    }

    /// 测试用：直接向键盘处理器发事件（不依赖 CGEvent 路由）
    func invokeKey(_ keyCode: Int) {
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window?.windowNumber ?? 0, context: nil,
                                    characters: " ", charactersIgnoringModifiers: " ",
                                    isARepeat: false, keyCode: CGKeyCode(keyCode)) {
            _ = handleKey(e)
        }
    }

    /// 测试用：把搜索框设为第一响应者（激活 field editor），再发一次按键，
    /// 验证「搜索框聚焦时方向键仍切换卡片」。
    /// 按键经 NSWindow.sendEvent 走完整响应链（window → field editor），
    /// 与真实键盘事件的路径一致
    func focusSearchAndSendKey(_ keyCode: Int) {
        window?.makeFirstResponder(searchField)
        // 激活编辑：让 field editor 成为真正的第一响应者
        searchField.selectText(nil)
        let first = type(of: window?.firstResponder as Any)
        FileHandle.standardError.write(Data("FIRSTRESPONDER \(String(describing: first))\n".utf8))
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window?.windowNumber ?? 0, context: nil,
                                       characters: " ", charactersIgnoringModifiers: " ",
                                       isARepeat: false, keyCode: CGKeyCode(keyCode)) else { return }
        window?.sendEvent(e)
    }

    var selectedIndexForTest: Int { selectedIndex }

    // MARK: - 数据

    private func load() {
        loading = true
        refreshButton.isEnabled = false
        statusLabel.stringValue = "正在读取备忘录…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NotesService.listNotes()
            DispatchQueue.main.async {
                guard self.loading else { return }
                self.loading = false
                self.refreshButton.isEnabled = true
                switch result {
                case .success(let notes):
                    self.all = notes.map {
                        NoteRef(id: $0.id, name: $0.name.isEmpty ? "（无标题）" : $0.name)
                    }
                    self.statusLabel.stringValue = "共 \(self.all.count) 条备忘录"
                    self.applyFilter()
                case .failure(let e):
                    self.statusLabel.stringValue = "读取失败：\(e.localizedDescription)"
                    self.statusLabel.textColor = .systemRed
                    self.emptyLabel.stringValue = "读取备忘录失败"
                    self.emptyLabel.isHidden = false
                }
            }
        }
    }

    private func applyFilter() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        filtered = q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
        rebuildCards()
        emptyLabel.isHidden = !filtered.isEmpty
        if filtered.isEmpty {
            emptyLabel.stringValue = all.isEmpty ? "没有找到备忘录" : "没有匹配的备忘录"
        }
        if selectedIndex < 0 || selectedIndex >= filtered.count {
            selectedIndex = 0
        }
        scrollSelectedIntoView()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    @objc private func pickSelected() {
        guard selectedIndex >= 0, selectedIndex < filtered.count else {
            statusLabel.stringValue = "请先选择一条备忘录"
            return
        }
        let ref = filtered[selectedIndex]
        onPick?(ref.id, ref.name)
        DispatchQueue.main.async { [weak self] in self?.window?.close() }
    }

    @objc private func cancel() {
        window?.close()
    }

    /// 手动刷新笔记列表（弹窗每次打开时也会自动重读）
    @objc private func refresh() {
        guard !loading else { return }
        load()
    }

    // MARK: - 卡片模式

    private func rebuildCards() {
        let w = max(cardScroll.contentSize.width, 320)
        let h = max(cardScroll.contentSize.height, 200)
        cardScroll.documentView = makeCardDoc(width: w, viewportH: h)
        scrollSelectedIntoView()
    }

    // 窗口缩放后按新宽度重排卡片网格
    func windowDidResize(_ notification: Notification) {
        rebuildCards()
    }

    /// 卡片底色：半透明 + 毛玻璃，让背景图与透明度设置能透出；
    /// 深色模式下自动变深，文字对比度不受影响
    private func cardFillColor(selected: Bool) -> NSColor {
        if selected {
            return NSColor.controlAccentColor.withAlphaComponent(0.22)
        }
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return (dark ? NSColor.white : NSColor.white)
                .withAlphaComponent(dark ? 0.12 : 0.55)
        }
    }

    private func makeCardDoc(width: CGFloat, viewportH: CGFloat) -> NSView {
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: max(viewportH, 10)))
        guard !filtered.isEmpty else { return doc }
        let cardW: CGFloat = 158, cardH: CGFloat = 96, spacing: CGFloat = 10
        let cols = max(1, Int((width - 8 + spacing) / (cardW + spacing)))
        cardCols = cols
        for (i, ref) in filtered.enumerated() {
            let r = i / cols, c = i % cols
            let x = 4 + CGFloat(c) * (cardW + spacing)
            let y = 4 + CGFloat(r) * (cardH + spacing)
            let selected = (i == selectedIndex)
            let card = FlippedView(frame: NSRect(x: x, y: y, width: cardW, height: cardH))
            card.wantsLayer = true
            card.layer?.backgroundColor = cardFillColor(selected: selected).cgColor
            card.layer?.cornerRadius = 10
            card.layer?.borderColor = selected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.withAlphaComponent(0.6).cgColor
            card.layer?.borderWidth = selected ? 2 : 1
            card.layer?.shadowOpacity = 0
            if selected {
                card.layer?.shadowOpacity = 0.18
                card.layer?.shadowRadius = 6
                card.layer?.shadowOffset = CGSize(width: 0, height: -2)
            }

            let icon = NSImageView(frame: NSRect(x: 12, y: 12, width: 18, height: 18))
            icon.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
            icon.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            card.addSubview(icon)

            let title = NSTextField(labelWithString: ref.name)
            title.font = NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .medium)
            title.lineBreakMode = .byTruncatingTail
            title.frame = NSRect(x: 12, y: (cardH - 18) / 2, width: cardW - 24, height: 18)
            title.toolTip = ref.name
            card.addSubview(title)

            let click = NSClickGestureRecognizer(target: self, action: #selector(cardClicked(_:)))
            click.numberOfClicksRequired = 1
            card.addGestureRecognizer(click)
            cardNote[ObjectIdentifier(card)] = ref
            doc.addSubview(card)
        }
        let rowCount = (filtered.count + cols - 1) / cols
        doc.frame = NSRect(x: 0, y: 0, width: width,
                           height: max(CGFloat(rowCount) * (cardH + spacing) + 8, viewportH))
        return doc
    }

    private var cardNote: [ObjectIdentifier: NoteRef] = [:]

    @objc private func cardClicked(_ g: NSClickGestureRecognizer) {
        guard let card = g.view, let ref = cardNote[ObjectIdentifier(card)] else { return }
        onPick?(ref.id, ref.name)
        DispatchQueue.main.async { [weak self] in self?.window?.close() }
    }

    // MARK: - 选中滚动

    /// 选中卡片超出可视区域时，滚动弹窗内容使其可见（居中）
    private func scrollSelectedIntoView() {
        guard let doc = cardScroll.documentView, !filtered.isEmpty,
              selectedIndex < filtered.count else { return }
        let cardH: CGFloat = 96, spacing: CGFloat = 10
        let r = selectedIndex / cardCols
        let cardTop = 4 + CGFloat(r) * (cardH + spacing)
        let viewport = cardScroll.contentView.bounds
        guard cardTop < viewport.minY || cardTop + cardH > viewport.maxY else { return }
        let targetY = max(0, cardTop + cardH / 2 - viewport.height / 2)
        cardScroll.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        cardScroll.reflectScrolledClipView(cardScroll.contentView)
    }
}
