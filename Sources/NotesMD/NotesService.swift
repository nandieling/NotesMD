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

    /// 读取指定笔记的正文 HTML（用于「选择备忘录」后把内容转成 Markdown 装入编辑区）
    static func noteHTML(id: String) -> Result<String, Error> {
        let script = """
        on run argv
            set theID to item 1 of argv
            tell application "Notes"
                repeat with n in (notes)
                    if id of n is theID then
                        return body of n
                    end if
                end repeat
            end tell
            return ""
        end run
        """
        switch runAppleScript(script, args: [id]) {
        case .success(let out):
            if out.isEmpty {
                return .failure(NSError(domain: "NotesMD", code: 5,
                                        userInfo: [NSLocalizedDescriptionKey: "读不到该备忘录的正文"]))
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

    /// 是否有辅助功能权限（菜单查询与点击走 AX 通道）
    static var canPasteIntoNotes: Bool { AXIsProcessTrusted() }

    /// 请求辅助功能权限：未授权时弹出系统对话框（带「打开系统设置」按钮，
    /// 直接定位到 隐私与安全性→辅助功能 列表）。返回当前是否已授权。
    @discardableResult
    static func requestAXAccessIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
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
        guard clickNotesMenu(pairs: [("新建备忘录", "文件"), ("New Note", "File")]) else {
            lastPasteFailureHint = "点击「文件→新建备忘录」失败"
            return nil
        }
        // 等新笔记编辑器聚焦（焦点元素变为 AXTextArea），最多 6 秒
        var elapsed = 0.0
        while elapsed < 6, focusedNoteTextAreaID() == nil {
            Thread.sleep(forTimeInterval: 0.2)
            elapsed += 0.2
        }
        guard focusedNoteTextAreaID() != nil else {
            for id in allNoteIDs().subtracting(before) { deleteNote(id: id) }
            lastPasteFailureHint = "等待备忘录编辑器就绪超时"
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
        let newIDs = allNoteIDs().subtracting(before)
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
    /// 菜单点击是 AX 动作，不产生 HID 键盘/鼠标事件。
    private static func clickNotesMenu(pairs: [(item: String, bar: String)]) -> Bool {
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
        _ = runAppleScript("tell application \"System Events\" to set frontmost of (first process whose name is \"Notes\") to true",
                           args: [], timeout: 10)
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
        add("list-view click=\(clickNotesMenu(pairs: [("列表视图", "显示"), ("List View", "View")]))")
        Thread.sleep(forTimeInterval: 0.4)
        add("new-note click=\(clickNotesMenu(pairs: [("新建备忘录", "文件"), ("New Note", "File")]))")
        for i in 1...30 {
            Thread.sleep(forTimeInterval: 0.2)
            let fid = focusedNoteTextAreaID()
            add("t=\(String(format: "%.1f", Double(i) * 0.2)) focus=\(fid ?? "nil")")
            if fid != nil { break }
        }
        Thread.sleep(forTimeInterval: 0.15)
        add("paste click=\(clickNotesMenu(pairs: [("粘贴", "编辑"), ("Paste", "Edit")]))")
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
            }
        } else {
            p.waitUntilExit()
        }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if p.terminationStatus != 0 {
            return .failure(NSError(domain: "NotesMD", code: Int(p.terminationStatus),
                                     userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "AppleScript 执行失败" : err]))
        }
        return .success(out)
    }
}
