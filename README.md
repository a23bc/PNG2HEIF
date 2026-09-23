# PNG2HEIF iOS 15+ — TrollStore build

PNG → HEIF 工具，面向 iOS 15+。

## 这版专门修复

上一版 IPA 在 TrollStore 中出现：

`parse error 303 unable to locate main binary inside app bundle`

本版本：

- 明确 `CFBundleExecutable = PNG2HEIF`
- 明确 `EXECUTABLE_NAME = $(PRODUCT_NAME)`
- GitHub Actions 在打包前检查主 Mach-O
- 检查主二进制是否为 arm64
- 打包后再次解压 IPA 检查 `Payload/PNG2HEIF.app/PNG2HEIF`
- 检查 `Info.plist` 与 `CFBundleExecutable` 是否一致
- 只有全部检查通过才上传 Artifact

## GitHub Actions

Workflow 会使用 macOS 15 runner 编译 iOS App，并生成：

`PNG2HEIF-TrollStore.ipa`

不进行 Apple Developer 签名，适合你使用 TrollStore 安装的场景。

## 使用

第一次请关闭：

`转换成功后删除 PNG`

先用 5～10 张截图测试日期、分辨率、HEIF 文件以及 Photos 中的显示情况。

确认无误后再开启删除原 PNG。

## 注意

新建的 HEIF Photos 资产无法通过公开 PhotoKit API 任意设置为系统"截图"智能相簿的 screenshot subtype，因此程序使用普通 `HEIF截图` 相簿管理。

## 分支 `feat/screenshot-subtype`：真正写入截图标记

公开 PhotoKit 设不了，就绕开它 —— 直接写 Photos.sqlite 里 Photos 实际用来显示的那一列
`ZASSET.ZKINDSUBTYPE`：

- `0` = 普通照片，`2` = Live Photo，**`10` = SpringBoard 截图**
- 打开「转换后写入截图标记」后，每张转换成功的资产会立刻写成 `10`；界面下方列出最近 12 行的
  `kind` / `cloud` / `Z_PK`，并且可以逐行「设为截图 10」「还原 0」
- 写入纪律：`SQLITE_OPEN_READWRITE` + 一条 `UPDATE` + 一行 + 绑定参数；不做 DDL、不改
  `journal_mode`、不 `checkpoint`、不 `VACUUM`；**写之前先读旧值**，随时可还原
- 定位新建资产：先用 `PHAsset.localIdentifier` 的 UUID 部分匹配 `ZASSET.ZUUID`，匹配不到就退回
  "最新一行且 5 分钟内添加的"；两者都不成立就**什么都不写**，绝不去改来路不明的行
- 需要能读写 `/var/mobile/Media/PhotoData/Photos.sqlite`（TrollStore 安装一般具备）。
  界面上那块探测信息会直接写出"文件不存在 / 打不开 / 读不到"的原因，**不要靠猜**

### 这个分支要验证的三件事

1. **写入是否生效**：转换后界面里 `kind` 是否从 0 变成 10，Photos 里是否按截图归类
2. **是否被系统写回**：respring 或重启 Photos 后点「刷新数据库状态」——值还在 ⇒ 数据库是权威；
   被写回 ⇒ 数据库只是缓存，这条路不能用来长期保持截图标记
3. **需要写几列**：目前只写 `ZKINDSUBTYPE`（真机验证过单这一列就够让界面变截图）。
   对照行里的 `cloud`（`ZCLOUDKINDSUBTYPE`，真实截图是 3）可以先观察，不急着写

### 权限：为什么一开始提示"文件不存在"

App 是沙盒里的，`/var/mobile/Media/PhotoData` 根本不在可达范围内 —— 不是路径写错，是没权限。
`PNG2HEIF/PNG2HEIF.entitlements` 与 PhotosDatabaseInspector 用的是同一套（那份在真机上验证过
能读这个库、也能写）：`com.apple.private.security.no-sandbox`、`platform-application`、
`container-required=false`，加上绝对路径只读例外。

要真正生效，两件事缺一不可：

- entitlements 必须写进 Mach-O 的 **`__TEXT,__entitlements` 段** —— ldid/TrollStore 读的是这个段，
  不是代码签名。workflow 里用
  `OTHER_LDFLAGS='$(inherited) -Wl,-sectcreate,__TEXT,__entitlements,...'` 把段塞进去
