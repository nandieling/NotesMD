import AppKit
import Foundation

/// 与 Apple 备忘录（Notes.app）交互的服务层。
enum NotesService {

    static let notesBundleID = "com.apple.Notes"

    /// 在备忘录中创建一条新笔记（HTML 正文由 Notes 自行排版）。
    @discardableResult
    static func createNote(title: String, html: String) -> Result<Void, Error> {
        let script = """
        on run argv
            set theHTML to item 1 of argv
            set theTitle to item 2 of argv
            tell application "Notes"
                activate
                make new note with properties {name:theTitle, body:theHTML}
            end tell
        end run
        """
        let scriptPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("notesmd-create-note-\(ProcessInfo.processInfo.processIdentifier).scpt")
        guard (try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)) != nil else {
            return .failure(NSError(domain: "NotesMD", code: 1,
                                     userInfo: [NSLocalizedDescriptionKey: "写入临时 AppleScript 失败"]))
        }
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = [scriptPath, html, title]
        let errPipe = Pipe()
        p.standardError = errPipe
        do { try p.run() } catch { return .failure(error) }
        p.waitUntilExit()
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if p.terminationStatus != 0 {
            return .failure(NSError(domain: "NotesMD", code: Int(p.terminationStatus),
                                    userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "AppleScript 执行失败" : message]))
        }
        return .success(())
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
}
