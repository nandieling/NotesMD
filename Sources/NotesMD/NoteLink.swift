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

// MARK: - 笔记选择窗口

final class NotePickerWindowController: NSWindowController, NSWindowDelegate,
                                        NSTableViewDataSource, NSTableViewDelegate,
                                        NSTextFieldDelegate {

    struct NoteRef {
        let id: String
        let name: String
    }

    var onPick: ((_ id: String, _ name: String) -> Void)?

    private var all: [NoteRef] = []
    private var filtered: [NoteRef] = []
    private var loading = false
    private var loaded = false
    private var table: NSTableView!
    private var searchField: NSTextField!
    private var statusLabel: NSTextField!
    private var emptyLabel: NSTextField!

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "选择要关联的备忘录"
        win.minSize = NSSize(width: 380, height: 300)
        win.center()
        self.init(window: win)
        win.delegate = self
        build()
    }

    func showWindowAndLoad() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !loaded { load() }
    }

    private func build() {
        guard let content = window?.contentView else { return }

        searchField = NSTextField(string: "")
        searchField.placeholderString = "搜索备忘录标题…"
        searchField.font = NSFont.systemFont(ofSize: 13)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        content.addSubview(searchField)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        table = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 28
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pickSelected)
        scroll.documentView = table
        content.addSubview(scroll)

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

        let pickBtn = NSButton(title: "关联所选", target: self, action: #selector(pickSelected))
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
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -56),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            pickBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            pickBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            pickBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),

            cancelBtn.trailingAnchor.constraint(equalTo: pickBtn.leadingAnchor, constant: -8),
            cancelBtn.centerYAnchor.constraint(equalTo: pickBtn.centerYAnchor),
            cancelBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])
    }

    // MARK: - 数据

    private func load() {
        loading = true
        statusLabel.stringValue = "正在读取备忘录…"
        table.reloadData()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NotesService.listNotes()
            DispatchQueue.main.async {
                guard self.loading else { return }
                self.loading = false
                self.loaded = true
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
        table.reloadData()
        emptyLabel.isHidden = !filtered.isEmpty
        if filtered.isEmpty {
            emptyLabel.stringValue = all.isEmpty ? "没有找到备忘录" : "没有匹配的备忘录"
        }
        if table.selectedRow < 0 || table.selectedRow >= filtered.count {
            table.selectRowIndexes(filtered.isEmpty ? [] : [0], byExtendingSelection: false)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    @objc private func pickSelected() {
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else {
            statusLabel.stringValue = "请先选择一条备忘录"
            return
        }
        let ref = filtered[row]
        onPick?(ref.id, ref.name)
        window?.close()
    }

    @objc private func cancel() {
        window?.close()
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("noteCell")
        let cell: NSTextField
        if let reuse = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            cell = reuse
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = id
            cell.lineBreakMode = .byTruncatingTail
            cell.font = NSFont.systemFont(ofSize: 13)
        }
        cell.stringValue = filtered[row].name
        cell.toolTip = filtered[row].name
        return cell
    }
}
