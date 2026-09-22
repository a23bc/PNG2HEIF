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

### 依据

`ZKINDSUBTYPE = 10` 的含义出自社区取证查询库
<https://github.com/pecca86/Photos.Sqlite_Queries>（iOS 14/15 两份查询文件一致）；
「写这一列就能改变系统对资产的分类」由 PhotosDatabaseInspector 项目在真机上验证：改成 10 立刻变截图，
改回 0 又变回普通照片。
