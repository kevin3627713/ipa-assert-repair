# iOS 工程

本目录包含完整 Flutter iOS 工程，基于 method 模板。

- Bundle ID：`com.kevin3627713.ipaAssertRepair`。
- 最低 iOS：15.0。
- `AppDelegate.swift` 使用系统文件选择器，通过 MethodChannel 导入和导出文件。
- 文件处理核心在 Dart isolate 中运行，不调用外部二进制或联网服务。
- 版本号由 Flutter 构建参数注入。
- GitHub Actions 使用 `--no-codesign` 编译，再用打包脚本添加无证书 ad-hoc 签名。

具体构建和使用方法见项目根目录的 README。