- 包再 ad-hoc 签一次同样的 entitlements，签名和段保持一致

CI 里这三步都是**硬检查**（不通过就失败）：`otool -l` 必须找到 `__entitlements` 段、
`codesign -d --entitlements` 必须报出 `no-sandbox` 与 `platform-application`，
并把段内容解出来打日志。构建设置写在 workflow 命令行里，`project.pbxproj` 保持不动。

### 排错：转换"全都失败"是怎么来的

第一版 entitlements **照抄**了 PhotosDatabaseInspector 的整套，里面有两个键
`com.apple.private.security.container-required=false` 与 `com.apple.private.security.no-container=true`
——它们会把 App 的**数据容器**一起去掉。而转换要往 `FileManager.default.temporaryDirectory`
写临时 PNG/HEIC、历史记录写在 Documents 里；容器没了这些路径就不存在，
于是**全量转换和自选转换在同一个地方一起失败**（那个项目不用临时目录，所以它没暴露这个问题）。
现在 entitlements 里已去掉这两个键，只保留真正让数据库可达的 `no-sandbox`。

代码也不再只认容器：

- `resolveWorkDirectory()` 优先 App 临时目录，写不进去就退到 `/tmp/png2heif`，
  两个都写不了才认输，并把原因显示在界面上
- 失败**带上真实原因**：`encodeHEIF` / 复制到文件夹各自的失败点都会写进失败列表
  （以前只在控制台 print，界面只显示"转换失败"，等于没有信息）
- 进度条标题显示本次范围（全部扫描 / 仅选中的 N 张），免得把两次转换看混
- 「已选」下面显示**选择器回传了几个标识符**，以及首个标识符；一张都没回传时会明说
- 数据库面板里多一块**环境自检**：工作目录与 Documents 的路径、能不能写

### 排错二：HEIC 编码失败、自选转换无反应、长按复制闪退

三件事，各自的原因与对策：

**HEIC 编码失败**（`CGImageDestinationFinalize` 返回 false，本身不报原因）。真机上拿到的
失败原文显示**两个目录都是同一个错**，所以不是路径问题，是编码器拒绝这张图
（`1242×2208 alpha=3`，即 RGBA 非预乘）。据此改成**三条路依次尝试**：

1. 原图直接编码
2. **重画成 8bit sRGB、铺白底去掉 alpha** 再编码（16bit / 索引色 / 非标准色彩空间也能一并归到标准形态）
3. **Core Image 的 HEIF 编码器**（`CIContext.writeHEIFRepresentation`）—— 与 ImageIO 是两套实现

每一步都用**新的输出文件名**：在同一个 URL 上失败过的 destination 会让下一个创建直接失败 ——
上一版的重试就是这么白试的（真机证据：两条候选目录报了完全相同的错，说明重试根本没跑成）。
三条都失败时，失败原因会写明尺寸 / 位数 / alpha / 色彩空间，以及每一步的结果。

**自选转换点了没反应**：定位不到资产时，现在会写明"选中几 张 / 在图库里查到几张 /
首个标识符长什么样"，并且加了一条兜底 —— 用标识符的第一段（UUID）再做一次前缀匹配，
以防 PHPicker 回传的前缀与 `PHAsset.localIdentifier` 不是逐字一致。

**长按文本 → 点「复制」闪退**：不再让文本可选中。长按会拉起系统编辑菜单，
那条路径在这台机器上会崩（PhotosDatabaseInspector 里定位过的 CoreImage/`CI::GLContext` 崩溃，
栈里只有 `main`）。改为一个明确的**「复制以上信息」按钮**，直接写剪贴板，
不经过任何菜单界面 —— 顺带也更好按。

### 排错三：转换闪退 —— 这台机器的 CoreImage 是坏的

崩溃日志（`2026-09-23 12:20`，`EXC_BAD_ACCESS` / `KERN_INVALID_ADDRESS at 0x0`）的栈顶写得非常清楚：

```
CoreImage  CI::GLContext::GLContext(...)
CoreImage  +[CIContext(Internal) internalContextWithEAGLContext:options:]
CoreImage  -[CIContext initWithOptions:]
PNG2HEIF   ← 我们的代码（那条 Core Image 兜底）
Photos     -[PHAssetResourceWriteRequest assetResourceRequest:didFinishWithError:]
```

