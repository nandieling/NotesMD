import AppKit
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

    /// 把渲染结果（RTF + HTML + 纯文本）放入剪贴板，可直接 ⌘V 进备忘录。
    static func copyRich(markdown: String) {
        let html = MarkdownRenderer.html(from: markdown)
        let pb = NSPasteboard.general
        pb.clearContents()
        let attr = MarkdownRenderer.render(markdown)
        pb.writeObjects([attr])
        if let data = html.data(using: .utf8) {
            pb.setData(data, forType: .html)
        }
    }

    /// 激活备忘录并发送 ⌘V（需要辅助功能权限；无权限时静默失败，用户可手动粘贴）。
    static func pasteIntoNotes() {
        guard let notes = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == notesBundleID }) else {
            return
        }
        notes.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V
            keyDown?.flags = .maskCommand
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - osascript 执行

    /// 运行 AppleScript（参数作为 argv 传入），返回 stdout 去除首尾空白
    private static func runAppleScript(_ script: String, args: [String]) -> Result<String, Error> {
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
        p.waitUntilExit()
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
