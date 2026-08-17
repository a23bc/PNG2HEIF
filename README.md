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

新建的 HEIF Photos 资产无法通过公开 PhotoKit API 任意设置为系统“截图”智能相簿的 screenshot subtype，因此程序使用普通 `HEIF截图` 相簿管理。
