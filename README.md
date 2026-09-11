# NotesMD — 给 Apple 备忘录加 Markdown 输入

macOS 小工具应用：Dock 图标常驻，同时在顶部菜单栏提供图标。在窗口里直接用 Markdown 语法写作，右侧即时预览排版，一键把结果写进 macOS 自带备忘录（写入的是原生富文本，而不是纯文本）。

仅依赖系统框架（AppKit / osascript），无第三方库。

## 功能

- **左栏 Markdown 编辑，右栏实时预览**（输入停顿 0.15s 自动刷新）
- **备忘录标题自动取自正文首个非空行**（不再单独提供标题输入框）
  支持语法：ATX / Setext 标题、**加粗**、*斜体*、~~删除线~~、`行内代码`、围栏代码块、有序/无序/嵌套列表、任务列表（`- [ ]` / `- [x]`）、完整表格（表头、左/中/右对齐、单元格内 `\|` 转义、长文本自动换行、引用内表格）、多级引用、水平线、[链接]、`![](url)` 图床图片、自动链接 `<https://…>`、反斜杠转义 `\*`、HTML 对齐标签（`<div align="center">…</div>` / `<p align="right">…</p>` / `<center>…</center>`，支持 left/center/right；块内的标题/列表/表格等按对应排版渲染，如 `<center> # 一级标题 </center>` 渲染为居中的加粗大标题）
  - 预览区表格渲染为带完整框线的表格图（表头加粗带底色）；写入备忘录时输出 `border=1` 的 HTML，Notes 会渲染成带框线的原生表格
- **新建md / 打开md / 保存md**：顶栏左侧按钮 + 菜单，Markdown 文件编辑（⌘N / ⌘O / ⌘S / ⇧⌘S）；「新建备忘录并粘贴 / 打开备忘录 / 更新备忘录」也位于顶栏左侧
- **新建备忘录并粘贴**（⌘R）：在 Apple 备忘录中创建一条原生排版的笔记（首行标题渲染为加粗大标题），同时把富文本复制进剪贴板，方便再 ⌘V 到其他笔记；创建后自动**关联**该笔记
- **关联修改已有备忘录**：
  - 「更新备忘录」（⇧⌘U）：把当前内容整体写入已关联的笔记（按 note id 更新，可反复覆盖，id 稳定）
  - 「打开备忘录」：从已有笔记中挑一条（支持按标题搜索；自动跳过「最近删除」中不可修改的笔记），**卡片网格**视图（半透明毛玻璃卡片，跟随背景图与透明度设置），支持**方向键切换选中项（↑↓按行、←→按列）、回车打开**（搜索框内回车同样打开所选）；切换时选中卡片超出可视区域会自动滚动居中；选中后会**把该备忘录的正文读回、转成 Markdown 装入编辑区**（表格/列表/任务项等一并还原；备忘录读回的 HTML 会丢失表格列对齐，本软件会按最近一次写入该备忘录的内容自动恢复 `:---:` / `---:` 对齐），改完再「更新备忘录」即可写回同一条笔记
  - 打开前若当前编辑区内容既没保存为 md、也没写入备忘录，会弹窗确认再加载（避免误替换）；读取完成后**自动跳回 NotesMD 主窗口**（osascript 读备忘录时会把备忘录带到前台）
  - 关联关系会记住（重启后仍在）；关联的笔记被删除时会提示并自动解绑
- **复制为富文本**（⇧⌘C，文件菜单）：只复制渲染结果（RTF/HTML/纯文本）到剪贴板，自己选位置粘贴
- **自动保存md**（右上角开关，开启态为绿色）：打开 md 文件后，停顿 0.6 秒自动保存该文件；关闭窗口时若开启且文件已打开，未及写盘的更改会直接保存，不弹窗；设置会记住
- **关闭确认**（红点关窗 / ⌘Q 退出一致，按当前模式区分）：
  - 新建md / 打开md：已保存或没有新增内容时直接关闭不提醒；有未保存的 md 更改时弹窗（保存并关闭 / 不保存直接关闭 / 取消）
  - 新建备忘录 / 打开备忘录：新增内容已写回关联备忘录时直接关闭不提醒；未写回时弹窗（更新备忘录并关闭 / 不更新直接关闭 / 取消）
  - 「打开备忘录」读回的内容与备忘录一致，视为已同步，不会误提醒
