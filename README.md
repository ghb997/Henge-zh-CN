<p align="center"><img src="docs/icon.png" width="120" height="120" alt="Henge"></p>

# Henge 简体中文版

在 iPhone 和 iPad 上运行 macOS。

本项目由 ghb997 基于 Leviidev 的 Henge 制作，提供简体中文界面、安装向导、JIT 设置、无障碍标签和常见错误提示。中文版本修改日期为 2026 年 11 月 9 日，上游基线提交为 `f9e00023532ad29d3cefdb952c00762715934b80`。[原项目](https://github.com/Leviidev/Henge)

## 下载与安装

从本仓库 Releases 下载 `Henge-zh-CN.ipa`，使用 SideStore 或 AltStore 签名并安装。发布包采用 ad-hoc 签名，侧载工具会使用你的证书重新签名。运行要求为 iOS / iPadOS 17 或更高版本，以及 A14 / M1 或更新的芯片。[下载中文版](https://github.com/ghb997/Henge-zh-CN/releases)

1. 安装后打开“Henge 中文”。
2. 在“设置”中配置并启用 JIT。上游支持 StikDebug、适用系统上的 TrollStore / TrollStore Lite，以及 iOS 26 及以上的内置 StikJIT。内置方案需要按照向导完成 LocalDevVPN 和设备配对。
3. 打开“安装”，推荐选择 macOS Sequoia 15.6.1。安装期间保持 Henge 在前台并连接电源。
4. 安装完成后，在后台上划关闭 Henge，再次打开并轻点“启动”。

macOS Sequoia 安装过程需要约 43 GB 可用空间，其中约 17 GB 用于下载安装镜像，约 26 GB 用于虚拟 Mac。安装镜像可在安装完成后删除。每台 Mac 可以分配 4、6 或 8 GB 内存。支持 increased-memory-limit 权限的签名证书可提高应用内存上限。

## 功能

- 自有 ARM64 JIT、MMU 和虚拟设备，运行 macOS 的 ARM64 代码。
- 从 Apple 下载安装镜像，并直接在设备上完成 macOS 安装。
- 通过虚拟 GPU 和 Metal 显示 macOS 画面。
- 触控屏可作为触控板，长按拖动，双指滚动。屏幕键盘提供 Esc、Tab、Control、Option 和 Command 等按键。
- iPad 支持妙控键盘、蓝牙键盘与鼠标。
- 通过支持视频输出的 USB-C 线缆或扩展坞连接外接显示器，在显示器上显示 Mac，设备保留触控板和键盘控制。
- 支持与虚拟 Mac 共享剪贴板和文件夹。

## 与 Mac 共享文件

在虚拟 Mac 中打开“终端”，然后在 Henge 的“详情”中轻点“输入设置命令”。在 Mac 中按回车键，并在系统询问 `henge-agent` 的本地网络权限时选择允许。输入命令时，Mac 的键盘布局需要设为“美国”。

完成后，Mac 用户目录中的 `Henge` 文件夹对应 iOS“文件”App 中的 `Henge / Shared`。Mac 上复制的内容会同步到设备，Henge 的粘贴按钮可将设备剪贴板内容粘贴到 Mac。

## 已知限制

- 上游报告，在 macOS 中登录 Apple 账户会出现验证错误。
- 图形兼容性仍在完善，部分应用可能显示异常。
- macOS 登录后的前几分钟会执行后台初始化，应用启动可能较慢。
- 每次打开 Henge 只能启动一台 Mac。切换 Mac，或在 macOS 关机、重启后再次启动，需要关闭并重新打开 Henge。
- iPadOS 会保留部分键盘快捷键，例如 Command-Tab。
- 实际速度取决于设备与负载，模拟运行会产生额外开销。
- 中文版覆盖 Henge 自身界面。macOS 内部语言可在 macOS“系统设置”中选择。诊断日志、第三方组件返回的原始错误和产品名称可能包含英文。

上游主要在 iPhone 17 Pro 上验证运行，iPad 支持仍需要更多真机验证。中文版的构建和测试结果可在 Actions 查看，真机安装、JIT 启用和 macOS 启动需要在目标设备验证。[构建记录](https://github.com/ghb997/Henge-zh-CN/actions)

## 构建 IPA

在本仓库 Actions 中运行 `Build Henge Chinese IPA` 工作流。工作流使用 GitHub 托管的 `xcode-27` macOS runner，执行现有 Swift 编译检查、显示路由测试和 JIT 建议测试，然后打包 IPA。完成后可下载 `Henge-zh-CN-ipa-<提交号>` artifact。

Husk 依赖固定为 `afe83d45b31194c4cc9f7b3db7ec2c757db8346e`，工作流会构建网络库和设备配对库。依赖源码、编译命令和缓存路径见工作流文件。[工作流](.github/workflows/build-henge.yml)

本地构建需要 macOS、Xcode 27 或更高版本、`xcodegen`，以及已构建的 Husk。将 `HUSK` 指向该目录，并将 `IOS_DEPS` 指向其中的 `build/ios-arm64/sysroot`，然后运行以下命令。

```bash
ios/scripts/fetch_deps.sh
tools/build_ios_restore.sh
make ios-lib
ios/scripts/package_ipa.sh
```

输出位于 `~/Desktop/Henge.ipa`。`package_ipa.sh --trollstore` 可生成适用于相应环境的 `Henge.tipa`。`make` 可构建 Mac 命令行引擎，`make test` 可运行引擎测试。

## 许可证与致谢

Henge 原作者为 Leviidev，遵循 GPL-2.0-or-later。中文翻译和构建调整沿用项目开源许可。完整版权声明、第三方许可与许可兼容性说明保留在仓库和应用资源内。[许可证](LICENSE) · [第三方许可说明](docs/licensing.md)

macOS 和启动 ROM 的权利属于 Apple。Henge 在设备安装过程中从 Apple 获取所需文件。发布的 IPA 仅包含应用及其开源组件。
