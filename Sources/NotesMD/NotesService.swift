import AppKit
import ApplicationServices
import Foundation

/// 与 Apple 备忘录（Notes.app）交互的服务层。
enum NotesService {

    static let notesBundleID = "com.apple.Notes"

    /// 在备忘录中创建一条新笔记（HTML 正文由 Notes 自行排版），返回新笔记的 id。
    /// 不显式设置 name：Notes 会把正文首行（H1 标题）渲染为加粗大标题并用作笔记名，
    /// 显式 name 则是普通字重且会与正文标题重复（两个主标题）。
    @discardableResult
    static func createNote(html: String) -> Result<String, Error> {
        let script = """
        on run argv
            set theHTML to item 1 of argv
            tell application "Notes"
                set theNote to make new note with properties {body:theHTML}
                return id of theNote
            end tell
        end run
        """
        return runAppleScript(script, args: [html])
    }

    /// 按 note id 更新已有笔记的正文（关联修改）。笔记不存在时返回失败。
    @discardableResult
    static func updateNote(id: String, html: String) -> Result<Void, Error> {
        let script = """
        on run argv
            set theID to item 1 of argv
            set theHTML to item 2 of argv
            tell application "Notes"
                set allNotes to notes
                repeat with n in allNotes
                    if id of n is theID then
                        try
                            set body of n to theHTML
                            return "ok"
                        end try
                        return "immutable"
                    end if
                end repeat
            end tell
            return "notfound"
        end run
        """
        switch runAppleScript(script, args: [id, html]) {
        case .success(let out):
            if out == "ok" { return .success(()) }
            let msg = out == "immutable"
                ? "该备忘录在「最近删除」中，无法更新，请先在备忘录里恢复它"
                : "找不到该备忘录，它可能已被删除"
            return .failure(NSError(domain: "NotesMD", code: 4,
                                     userInfo: [NSLocalizedDescriptionKey: msg]))
        case .failure(let e):
            return .failure(e)
        }
    }

    /// 读取指定笔记的正文 HTML（用于「选择备忘录」后把内容转成 Markdown 装入编辑区）。
    /// 先按 id 直接引用（服务端过滤，笔记多时也快），失败再按账号/文件夹遍历兜底；
    /// 大正文（表格笔记可达数百 KB）需要更长的响应时间，超时按失败返回，
    /// 由调用方提示原因，避免把编辑区清空后还报「已打开」。
    static func noteHTML(id: String, timeout: TimeInterval = 30) -> Result<String, Error> {
        let script = """
        on run argv
            set theID to item 1 of argv
            tell application "Notes"
                try
                    set theBody to body of (first note whose id is theID)
                    if theBody is missing value then return ""
                    return theBody
                end try
                repeat with acc in accounts
                    repeat with fld in (folders of acc)
                        try
                            set theBody to body of (first note of fld whose id is theID)
                            if theBody is missing value then return ""
                            return theBody
                        end try
                    end repeat
                end repeat
            end tell
            return ""
        end run
        """
        switch runAppleScript(script, args: [id], timeout: timeout) {
        case .success(let out):
            if out.isEmpty {
                return .failure(NSError(domain: "NotesMD", code: 5,
                                        userInfo: [NSLocalizedDescriptionKey: "读不到该备忘录的正文（可能已被删除或在「最近删除」中）"]))
            }
            return .success(out)
        case .failure(let e):
            return .failure(e)
        }
    }