- **全局快捷键 ⌥⌘M**：随时呼出 / 隐藏窗口
- **Markdown 文件编辑**：新建（⌘N）、打开（⌘O）、保存（⌘S）、另存为（⇧⌘S）；支持 `.md` / `.markdown` / `.mdown`，可直接在 Finder 里用 NotesMD 打开 .md 文件；菜单中可一键「设为 .md 默认打开程序」
- **预览背景图**：顶栏「背景设置」弹窗（固定不可拖动）内选择背景图片（铺满整个窗口：编辑区 + 预览区 + 标题栏 + 各弹窗）、用「透明度」滑杆调节不透明度、「清除背景」移除；设置会记住，重启后自动恢复。背景图与透明度会同步覆盖到「打开备忘录 / 背景设置 / 历史图片」等弹窗。添加背景不改变窗口大小与比例
- **图床图片 `![](url)`**：预览区异步下载并显示图片（带缓存、占位框、限宽）；支持 `http/https/file://` 与本地绝对路径，有 `alt` 时图下显示说明文字
- **粘贴图片自动转链接**：在编辑区直接 ⌘V 粘贴图片，会存到本地图床（`~/Library/Application Support/NotesMD/images/`）并写成 `![](路径)`；粘贴带图床 URL 的剪贴板则直接写成 `![](url)`
- **图床图片**：预览区异步下载显示（缓存 + 占位框 + 限宽），支持 `http/https/file://` 与本地绝对路径；有 `alt` 时图下显示说明文字
- **上传 pixhost 图床**（右上角「上传图床」）：选一张或多张图片上传到 pixhost（官方 API，支持 JPG/PNG/GIF/WebP/AVIF，≤10MB，其他格式自动转 PNG）；上传成功的 sheet 里可**复制原图直链** / 展示页，或一键把 `![](原图直链)` 插入编辑区
- **历史图片**（右上角「历史图片」）：列出所有上传过的图片（本地持久化，最多 500 条），**列表 / 卡片**两种视图切换，**分页**加载（列表 20 / 卡片 12 每页）；可复制原图链接、打开展示页；**移除需二次确认**，可选「移除并删除远端」（调 pixhost 删除接口）或「仅移出列表」
- **备忘录排版**：正文首行标题渲染为加粗大标题并用作笔记名（不重复），块之间保留段落空行
- **编辑菜单**（全中文）：撤销/重做、剪切/拷贝/粘贴/粘贴并匹配样式（⇧⌥⌘V）/删除/全选，**查找**子菜单（⌘F 查找、⌥⌘F 查找并替换、⌘G / ⇧⌘G 下一个/上一个、替换下一个/全部替换/替换并查找、⌘E 用所选文字查找），**定位**子菜单（⌘J 定位选区）；编辑区支持 ⌘F 唤出系统查找条
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
3. 写入备忘录：
   - 「新建备忘录并粘贴」（⌘R）— 新建一条笔记并自动关联，富文本同时进剪贴板
   - 「更新备忘录」（⇧⌘U）— 把当前内容写回关联的笔记（关联修改）
   - 「打开备忘录」— 打开任意一条已有笔记（可搜索，列表/卡片视图），其内容以 Markdown 形式加载进编辑区，之后即可反复更新它
   - 「复制为富文本」（⇧⌘C）— 复制到剪贴板，到任意笔记 ⌘V 粘贴
4. 图片：右上角「上传图床」传图到 pixhost 拿原图直链（可一键插入 `![](链接)`）；「历史图片」管理上传历史
5. 操作结果会显示在窗口底部状态栏

也可以把 Markdown 先存成文件（⌘S）再写入备忘录，方便反复编辑。

**关联修改工作流**：`新建备忘录并粘贴`（或 `打开备忘录`）建立关联 → 之后随意编辑 Markdown → `更新备忘录` 覆盖写入同一条笔记。这样既能保留 Markdown 源文件，又能随时同步到备忘录里的同一条笔记，不用再手动找笔记。

## 首次使用需要的系统权限

- **自动化权限**：第一次点「新建备忘录并粘贴」时，系统会弹窗请求「NotesMD 想要控制 Notes」，点允许即可
- **网络**：预览区显示 `![](url)` 图床图片需要联网下载

## 命令行（调试 / 脚本）

`build/NotesMD.app` 内的可执行文件（或 `swift build -c release` 后的 `.build/release/NotesMD`）支持以下参数：

```bash
.build/release/NotesMD --html note.md            # 输出该 markdown 文件的 HTML
.build/release/NotesMD --png in.md out.png       # 把该 markdown 文件渲染为 PNG（静态，不等图片下载）
.build/release/NotesMD --layout                  # 打印窗口布局信息后退出（调试用）
.build/release/NotesMD --smoke                   # 冒烟测试：渲染示例并真实创建一条备忘录
.build/release/NotesMD --note-list               # 列出备忘录（id + 标题，跳过最近删除）
.build/release/NotesMD --note-md <id>           # 读取指定备忘录正文并输出为 Markdown（调试用）
.build/release/NotesMD --note-update <id> in.md  # 把 markdown 内容更新进指定 id 的已有备忘录
.build/release/NotesMD --pixhost-upload img.png  # 上传图片到 pixhost，打印直链/展示页/管理链接
.build/release/NotesMD --pixhistory [out.png] [list|card]
                                                 # 打开历史图片窗口（可选截图/卡片模式，调试用）
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
Sources/NotesMD/NotesService.swift       osascript 建笔记/更新笔记/列笔记、剪贴板、模拟 ⌘V 粘贴
Sources/NotesMD/NoteLink.swift           备忘录关联（绑定存储 + 笔记选择窗口）
Sources/NotesMD/Pixhost.swift            pixhost 图床 API、历史存储、上传结果 sheet、历史图片窗口
Sources/NotesMD/ImageStore.swift         图床图片下载、缓存、占位图
Sources/NotesMD/MediaStore.swift         粘贴图片的本地图床存储
Sources/NotesMD/MarkdownBlocks.swift     块级解析（HTML / 富文本共用）：标题、表格（含转义竖线）、嵌套列表、任务列表、引用
```
