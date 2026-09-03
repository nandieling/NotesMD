# NotesMD — 给 Apple 备忘录加 Markdown 输入

macOS 小工具应用：Dock 图标常驻，同时在顶部菜单栏提供图标。在窗口里直接用 Markdown 语法写作，右侧即时预览排版，一键把结果写进 macOS 自带备忘录（写入的是原生富文本，而不是纯文本）。

仅依赖系统框架（AppKit / osascript），无第三方库。

## 功能

- **左栏 Markdown 编辑，右栏实时预览**（输入停顿 0.15s 自动刷新）
  支持语法：标题、**加粗**、*斜体*、~~删除线~~、`行内代码`、围栏代码块、有序/无序列表、引用、水平线、[链接]、段落换行
- **新建备忘录**（⌘R）：在 Apple 备忘录中创建一条原生排版的笔记；标题输入框可留空，自动从正文第一个 `# 标题` 提取
- **粘贴到当前备忘录**（⇧⌘V）：把渲染结果放进剪贴板，自动激活备忘录并模拟 ⌘V（需要辅助功能权限，否则剪贴板里已是富文本，手动 ⌘V 即可）
- **复制富文本**（⇧⌘C）：只复制渲染结果（RTF/HTML/纯文本）到剪贴板，自己选位置粘贴
- **全局快捷键 ⌥⌘M**：随时呼出 / 隐藏窗口
- **Markdown 文件编辑**：新建（⌘N）、打开（⌘O）、保存（⌘S）、另存为（⇧⌘S）；支持 `.md` / `.markdown` / `.mdown`，可直接在 Finder 里用 NotesMD 打开 .md 文件；菜单中可一键「设为 .md 默认打开程序」
- **预览背景图**：顶栏「背景图片…」选择图片铺满整个窗口（编辑区 + 预览区），「透明度」滑杆调节不透明度，「清除背景」移除；设置会记住，重启后自动恢复。添加背景不改变窗口大小与比例
- **图床图片 `![](url)`**：预览区异步下载并显示图片（带缓存、占位框、限宽）；支持 `http/https/file://` 与本地绝对路径，有 `alt` 时图下显示说明文字
- **粘贴图片自动转链接**：在编辑区直接 ⌘V 粘贴图片，会存到本地图床（`~/Library/Application Support/NotesMD/images/`）并写成 `![](路径)`；粘贴带图床 URL 的剪贴板则直接写成 `![](url)`
- **备忘录排版**：正文首行标题渲染为加粗大标题并用作笔记名（不重复），块之间保留段落空行
- **菜单栏图标**：显示/隐藏、打开、保存、三种写入方式、设默认应用、退出

## 构建与运行

要求：macOS 13+，已安装 Xcode Command Line Tools（`xcode-select --install`）。

```bash
./Scripts/make-app.sh     # 编译并打包生成 build/NotesMD.app
open build/NotesMD.app
```

`build/` 是构建产物，不入库，随时可用脚本重新生成。

## 使用方法

1. 左侧输入 Markdown，右侧实时预览
2. 可选：在顶部「标题」输入框填写标题（留空则从正文首个 `# 标题` 提取）
3. 三选一写入：
   - 「新建备忘录」（⌘R）— 在备忘录里新建一条笔记
   - 「粘贴到当前备忘录」（⇧⌘V）— 对当前打开的笔记直接粘贴
   - 「复制富文本」（⇧⌘C）— 复制到剪贴板，自行粘贴
4. 操作结果会显示在窗口底部状态栏

也可以把 Markdown 先存成文件（⌘S）再写入备忘录，方便反复编辑。

## 首次使用需要的系统权限

- **自动化权限**：第一次点「新建备忘录」时，系统会弹窗请求「NotesMD 想要控制 Notes」，点允许即可
- **辅助功能权限**（仅「粘贴到当前备忘录」的自动 ⌘V 需要）：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 NotesMD；未授权时点击后剪贴板已复制好，手动在备忘录中按 ⌘V 即可

## 命令行（调试 / 脚本）

`build/NotesMD.app` 内的可执行文件（或 `swift build -c release` 后的 `.build/release/NotesMD`）支持以下参数：

```bash
.build/release/NotesMD --html note.md            # 输出该 markdown 文件的 HTML
.build/release/NotesMD --png in.md out.png       # 把该 markdown 文件渲染为 PNG（静态，不等图片下载）
.build/release/NotesMD --layout                  # 打印窗口布局信息后退出（调试用）
.build/release/NotesMD --smoke                   # 冒烟测试：渲染示例并真实创建一条备忘录
.build/release/NotesMD --screenshot in.md out.png [bg.png] [alpha] [paste.png]
                                                 # 加载内容截图（可选背景图/透明度/模拟粘贴图片，调试用）
```

`--screenshot` 的等待时长按环境变量 `NMD_SHOT_WAIT`（秒，默认 5）控制，便于等远程图片下载完成。

## 上传 GitHub 前排查

```bash
./Scripts/check-upload.sh
```

列出会被上传的文件清单及体积，检查构建产物（`.build/`、`build/`）、`.DS_Store`、大文件、二进制文件、疑似密钥，以及未跟踪且未被忽略的文件。当前仓库约定：`.build/`、`build/`、`.DS_Store` 等一律不上传（见 `.gitignore`）。

## 目录结构

```
Package.swift                     SwiftPM 工程定义（macOS 13+）
Scripts/make-app.sh               构建并打包 NotesMD.app
Scripts/check-upload.sh           GitHub 上传前文件排查
Resources/AppIcon.icns            应用图标
Sources/NotesMD/main.swift        窗口、菜单栏、全局快捷键、文件操作、CLI 入口
Sources/NotesMD/MarkdownRenderer.swift   Markdown → HTML / 富文本（HTML 输出方向）
Sources/NotesMD/MarkdownRender.swift     Markdown → NSAttributedString（进程内渲染预览，不依赖 XPC 服务）
Sources/NotesMD/NotesService.swift       osascript 建笔记、剪贴板、模拟 ⌘V 粘贴
Sources/NotesMD/ImageStore.swift         图床图片下载、缓存、占位图
Sources/NotesMD/MediaStore.swift         粘贴图片的本地图床存储
```
