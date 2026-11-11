# PNG2HEIF — iOS 15+ / TrollStore

把照片库里的 **PNG 截图批量转换成 HEIF**，导入回照片库，并让它**看起来就像原来那张截图**：
同名、同时间、同排序位置、同色域、带系统"截图"分类。面向 iOS 15+，以**未签名 IPA** 经
TrollStore 安装。

当前状态：**主线功能完工**（build 20）。转换、导入、截图标记、无缝替换（文件名/排序/时间/色域）
均已在真机验证闭环。

---

## 功能

- **扫描 / 自选转换**：全量扫描图库 PNG，或用 `PHPicker` 在应用内选若干张转换。
- **PNG → HEIF**：VideoToolbox 编 HEVC + 手工封装 HEIF 容器（原因见下）。
- **导入照片库**：`PHAssetCreationRequest`，保留原创建时间、位置、收藏。
- **截图标记**：写 `Photos.sqlite` 的 `ZASSET.ZKINDSUBTYPE = 10`（SpringBoard 截图分类）。
- **无缝替换**（随标记开关一起生效）：
  - 文件名保持原样：DCIM 物理改名 + 同步 `ZASSET.ZFILENAME`（重名保护、失败回滚）；
  - 排序回原位：带原图 `ZASSET.ZSORTTOKEN`；
  - 色域保留：源为 Display P3 时全程保留 P3（`colr` nclx primaries=12）。
- **数据库面板**：探测信息、最近行 `kind/cloud/Z_PK/文件名/时间`、逐行「设为截图 10 / 还原 0」、
  「源图 ↔ 新资产」对应表（含定位核对与无缝替换结果）。
- **编码自检**：PNG/JPEG/HEIC 编码对照、容器变体回读、VideoToolbox/CVPixelBuffer 探测、
  已有 HEIC 解码对照、**副本索引实验**（只改副本，见下）。

## 为什么自己写 HEIF 容器

目标设备有三个实测的设备级缺陷（自检可复现）：

| 组件 | 实测结果 |
| --- | --- |
| CoreImage | 创建 `CIContext` 在 `CI::GLContext` 空指针崩溃 → **全程不碰 CoreImage** |
| ImageIO HEIC 编码 | 连代码生成的 8bit sRGB 图都编不出（PNG/JPEG 正常）→ 设备级不可用 |
| IOSurface | `CVPixelBuffer` 带 IOSurface 属性返回 `-6662`(AllocationFailed) → 用普通 CVPixelBuffer |
| VideoToolbox HEVC | **可用**（会话创建 + Prepare 成功）→ 用它编码 |

因此管线为：

```
CGImage → CVPixelBuffer(BGRA, 无 IOSurface, 附色彩空间)
        → VTCompressionSession(HEVC, 单帧, 强制关键帧)
        → 手工 HEIF 容器：ftyp / meta(hdlr,dinf,pitm,iinf,iprp,iloc) / mdat
```

容器要点（均经真机 + 本地 ffmpeg 双重验证）：

- `infe` 必须 **version 2**（带 4 字符 `item_type=hvc1`）；version 0 会让解析器把 `hvc1`
  当成 item_name，整个 item 不被识别（曾导致所有容器变体解码失败）。
- `hvc1` item 只放 **VCL 切片 NAL**（4 字节长度前缀）；VPS/SPS/PPS 只在 `hvcC`。
- `iloc` 偏移为文件绝对偏移；`ipma` 中 `hvcC` 标 essential。
- 色域：`colr` nclx，P3=primaries 12 / sRGB=1，transfer 13，matrix 1，full range。

容器布局先在本地用 ffmpeg 验证（`build/.tools/heif_proto.py`，gitignore）：libx265 产出真实
hvcC 与码流 → 同一套盒子布局写 `.heic` → ffprobe/ffmpeg 能识别并解码回 PNG → 才移植到 Swift。
**不拿真机当编译器。**

## Photos.sqlite 集成与写入纪律

公开 PhotoKit 设不了截图分类，故直接写 Photos 实际读取的列。杠杆与结论：

| 目标 | 杠杆 | 说明 |
| --- | --- | --- |
| 截图分类 | `ZASSET.ZKINDSUBTYPE=10` | 单列即够（真机验证）；`ZCLOUDKINDSUBTYPE` 暂不写 |
| 文件名 | `ZASSET.ZFILENAME` + DCIM 物理改名 | 公开 API 只能设 `ZORIGINALFILENAME`（相册显示名） |
| 排序位置 | `ZASSET.ZSORTTOKEN` | **不是 Z_PK**；Z_PK 只是插入顺序 |
| 创建时间 | PhotoKit `creationDate` | 导入时带上，落 `ZDATECREATED` |

**写入纪律**：`SQLITE_OPEN_READWRITE` + 一条 `UPDATE` + 一行 + 绑定参数；写前读旧值、写后回读；
不做 DDL、不改 `journal_mode`、不 `checkpoint`、不 `VACUUM`、**不 DELETE**。定位不到目标行就
什么都不写，绝不改来路不明的行。

