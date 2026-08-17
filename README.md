# PNG2HEIF iOS 15+ — TrollStore

本版本修复：
- TrollStore parse error 303
- 主二进制显式设置为 PNG2HEIF
- IPA 打包前后均验证 Mach-O arm64

本版本新增：
- 转换过程中显示实时进度
- 「停止转换」按钮
- 停止时不会启动下一张
- 当前正在进行的单张资源写入/Photos 事务完成后停止
- 原 PNG 仍然只有在新 HEIF 成功创建后才会删除

使用建议：
1. 第一次关闭「转换成功后删除 PNG」。
2. 先测试 5～10 张。
3. 检查日期、分辨率、相簿和最近项目排序。
4. 确认无误后再开启删除。

GitHub Actions 生成 PNG2HEIF-TrollStore.ipa。
