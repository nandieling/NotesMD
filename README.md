# NotesMD — 给 Apple 备忘录加 Markdown 输入

菜单栏小工具：在窗口里直接用 Markdown 语法写作，右侧即时预览排版，
一键把结果写进 macOS 自带备忘录（原生富文本，而不是纯文本）。

## 功能
- 左栏 Markdown 编辑，右栏实时预览（标题、加粗、斜体、删除线、代码、列表、引用、链接、水平线）
- **新建备忘录**：在备忘录中创建一条原生排版的笔记（⌘R）
- **粘贴到当前备忘录**：自动激活备忘录并 ⌘V（⇧⌘V；需要给 NotesMD 授予辅助功能权限，否则请手动 ⌘V）
- **复制富文本**：把渲染结果（RTF/HTML）放进剪贴板，自己选位置粘贴（⇧⌘C）
- 全局快捷键 **⌥⌘M**：随时呼出 / 隐藏窗口
- 标题输入框可留空，自动从正文第一个 `# 标题` 提取

## 构建与运行
```bash
./Scripts/make-app.sh     # 编译并生成 build/NotesMD.app
open build/NotesMD.app
```
仅依赖系统框架（AppKit / osascript），无第三方库。

## 首次使用注意
- 第一次点「新建备忘录」时，系统会弹窗请求「NotesMD 想要控制 Notes」，点允许即可。
- 「粘贴到当前备忘录」需要：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 NotesMD。

## 命令行
```bash
.build/release/NotesMD --html note.md   # 输出 HTML
.build/release/NotesMD --png out.png    # 渲染示例为 PNG
```

## 结构
- `Sources/NotesMD/MarkdownRenderer.swift` — 轻量 Markdown → HTML / 富文本
- `Sources/NotesMD/NotesService.swift` — osascript 建笔记、剪贴板、模拟粘贴
- `Sources/NotesMD/main.swift` — 窗口、菜单栏、全局快捷键