**定位新资产**：用 `localIdentifier` 的 UUID 匹配 `ZASSET.ZUUID`（带重试）。注意导入瞬间新行 /
ZUUID 有 **WAL 可见性延迟**，回读可能暂时为空——不能拿"读不到"当否决证据；只有"读到且 UUID 不等"
才判错行。无缝替换的行读取同样带重试。

**改 Z_PK 索引：此路不通（副本实验实锤）**。ZASSET 挂 Core Data 触发器，调用仅 Photos 进程运行时
注册的 SQL 函数 `NSCoreDataTriggerUpdateAffectedObjectValue`；裸 sqlite 连接 DELETE 会
`no such function` 失败，而 Z_PK 唯一 ⇒ 改 PK 必 `UNIQUE constraint failed`。绕开只能删触发器
(DDL)=库级破坏，不可取。自检里的「索引实验」**只在 Photos.sqlite 的副本上**模拟改 PK + 级联外键并
跑 integrity/foreign_key 检查，真库零写入。

**权限**：entitlements（`no-sandbox`、`platform-application` 等）必须塞进 Mach-O 的
`__TEXT,__entitlements` 段（ldid/TrollStore 读段而非签名），CI 用
`OTHER_LDFLAGS=-Wl,-sectcreate,__TEXT,__entitlements,...` 硬塞并硬检查。**不要**加
`container-required=false`/`no-container=true`——那会连数据容器一起去掉，临时目录/Documents
消失导致转换全失败。

## 构建与安装

- GitHub Actions（`.github/workflows/build.yml`，macOS runner）编译 **未签名** iOS 归档并打包
  `PNG2HEIF-TrollStore.ipa`；打包前后硬检查主 Mach-O（arm64、`CFBundleExecutable` 一致、
  `__entitlements` 段、codesign entitlements）。
- 分支 push 不触发（仅 main/master push + `workflow_dispatch`）；开发分支用
  `gh workflow run build.yml --ref <branch>` 手动出包。
- 本机无 Mac，**CI 是唯一编译器**；产物下载后解包核验 `CFBundleVersion` 再交付。
- TrollStore 安装。**重装后必须强退重开**：旧进程会继续跑旧二进制，而表头 build 号读磁盘 plist
  会"谎报"；自检首行与对应表 note 打印**编译期烧入的 `compiledBuild`** 用以识破。

## 使用

1. 首次建议**关闭**「转换成功后删除 PNG」，先转 5–10 张核对时间/分辨率/色域/Photos 显示。
2. 打开「转换后写入截图标记」后，每张转换成功的资产会写 `ZKINDSUBTYPE=10` 并做无缝替换
   （同名 + 同排序）。对应表会给出结果；若报「UUID 不吻合」会附新/行 UUID 与 zpk 供核对。
3. 确认无误后再开删除原 PNG。
4. respring / 重启 Photos 后点「刷新数据库状态」：值仍在 ⇒ 数据库是权威；被写回 ⇒ 只是缓存。
5. 批量前先用单张验证"照片能正常打开、出缩略图"（证明物理改名没弄坏资源解析）。

## 已知边界 / 可选未做

- **EXIF 时间串**（`ZEXIFTIMESTAMPSTRING`）未嵌入：HEIC 无 Exif item。Photos 排序/显示用
  `ZDATECREATED`（已带原时间），故仅对直接读文件 EXIF 的外部工具有意义；收益小，默认不做。
- 分析类字段（美学评分/场景/文字识别/`ZMEDIAANALYSIS…`）导入后为 null 属正常，由 iOS
  mediaanalysisd 异步填充，非本 App 职责。
- `ZCLOUDKINDSUBTYPE`（真实截图为 3）暂只观察不写。
- 诊断/实验代码（六变体回读、Apple 瓦片二分、索引实验、UUID 详细诊断）已完成使命，
  可保留作安全诊断或后续清理包移除。

## 代码布局

- `PNG2HEIF/PhotoLibraryService.swift` — 转换管线、`HEIFWriter`（VT+容器）、`ScreenshotSubtype`
  （SQLite 读写）、`IndexExperiment`（副本实验）、自检。
- `PNG2HEIF/ContentView.swift` — UI（扫描/自选/开关/数据库面板/对应表/自检）。
- `PNG2HEIF/Converter.swift` — 辅助 view-model / 错误类型。
- `PNG2HEIF/PNG2HEIFApp.swift` — 入口。
- `PNG2HEIF/PNG2HEIF.entitlements`、`Info.plist` — 权限与版本（`CFBundleVersion` 每轮递增）。
- `.github/workflows/build.yml` — 未签名 IPA 构建 + 硬检查。
- `build/.tools/`（gitignore）— 本地参考原型与推送/取产物脚本；`logs/`（gitignore）— 设备日志。

## 依据

`ZKINDSUBTYPE=10` 的含义出自社区取证查询库
<https://github.com/pecca86/Photos.Sqlite_Queries>（iOS 14/15 查询一致）；"写该列即改变系统分类"
经真机验证（改 10 变截图、改 0 还原）。