    /// 列出全部笔记（id + 标题），用于选择要关联的笔记
    static func listNotes() -> Result<[(id: String, name: String)], Error> {
        // 按账号/文件夹遍历，跳过「最近删除」（其中的笔记不可修改）
        let script = """
        on run
            set output to ""
            tell application "Notes"
                repeat with acc in accounts
                    repeat with fld in (folders of acc)
                        set theName to name of fld
                        if theName is not "Recently Deleted" and theName is not "最近删除" then
                            repeat with n in (notes of fld)
                                try
                                    set output to output & (id of n) & tab & (name of n) & linefeed
                                end try
                            end repeat
                        end if
                    end repeat
                end repeat
            end tell
            return output
        end run
        """
        return runAppleScript(script, args: []).map { out in
            out.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> (String, String)? in
                let str = String(line)
                guard let tab = str.firstIndex(of: "\t") else { return nil }
                let id = String(str[str.startIndex..<tab])
                let name = String(str[str.index(after: tab)...])
                guard !id.isEmpty else { return nil }
                return (id, name)
            }
        }
    }

    /// 把渲染结果（RTF + HTML + 纯文本）放入剪贴板，可用「编辑→粘贴」（或 ⌘V）进备忘录。
    /// preloadLocalImages 为 true 时先把 markdown 引用的本地图片同步读入缓存，
    /// 使剪贴板富文本携带真实图片数据（粘贴进备忘录时图片得以嵌入）。
    static func copyRich(markdown: String, preloadLocalImages: Bool = false) {
        if preloadLocalImages {
            MarkdownRenderer.preloadLocalImages(in: markdown)
        }
        let html = MarkdownRenderer.html(from: markdown)
        let pb = NSPasteboard.general
        pb.clearContents()
        let attr = MarkdownRenderer.render(markdown)
        pb.writeObjects([attr])
        if let data = html.data(using: .utf8) {
            pb.setData(data, forType: .html)
        }
    }

    /// 激活备忘录并点击「编辑→粘贴」菜单（AX 动作，不发送按键事件，
    /// 不触发 macOS 26+ 的「设备控制和数据访问」授权弹窗）。
    static func pasteIntoNotes() {
        guard canPasteIntoNotes else {
            _ = requestAXAccessIfNeeded()
            return
        }
        guard activateNotes(), notesWindowCount() != 0 else { return }
        _ = clickNotesMenu(pairs: [("粘贴", "编辑"), ("Paste", "Edit")])
    }

    // MARK: - 嵌入图片的笔记创建（菜单操作：文件→新建备忘录 + 编辑→粘贴）
    //
    // macOS 26+ 对 CGEvent 合成按键启用「设备控制和数据访问」权限，
    // 对 ad-hoc 签名应用容易反复弹窗且不生效。因此整个流程只用
    // AppleScript + AX 菜单点击，不发送任何键盘/鼠标事件：
    //   1. 显示→列表视图（幂等；画廊视图没有编辑器）
    //   2. 文件→新建备忘录：Notes 自动聚焦新笔记编辑器
    //      （0 窗口时会新开一个窗口，无需任何占位/临时笔记）
    //   3. 富文本写入剪贴板 → 编辑→粘贴（本地图片以附件形式嵌入）
    //   4. 读回正文校验；失败则清理空笔记并返回 nil（调用方回退纯 HTML）

    /// 是否有辅助功能权限（菜单点击与焦点读取由本进程直接走 AX 通道）
    static var canPasteIntoNotes: Bool { AXIsProcessTrusted() }

    /// 同一进程内只引导一次系统授权弹窗。授权没生效时（例如重新编译/签名导致
    /// TCC 记录与当前二进制不匹配），每次操作都弹窗只会反复打断用户；
    /// 未授权时创建流程会回退为纯 HTML 创建，并在状态栏说明原因。
    private static var didPromptForAXAccess = false

    /// 请求辅助功能权限：未授权时弹出系统对话框（带「打开系统设置」按钮，
    /// 直接定位到 隐私与安全性→辅助功能 列表）。返回当前是否已授权。
    @discardableResult
    static func requestAXAccessIfNeeded() -> Bool {
        if canPasteIntoNotes { return true }
        guard !didPromptForAXAccess else { return false }
        didPromptForAXAccess = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - 备忘录 UI 操作：本进程直接调用辅助功能 API
    //
    // 早先菜单点击/焦点读取是发 AppleScript 给 System Events 做的（UI 脚本）。
    // 那条路径需要 macOS 26+ 的「设备控制和数据访问」授权，而该授权按「发起控制的
    // 进程」归属：请求实际由 osascript/System Events 发出，授权记录难以稳定锚定到
    // NotesMD，于是每次「新建备忘录并粘贴」都重新弹窗，且勾选后仍不生效。
    // 现在改为在 NotesMD 进程内用 AXUIElement API 直接读备忘录的菜单树并执行
    // AXPress：不经过 System Events，不合成任何 HID 按键/鼠标事件，
    // 只需要「辅助功能」这一项按应用身份持久化的授权。

    /// 备忘录进程的 AX 元素（未运行时 nil）
    private static func notesAXApp() -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == notesBundleID }) else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private static func axRaw(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func axString(_ element: AXUIElement, _ name: String) -> String? {
        axRaw(element, name) as? String
    }

    private static func axElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = axRaw(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func axElements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = axRaw(element, name), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        // 逐项验类型再转换：数组里混入非元素对象时不至于崩溃
        return (value as! [AnyObject]).compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? unsafeBitCast(item, to: AXUIElement.self) : nil
        }
    }

    /// 备忘录当前打开的窗口数（AX 通道；读不到返回 nil 交由调用方回退）
    private static func axWindowCount() -> Int? {
        guard canPasteIntoNotes, let app = notesAXApp(),
              let value = axRaw(app, "AXWindows"), CFGetTypeID(value) == CFArrayGetTypeID()
        else { return nil }
        return (value as! [AXUIElement]).count
    }

    /// 备忘录当前聚焦元素（AX 通道）
    private static func axFocusedElement() -> AXUIElement? {
        guard canPasteIntoNotes, let app = notesAXApp() else { return nil }
        return axElement(app, "AXFocusedUIElement")
    }

    /// AX 点击备忘录菜单项：读 menu bar → 对应菜单 → 目标菜单项，执行 AXPress
    private static func clickNotesMenuAX(pairs: [(item: String, bar: String)]) -> Bool {
        guard canPasteIntoNotes, let app = notesAXApp(),
              let menuBar = axElement(app, "AXMenuBar") else { return false }
        for pair in pairs {
            guard let barItem = axElements(menuBar, "AXChildren")
                    .first(where: { axString($0, "AXTitle") == pair.bar }) else { continue }
            // 先确认目标菜单项存在，避免按下菜单栏项后没有东西可点、菜单悬着不收起
            let hasItem = axElements(barItem, "AXChildren").contains { menu in
                axElements(menu, "AXChildren").contains { axString($0, "AXTitle") == pair.item }
            }
            guard hasItem else { continue }
            // 备忘录的菜单项要等菜单处于展开状态才响应 AXPress：
            // 先按菜单栏项展开，再点目标项（实测直接点菜单项不会生效）
            _ = AXUIElementPerformAction(barItem, "AXPress" as CFString)
            for menu in axElements(barItem, "AXChildren") {
                for item in axElements(menu, "AXChildren") where axString(item, "AXTitle") == pair.item {
                    if AXUIElementPerformAction(item, "AXPress" as CFString) == .success { return true }
                }
            }
            // 没点中：再按一次菜单栏项，收起刚才展开的菜单
            _ = AXUIElementPerformAction(barItem, "AXPress" as CFString)
        }
        return false
    }

    /// 最近一次 createNoteByPasting 失败的原因（供状态栏提示；空字符串表示无需提示）
    static var lastPasteFailureHint: String = ""

    /// 通过「文件→新建备忘录 + 编辑→粘贴」（菜单点击、无按键事件）创建备忘录，
    /// 本地图片以附件形式嵌入。成功返回新笔记 id；失败返回 nil
    /// （调用方回退纯 HTML 的 createNote）。
    /// 流程会短暂把备忘录带到前台并操作其菜单。
    @discardableResult
    static func createNoteByPasting(markdown: String) -> String? {
        lastPasteFailureHint = ""
        if !canPasteIntoNotes {
            // 弹系统授权引导（「打开系统设置」按钮直达辅助功能列表）
            let grantedNow = requestAXAccessIfNeeded()
            if !grantedNow {
                lastPasteFailureHint = "未授予辅助功能权限（已在系统设置中引导添加）"
                return nil
            }
        }
        guard activateNotes() else {
            lastPasteFailureHint = "无法将备忘录带到前台"
            return nil
        }
        guard waitNotesProcessVisible(timeout: 15) else {
            lastPasteFailureHint = "备忘录未就绪"
            return nil
        }
        // 切到列表视图（已是列表视图时点击是幂等的；画廊视图没有编辑器；
        // 0 窗口时这是无害的菜单操作）
        _ = clickNotesMenu(pairs: [("列表视图", "显示"), ("List View", "View")])
        Thread.sleep(forTimeInterval: 0.4)
        let before = allNoteIDs()
        // 文件→新建备忘录：无论当前是 0 窗口还是有窗口，Notes 都会创建新笔记
        // 并把编辑器聚焦（0 窗口时会新开一个窗口）
        // 先记下当前聚焦的笔记：新建成功后焦点必然落到一条新笔记上。
        // 用它判断点击是否真的生效，避免菜单点击没起作用时把内容粘贴进旧笔记。
        let prevFocus = focusedNoteTextAreaID()
        let newNotePairs: [(item: String, bar: String)] = [("新建备忘录", "文件"), ("New Note", "File")]
        guard clickNotesMenu(pairs: newNotePairs) else {
            lastPasteFailureHint = "点击「文件→新建备忘录」失败"
            return nil
        }
        // 等新笔记编辑器聚焦（焦点元素为 AXTextArea，且不是原来那条笔记），最多 6 秒
        var focus = focusedNoteTextAreaID()
        var elapsed = 0.0
        while elapsed < 6, focus == nil || focus == prevFocus {
            Thread.sleep(forTimeInterval: 0.2)
            elapsed += 0.2
            focus = focusedNoteTextAreaID()
        }
        if focus == nil || focus == prevFocus {
            // 备忘录偶尔会吞掉第一次点击，再点一次并再等 3 秒
            _ = clickNotesMenu(pairs: newNotePairs)
            var retried = 0.0
            while retried < 3, focus == nil || focus == prevFocus {
                Thread.sleep(forTimeInterval: 0.2)
                retried += 0.2
                focus = focusedNoteTextAreaID()
            }
        }
        guard focus != nil, focus != prevFocus else {
            for id in allNoteIDs().subtracting(before) { deleteNote(id: id) }
            lastPasteFailureHint = "「新建备忘录」未生效（编辑器未切换到新笔记）"
            return nil
        }
        Thread.sleep(forTimeInterval: 0.15)
        copyRich(markdown: markdown, preloadLocalImages: true)
        guard clickNotesMenu(pairs: [("粘贴", "编辑"), ("Paste", "Edit")]) else {
            for id in allNoteIDs().subtracting(before) { deleteNote(id: id) }
            lastPasteFailureHint = "点击「编辑→粘贴」失败"
            return nil
        }
        Thread.sleep(forTimeInterval: 1.2)
        // 新建的笔记可能要稍后才出现在 Apple Events 的笔记列表里（iCloud 同步），多等几秒
        var newIDs = allNoteIDs().subtracting(before)
        var listed = 0.0
        while newIDs.isEmpty && listed < 6 {
            Thread.sleep(forTimeInterval: 0.5)
            listed += 0.5
            newIDs = allNoteIDs().subtracting(before)
        }
        guard !newIDs.isEmpty else {
            lastPasteFailureHint = "未检测到新建的备忘录"
            return nil
        }
        // 极端情况（一次出现多条新笔记，如 iCloud 同步）：按正文首行匹配
        var id = newIDs.first
        if newIDs.count > 1 {
            let marker = firstContentLine(markdown)
            id = nil
            if !marker.isEmpty {
                for cand in newIDs where (noteBody(id: cand) ?? "").contains(marker) {
                    id = cand
                    break
                }
            }
            if id == nil { id = newIDs.sorted().first }
        }
        // 校验粘贴是否生效，分两级：
        // 1) 快速校验（UI 层）：粘贴成功后编辑器 AXValue 会立刻有内容，
        //    该读取走 AX、不被 Notes 导入图片时的 Apple Events 阻塞。
        //    5 秒内仍为空 → 粘贴没送达，快速失败。
        var delivered = focusedEditorTextLength() > 0
        var dElapsed = 0.0
        while !delivered && dElapsed < 5 {
            Thread.sleep(forTimeInterval: 0.3)
            dElapsed += 0.3
            if focusedEditorTextLength() > 0 { delivered = true }
        }
        // 2) 尽力确认正文提交：粘贴后 Notes 导入图片附件期间正文可能长时间为空
        //    （Apple Events 被阻塞时读取超时返回 nil）。本机慢导入实测需几十秒，
        //    但第 1 步已确认内容在编辑器中，Notes 会在后台完成写入，因此：
        //    已送达 → 最多再等 15 秒，等不到也按成功返回；未送达 → 最多等 6 秒判失败。
        let vDeadline = Date().addingTimeInterval(delivered ? 8 : 6)
        var committed = false
        while Date() < vDeadline {
            if let b = noteBody(id: id!), !b.isEmpty {
                committed = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard committed || delivered else {
            deleteNote(id: id!)
            lastPasteFailureHint = "粘贴未生效"
            return nil
        }
        return id!
    }

    /// 备忘录当前打开的窗口数（查询失败返回 -1，按有窗口处理）
    private static func notesWindowCount() -> Int {
        if let n = axWindowCount() { return n }
        let script = "tell application \"System Events\" to get count of windows of (first process whose name is \"Notes\")"
        guard case .success(let out) = runAppleScript(script, args: []) else { return -1 }
        return Int(out) ?? -1
    }

    /// 等待备忘录可响应 Apple Events。冷启动时首次 ping 会阻塞到备忘录就绪
    /// （本机实测冷启动需数秒到二十秒），单次 ping 限时 10 秒防止无限阻塞。
    private static func waitNotesAppleEvents(timeout: TimeInterval) -> Bool {
        var waited = 0.0
        while waited < timeout {
            if case .success = runAppleScript("tell application \"Notes\" to get name", args: [],
                                              timeout: 10) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
            waited += 0.5
        }
        return false
    }

    /// 等待 System Events 能看到备忘录进程（窗口数查询与菜单点击都依赖它）。
    /// 冷启动后进程出现在 System Events 列表可能比 Apple Events 就绪更晚。
    private static func waitNotesProcessVisible(timeout: TimeInterval) -> Bool {
        var waited = 0.0
        while waited < timeout {
            if notesWindowCount() != -1 { return true }
            Thread.sleep(forTimeInterval: 0.5)
            waited += 0.5
        }
        return notesWindowCount() != -1
    }

    /// 点击备忘录菜单项：按顺序尝试 (菜单项名, 菜单栏项名) 各对（兼容中英文 UI）。
    /// 优先用本进程 AX 通道（见上）；仅在 AX 不可用时回退 System Events 脚本。
    private static func clickNotesMenu(pairs: [(item: String, bar: String)]) -> Bool {
        if clickNotesMenuAX(pairs: pairs) {
            lastMenuClickChannel = "ax"
            return true
        }
        let ok = clickNotesMenuSystemEvents(pairs: pairs)
        lastMenuClickChannel = ok ? "system-events" : ""
        return ok
    }

    /// 最近一次菜单点击走的通道（"ax" / "system-events" / ""）。
    /// 出现 "system-events" 说明本进程 AX 通道没起作用，往往意味着这次操作
    /// 需要「设备控制和数据访问」授权；调试日志据此定位权限问题的来源。
    private(set) static var lastMenuClickChannel = ""

    /// 回退路径：让 System Events 代点菜单（需要「设备控制和数据访问」授权）
    private static func clickNotesMenuSystemEvents(pairs: [(item: String, bar: String)]) -> Bool {
        for pair in pairs {
            let script = """
            on run argv
                set wantItem to item 1 of argv
                set wantBar to item 2 of argv
                tell application "System Events"
                    tell (first process whose name is "Notes")
                        repeat with mbi in (menu bar items of menu bar 1)
                            if (name of mbi) is wantBar then
                                repeat with mi in (menu items of menu 1 of mbi)
                                    if (name of mi) is wantItem then
                                        click mi
                                        return true
                                    end if
                                end repeat
                            end if
                        end repeat
                    end tell
                end tell
                return false
            end run
            """
            if case .success(let out) = runAppleScript(script, args: [pair.item, pair.bar]),
               out == "true" {
                return true
            }
        }
        return false
    }

    /// 备忘录当前焦点元素若为笔记正文（AXTextArea），返回其 AXIdentifier（形如 Note[id=UUID]），否则 nil。
    /// 直接查询 Notes 进程（不依赖其是否前台）。
    private static func focusedNoteTextAreaID() -> String? {
        if let fe = axFocusedElement(), axString(fe, "AXRole") == "AXTextArea" {
            let id = axString(fe, "AXIdentifier") ?? ""
            return id.isEmpty ? nil : id
        }
        let script = """
        on run
            tell application "System Events"
                set p to first process whose name is "Notes"
                try
                    set fe to value of attribute "AXFocusedUIElement" of p
                    if role of fe is not "AXTextArea" then return ""
                    return value of attribute "AXIdentifier" of fe
                on error
                    return ""
                end try
            end tell
        end run
        """
        guard case .success(let out) = runAppleScript(script, args: []) else { return nil }
        return out.isEmpty ? nil : out
    }

    /// 备忘录当前聚焦编辑器（AXTextArea）的文本长度；非文本区或读不到返回 -1。
    /// 读取走 AX，不被 Notes 导入图片时的 Apple Events 阻塞，用于快速判断粘贴是否送达。
    private static func focusedEditorTextLength() -> Int {
        if let fe = axFocusedElement(), axString(fe, "AXRole") == "AXTextArea",
           let value = axString(fe, "AXValue") {
            return value.count
        }
        let script = """
        on run
            tell application "System Events"
                set p to first process whose name is "Notes"
                try
                    set fe to value of attribute "AXFocusedUIElement" of p
                    if role of fe is not "AXTextArea" then return "-1"
                    set v to value of fe
                    if v is missing value then return "0"
                    return length of v
                on error
                    return "-1"
                end try
            end tell
        end run
        """
        guard case .success(let out) = runAppleScript(script, args: [], timeout: 5) else { return -1 }
        return Int(out) ?? -1
    }

    /// 删除指定笔记（清理粘贴失败/流程中产生的空笔记）
    private static func deleteNote(id: String) {
        let script = """
        on run argv
            set theID to item 1 of argv
            tell application "Notes"
                try
                    delete (first note whose id is theID)
                on error
                end try
            end tell
        end run
        """
        _ = runAppleScript(script, args: [id])
    }

    /// 确保备忘录在运行并激活到前台。
    /// 就绪判断以 Apple Events ping 为准：本机 macOS 27 上冷启动后
    /// NSWorkspace.runningApplications 可能十几秒都检测不到新进程，
    /// 而 Apple Events 在备忘录就绪后即可用（未运行时 ping 会自动拉起它）。
    private static func activateNotes() -> Bool {
        let appURL = URL(fileURLWithPath: "/System/Applications/Notes.app")
        if !NSWorkspace.shared.runningApplications
            .contains(where: { $0.bundleIdentifier == notesBundleID }) {
            NSWorkspace.shared.openApplication(at: appURL,
                                               configuration: NSWorkspace.OpenConfiguration())
        }
        guard waitNotesAppleEvents(timeout: 30) else { return false }
        // 尽量带到前台（菜单点击本身不依赖前台，这里只为体验更好）
        if let notes = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == notesBundleID }) {
            notes.activate()
        }
        // 用 AX 置前，避免再让 System Events 代做一次「控制」
        if let app = notesAXApp() {
            if AXUIElementSetAttributeValue(app, "AXFrontmost" as CFString, kCFBooleanTrue) != .success {
                _ = runAppleScript("tell application \"System Events\" to set frontmost of (first process whose name is \"Notes\") to true",
                                   args: [], timeout: 10)
            }
        }
        // 刚置前时菜单栏可能还没准备好，立刻点菜单容易被吞掉
        Thread.sleep(forTimeInterval: 0.25)
        return true
    }

    /// 当前所有笔记 id 集合
    private static func allNoteIDs() -> Set<String> {
        let script = """
        on run
            set output to ""
            tell application "Notes"
                repeat with n in notes
                    set output to output & (id of n) & linefeed
                end repeat
            end tell
            return output
        end run
        """
        guard case .success(let out) = runAppleScript(script, args: []) else { return [] }
        return Set(out.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    /// 指定笔记的正文（直接引用，不遍历全部笔记；读取超时返回 nil）
    private static func noteBody(id: String) -> String? {
        let script = """
        on run argv
            set theID to item 1 of argv
            tell application "Notes"
                try
                    return body of (first note whose id is theID)
                on error
                    return ""
                end try
            end tell
        end run
        """
        guard case .success(let out) = runAppleScript(script, args: [id], timeout: 8) else { return nil }
        return out
    }

    /// markdown 首个非空行（内容标记）
    private static func firstContentLine(_ markdown: String) -> String {
        for raw in markdown.split(separator: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return ""
    }

    // MARK: - 调试（--create-note-debug）

    static func runCreateNoteDebug(markdown: String) {
        var log = ""
        func add(_ line: String) {
            log += line + "\n"
            try? log.write(toFile: "/tmp/create-note-debug.log", atomically: true, encoding: .utf8)
        }
        add("start \(Date()) trusted=\(canPasteIntoNotes)")
        add("activateNotes=\(activateNotes())")
        add("windows=\(notesWindowCount())")
        let before = allNoteIDs()
        add("before count=\(before.count)")
        copyRich(markdown: markdown, preloadLocalImages: true)
        add("list-view click=\(clickNotesMenu(pairs: [("列表视图", "显示"), ("List View", "View")])) channel=\(lastMenuClickChannel)")
        Thread.sleep(forTimeInterval: 0.4)
        add("new-note click=\(clickNotesMenu(pairs: [("新建备忘录", "文件"), ("New Note", "File")])) channel=\(lastMenuClickChannel)")
        for i in 1...30 {
            Thread.sleep(forTimeInterval: 0.2)
            let fid = focusedNoteTextAreaID()
            add("t=\(String(format: "%.1f", Double(i) * 0.2)) focus=\(fid ?? "nil")")
            if fid != nil { break }
        }
        Thread.sleep(forTimeInterval: 0.15)
        add("paste click=\(clickNotesMenu(pairs: [("粘贴", "编辑"), ("Paste", "Edit")])) channel=\(lastMenuClickChannel)")
        Thread.sleep(forTimeInterval: 1.2)
        let newIDs = allNoteIDs().subtracting(before)
        add("newIDs=\(newIDs.sorted())")
        for id in newIDs {
            let b = noteBody(id: id) ?? ""
            add("body[\(id)] len=\(b.count)")
        }
        add("done \(Date())")
    }

    // MARK: - osascript 执行

    /// 运行 AppleScript（参数作为 argv 传入），返回 stdout 去除首尾空白
    private static func runAppleScript(_ script: String, args: [String],
                                       timeout: TimeInterval? = nil) -> Result<String, Error> {
        let scriptPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("notesmd-\(ProcessInfo.processInfo.processIdentifier)-\(Int(Date().timeIntervalSince1970 * 1000)).scpt")
        guard (try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)) != nil else {
            return .failure(NSError(domain: "NotesMD", code: 1,
                                     userInfo: [NSLocalizedDescriptionKey: "写入临时 AppleScript 失败"]))
        }
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = [scriptPath] + args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return .failure(error) }

        // 先起后台线程把两条管道读空，再等待进程退出。
        // 备忘录正文 HTML 可达数百 KB（带表格的笔记尤其大），超过管道缓冲区
        // （64KB）后 osascript 会阻塞在 write 上；原先「先 waitUntilExit 再读管道」
        // 的写法在这种笔记上永久死锁，表现为「打开备忘录」后编辑区一片空白。
        let outBox = DataBox()
        let errBox = DataBox()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outBox.append(outPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.append(errPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        var timedOut = false
        if let timeout = timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if p.isRunning {
                p.terminate()
                let t2 = Date().addingTimeInterval(2)
                while p.isRunning && Date() < t2 {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if p.isRunning {
                    kill(p.processIdentifier, SIGKILL)
                    timedOut = true
                }
            }
        } else {
            p.waitUntilExit()
        }
        // 进程已退出或被杀，管道必然到达 EOF；仍设 5 秒上限，避免极端情况卡住调用方
        _ = readers.wait(timeout: .now() + 5)
        let out = String(data: outBox.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errBox.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if timedOut {
            return .failure(NSError(domain: "NotesMD", code: 6,
                                     userInfo: [NSLocalizedDescriptionKey:
                                                    "备忘录响应超时（\(Int(timeout ?? 0)) 秒）"]))
        }
        if p.terminationStatus != 0 {
            return .failure(NSError(domain: "NotesMD", code: Int(p.terminationStatus),
                                     userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "AppleScript 执行失败" : err]))
        }
        return .success(out)
    }
}

/// 供后台线程回填的 Data 容器（加锁，便于安全地在读管道线程与调用线程之间传递）
private final class DataBox {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