**这台机器上创建 `CIContext` 会在 `CI::GLContext` 里空指针崩溃。** 同一个毛病在
PhotosDatabaseInspector 里也出现过（那次是弹出键盘触发系统渲染）。所以：

- 编码路径**彻底不再触碰 CoreImage** —— 那条 CoreImage 兜底已删除；`import CoreImage` 也删了
- 自检不再创建 `CIContext`，改成探 **VideoToolbox 的 HEVC 编码器**（不经过 CoreImage）
- **重要推论**：ImageIO 的 HEIC 编码在这台机器上失败，很可能与这个 GL 缺陷同源
  （HEIF 编码内部要做色彩管理）。若自检确认 ImageIO 连一张代码生成的标准图都编不出 HEIC，
  而 VideoToolbox 可用，那么下一步就是**绕开 ImageIO**：用 VT 编出 HEVC 码流再手工封装 HEIF 容器

`logs/` 放设备日志（崩溃报告等），只留在本地，`.gitignore` 里已忽略。

### 排错四：自己写 HEIF 容器（ImageIO 的 HEIC 在这台设备上就是不可用）

真机自检输出：

```
生成图 → PNG ：通过（1649 字节）
生成图 → JPEG：通过（1969 字节）
生成图 → HEIC：失败          ← 连代码生成的 8bit sRGB 图都编不出
真实资产：1242×2208 16bit/64bpp alpha=3 cs=DisplayP3 —— 原图与重画都失败
VideoToolbox HEVC：可用（会话创建 + Prepare 都成功）   ← ★ 硬件编码器是好的
```

⇒ **ImageIO 的 HEIC 编码器在这台设备上坏了**（同一张图编 PNG/JPEG 都成功），
而 **VideoToolbox 的 HEVC 编码器可用**。所以 `HEIFWriter`（在 `Converter.swift`）自己来：

```
CGImage → CVPixelBuffer(BGRA) → VTCompressionSession(HEVC, 单帧)
        → 按 ISO/IEC 23008-12 拼最小 HEIF：ftyp / meta(hdlr,pitm,iloc,iinf,iprp) / mdat
```

编码阶梯因此变成：ImageIO 原图 → ImageIO 重画去 alpha → **自建 HEIF**。全程不碰 CoreImage。

**容器格式先在本地验证过**（`build/.tools/heif_proto.py`，放在 gitignore 的 build/ 下）：
让 ffmpeg 的 libx265 产出真实的 hvcC 与 length-prefixed 码流，用**同一套盒子布局**写出 `.heic`，
ffprobe 能识别（`hevc 64×64`）、ffmpeg 能完整解码回 PNG，然后才把逻辑移植到 Swift ——
**不拿真机当编译器**。

### 自选转换：应用内选图 + 选图与 SQL 行对应

- 「在图库里选择照片」用 `PHPickerViewController`（进程内运行，不需要额外授权弹窗）。
  configuration 带 `photoLibrary: .shared()`，这才会有 `PHPickerResult.assetIdentifier` ——
  它就是"选中的这张图 → PHAsset → Photos.sqlite 里那一行"的纽带
- 只转换选中的这些：`convertSelected()` 按 localIdentifier 取回 PHAsset（保持选择顺序），
  已不在图库的会如实报数；走的是和全量扫描同一条流水线
- **对应关系是核对出来的，不是假设的**：转换后拿新建资产的 localIdentifier 反查数据库行，
  把该行的 `ZUUID` 与 localIdentifier 的 UUID 比对，结果写进「源图 ↔ 新资产」表。
  不吻合、或走了"最新一行"兜底定位的，会标橙提醒先人工核对
- 每张记一条：源图原始文件名、新资产 localIdentifier、解析到的 `Z_PK`、新文件名、
  `ZKINDSUBTYPE` 变化前后、UUID 是否吻合

### 依据

`ZKINDSUBTYPE = 10` 的含义出自社区取证查询库
<https://github.com/pecca86/Photos.Sqlite_Queries>（iOS 14/15 两份查询文件一致）；
「写这一列就能改变系统对资产的分类」由 PhotosDatabaseInspector 项目在真机上验证：改成 10 立刻变截图，
改回 0 又变回普通照片。
