# PNG2HEIF iOS 15+

这是一个面向 iOS 15+ 的本地 PNG → HEIF 工具。

## 功能

- 扫描 Photos 图片资产中的 PNG
- Image I/O 编码为 HEIF
- 保持原始分辨率
- 尽量复制原始元数据
- 保留原资产 creationDate / location / favorite
- 自动创建 `HEIF截图` 相簿
- 只有创建新 HEIF Photos 资产成功后才删除原 PNG
- 默认关闭删除原 PNG，建议先用少量照片测试

## GitHub Actions

项目包含 `.github/workflows/build.yml`。

GitHub Actions 使用 macOS 15 runner + Xcode，生成未签名 IPA。无需 Apple Developer 账号；可用于支持相应安装方式的设备。

## 注意

Photos 的“截图”系统智能相簿分类不是公开 API 可自由设置的属性，因此新 HEIF 资产使用普通 `HEIF截图` 相簿管理。
