# IPA Assert Repair / IPA 修复

一个在 iPhone / iPad 上离线处理 IPA 的工具，用于修复旧版 SideStore / AltSign / ldid 的尾部边界断言：

```text
ldid.cpp(1461): _assert(): end >= size - 0x10
```

项目基于 [ios-ipa-ci-without-mac](https://github.com/Kevin589981/ios-ipa-ci-without-mac) 的 Flutter iOS 模板，使用 GitHub Actions 的 macOS runner 生成无证书、带临时 ad-hoc 签名的 IPA。

## 使用

1. 在 Releases 下载 `IPA-Assert-Repair-v1.0.0.ipa`，用 SideStore 安装，或导入 LiveContainer 运行。
2. 打开“IPA 修复”，从系统文件选择器导入需要处理的 `.ipa`。
3. 点“检查并生成修复包”，等待处理和验证完成。
4. 点“保存修复后的 IPA”，选保存位置，再用 SideStore 安装输出包。
5. 可以导出 JSON 检查报告。生成的文件也在本应用的 `Repairs` 文件夹。

安装本工具仍需要 SideStore / LiveContainer 提供签名环境。修复目标包不需要在工具中登录 Apple ID 或导入证书。没有上传、联网或后台服务。

## 修复范围

旧版 ldid 签整个应用目录时，会给输入缓冲区额外补齐字节。某些未签名 Mach-O 的字符串表末尾与文件末尾之间已有填充，叠加后超过断言允许的 16 字节。

工具逐一解析 Mach-O，并按真实的旧版目录签名规则计算边界。仅对触发检查、尾部是零填充、头部有足够空间的未签名文件，补充 SHA-256 ad-hoc 签名和 `LC_CODE_SIGNATURE`。已有且边界正常的签名保持原样。

- 支持 thin 32/64 位、小端/大端和 FAT32 多架构容器。
- 断言允许 `0 <= boundary - stringTableEnd <= 16`；恰好 16 字节也通过。
- 原 Bundle ID、所有 Info.plist、已有权限文件和业务代码/数据保持原样。
- ZIP 文件路径、内容、Unix 权限和 DOS 时间戳验证后导出。未修改文件的压缩数据直接复制。
- 对已有异常签名、非零尾部、没有头部空间、加密 Mach-O、FAT64 等情况停止并解释原因。
- 输入 IPA 限 512 MB，单文件限 128 MB，解压总量限 2 GB。处理在独立 Dart isolate 中执行。

工具专门处理这一类兼容问题，不提供通用解密、证书签名或任意损坏修复。导出包是等待 SideStore 再签名的预处理产物。边界通过不等于所有应用都能在 iOS / LiveContainer 上运行。

## 构建和验证

Flutter 固定为 **3.35.4**，依赖由 `pubspec.lock` 固定。推送 main 或手动运行 `Build IPA Repair`：

```sh
flutter pub get --enforce-lockfile
flutter analyze --fatal-infos
flutter test
flutter build ios --release --no-codesign
bash scripts/package_unsigned_ipa.sh build/ios/iphoneos/Runner.app IPA-Assert-Repair.ipa
```

打包脚本来自 method 模板的修正版，从内到外对框架和主应用签名，并验证所有 Info.plist 未改变。CI 再使用本工具检查自身 IPA，必须没有需要修复的文件。

同一个 Dart 核心也可以在 Windows / Linux / macOS 命令行运行：

```sh
dart run tool/repair.dart original.ipa new-output.ipa
```

输出文件存在时会拒绝覆盖。公开仓库的测试只使用自行生成的合成文件，不包含真实用户 IPA。

## 技术依据

- [旧版 ldid 断言](https://github.com/SideStore/ldid/blob/6a6a92de56ae2110e4d6f292b315df0f586d6af5/ldid.cpp#L1457-L1462)
- [旧版目录签名的额外补齐](https://github.com/SideStore/ldid/blob/6a6a92de56ae2110e4d6f292b315df0f586d6af5/ldid.cpp#L2882-L2892)

主应用 Bundle ID：`com.kevin3627713.ipaAssertRepair`。最低 iOS 15。MIT 许可证。
