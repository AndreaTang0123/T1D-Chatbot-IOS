# Joe — Standalone iOS Research App

原生 SwiftUI iPhone app。运行架构为 **iPhone → Nightscout HTTPS**；context、存储、Core ML 推理、Apple Foundation Models 和朗读均在手机上执行，不调用原来的 Python server、Mac mini、Tailscale、Ollama 或 Gemini。

**当前状态：已实现源代码和可测试的研究链路，尚未完成 Xcode/iPhone 真机验收。没有附带用户训练模型，也没有伪造预测。** 原始需求见 [implementation plan](IOS_STANDALONE_IMPLEMENTATION_PLAN.md)，实际交付与缺口见 [implementation status](docs/IMPLEMENTATION_STATUS.md)。

## 打开并安装

1. 安装完整 **Xcode 26 或更新版本**，iPhone 15 Pro 升级到 **iOS 26+**。本项目将 iOS 26 作为最低版本，以使用 Foundation Models；模型未启用/未下载时自动使用模板。[Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels)
2. 打开 `ios/JoeMobile.xcodeproj`，选择 `JoeMobile` scheme。
3. 在 Signing & Capabilities 选择你的 Apple Developer Team，必要时修改 bundle ID。需要支持 HealthKit 的签名/provisioning；entitlements 已提供。不要将个人签名配置提交到仓库。
4. 连接 iPhone、启用 Developer Mode，选择手机后 Run。开发安装由 Mac 完成；安装后日常运行无需 Mac。开发签名有有效期，长期安装需相应的开发者分发方式。
5. 在 app「设置」输入 **公开 HTTPS Nightscout 基础地址**和只读 access token，或 API secret 的 40 位 SHA-1。地址和凭据只保存在本机 Keychain。不要把 token 拼进基础地址。
6. 在「生活」分别启用 HealthKit、日历和定位；后台 Visits/地理围栏需要用户另行选择 Always 权限。

**第一项真机验收：** 关闭 Tailscale、关闭 Wi-Fi、通过蜂窝网络在 Safari 打开 Nightscout 的 `/api/v1/entries.json?count=1`（需要时进行认证），再在 app 刷新。如果 Nightscout 只能经 Tailscale 访问，必须先提供公开的认证 HTTPS 服务。

没有 Core ML 模型时，可以先同步真实 CGM/泵数据、采集 context、查看曲线和使用本地解释。预测栏明确显示「尚未安装训练好的 Core ML 模型」。

## 仓库结构

```text
Sources/JoeCore/             纯 Swift 数据类型、Nightscout 解码、特征与预测校验
Tests/JoeCoreTests/          核心测试与 Python/Swift 特征一致性 fixtures
ios/JoeMobile.xcodeproj/     可直接打开的 Xcode 工程与共享 scheme
ios/JoeMobile/              SwiftUI、SwiftData、系统服务、Core ML / Foundation Models
analysis/forecast/          数据构建、A–D 实验、训练、评估、Core ML 导出
scripts/                    工程生成、跨语言 fixtures、无 XCTest 核心检查
docs/                       特征定义、真机测试与实际交付状态
```

工程无需 CocoaPods、XcodeGen 或运行时第三方服务；使用仓库根目录的本地 Swift package。新增 Swift 文件或模型资源后执行：

```sh
python3 scripts/generate_project.py
```

生成器会重建 project.pbxproj；个人签名 Team 可在 Xcode 中重新选择。

## 测试

仅有 Command Line Tools 的 Mac：

```sh
swift build
python3 scripts/check_core.py
```

完整 Xcode 环境还可执行 `swift test`。CLI 检查运行同一份测试源码；不会把没有 XCTest 的环境错误伪装成 XCTest 通过。

训练/导出环境使用 Python 3.11（Core ML 的原生 macOS wheel 必须可用）：

```sh
python3.11 -m venv .venv311
.venv311/bin/pip install -r analysis/forecast/requirements.txt
cd analysis/forecast
../../.venv311/bin/python -m unittest -v test_pipeline.py
```

这些测试仅使用临时合成数据验证工程，不代表真实血糖预测效果。

## 训练并添加个人模型

1. 通过 app「设置 → 准备导出研究 JSON → 分享导出文件」保存本机数据。建议先收集数周数据；context 启用前的历史数据不能补造。
2. 在本机运行：

```sh
cd analysis/forecast
../../.venv311/bin/python build_dataset.py /absolute/path/Joe-research-export.json
../../.venv311/bin/python train.py data/dataset.json
../../.venv311/bin/python export_coreml.py
cd ../..
python3 scripts/generate_project.py
```

3. 查看 `analysis/forecast/artifacts/report.json` 的数据覆盖、A–D 实验和时间顺序测试指标。导出脚本在写入资源前验证 Python/Core ML 数值一致性。之后重新安装 app。
4. 使用 [真机测试清单](docs/DEVICE_TESTS.md) 完成设备上数值一致性与端到端验收，并收集 3–7 天 shadow-mode 结果。

训练使用 persistence、Ridge 和 Random Forest，按 70/15/15 时间切分，并隔离跨边界的未来标签。根据验证集选择 Ridge 特征组和 alpha；Random Forest 暂只用于离线比较。Core ML 为已折叠标准化的线性网络，CPU 推理；app 要求 38 个有序输入以及匹配 manifest。模型文件和研究数据默认不进入 git。

低血糖概率模型、IOB/COB 和临床误差网格尚未完成；不会用未经校准的值代替。验证集 P90 绝对误差只是研究性误差摘要，不是保证覆盖率的置信区间。

## 隐私与运行限制

- App 仅通过 URLSession 读取 Nightscout 的 entries、treatments、profile；不写入 Nightscout、不包含泵控制路径。
- SwiftData 不启用 CloudKit；Keychain 凭据为 ThisDeviceOnly，不记录 token/认证 URL。系统备份行为取决于用户的设备设置；导出后文件由用户选择的目标管理。
- Calendar 标题只用于瞬时本地分类，不保存标题、备注或参与者。HealthKit 只申请所需读取权限；空结果代表「无可用数据」，不能确定是否拒绝授权。[HealthKit 授权规则](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
- 位置默认保存类别与访问时间；用户主动命名地点时才保存该地点坐标，不保存连续轨迹。
- Apple 模型只生成受约束的解释重点；可见数值由四个本地工具填入模板。不可用或拒绝响应时自动降级。
- iOS 后台刷新、HealthKit observer、Visits 和地理围栏均是机会性更新，不能保证五分钟执行。不应依赖此 app 发出紧急预警。
- 自动剔除无效/未来/不在支持范围 40–400 mg/dL 的 CGM；界面明确区分测量、过期缓存和实验性预测。

研究观察用途；不能替代 CGM、治疗方案或临床判断。尚无真机续航、可用性或临床性能结论。
