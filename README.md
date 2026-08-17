# PNG2HEIF — iOS 15+

一个面向 iOS 15+ Photos 图库的本地 PNG → HEIF 批量转换工具。

## 目前功能

- 扫描 Photos 图库中的截图资产
- 只处理 PNG
- 使用 Image I/O 编码 HEIF
- 保持原始分辨率
- 尽量复制原始图像元数据
- 新资产使用原截图的 `creationDate`
- 可加入 `HEIF截图` 相簿
- 只有新 HEIF 资产创建成功后才删除原 PNG
- 支持逐张处理，避免一次性加载大量图片
- 全程本地处理

> 注意：Photos 的“截图”智能相簿 subtype 不是公开 API 可写属性，因此新 HEIF 默认进入普通的 `HEIF截图` 相簿，而不保证继续出现在系统“截图”智能相簿。

## Windows 用户：用 GitHub Actions 编译

本项目包含：

`.github/workflows/build.yml`

它会在 GitHub 的 macOS runner 上使用 Xcode 编译**未签名 IPA**，然后把 IPA 作为 Actions Artifact 提供下载。

### 步骤

1. 在 GitHub 新建一个空仓库。
2. 把整个项目目录上传，包括 `.github/workflows/build.yml`。
3. 打开仓库的 **Actions**。
4. 选择 **Build PNG2HEIF IPA**。
5. 点击 **Run workflow**。
6. 编译完成后，在该 workflow 的 **Artifacts** 区域下载 `PNG2HEIF-unsigned-ipa`。
7. 将 IPA 传到 iPhone，用 TrollStore 安装。

### 为什么不需要 Apple Developer 签名

Workflow 使用：

- `CODE_SIGNING_ALLOWED=NO`
- `CODE_SIGNING_REQUIRED=NO`
- `AD_HOC_CODE_SIGNING_ALLOWED=NO`

因此它生成的是未签名 IPA，适合由 TrollStore 处理。

## 第一次测试建议

先关闭 App 中的“转换成功后删除 PNG”，只处理少量截图，例如 5–10 张。确认：

- HEIF 能正常打开
- 分辨率没有变化
- 日期正确
- `HEIF截图` 相簿正常
- 最近项目的排序符合预期
- 文件体积明显下降

确认无误后再启用删除原 PNG。
