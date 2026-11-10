# Recovery Pocket

面向 iPhone 和 Apple Watch 的实验性身体电量 App。它读取 Apple 健康中的睡眠、心率、HRV 和活动记录，在手机端估算日内电量变化，并把摘要同步到手表及组件。

## 0.33.0

- **每日电量回顾**显示补充、消耗和可比较曲线的覆盖时间。点选变化最大的区间，可以查看曲线和计算分项。
- **每周回顾**对照睡眠目标、活动能量和主观精力，可回到对应日期查看当天记录。
- **习惯与精力对照**比较明确记录「有」和「无」的日子，展示样本数及仍需补齐的天数。
- **手表电量回顾**显示今日补充、消耗、曲线范围和覆盖时间。工程也包含 iPhone 小组件与 Watch 表盘组件。

分数是基于可用数据的实验估计，尚未完成个人生理校准。没有足够数据的时段留空。

## 构建与检查

已用 Xcode 27.2 验证。工程最低部署版本为 iOS 17 和 watchOS 10。

在 Xcode 打开 `RecoveryPocket.xcodeproj`，选择 `RecoveryPocket` 方案和一个 iPhone 模拟器。可在 App 的「我的」中打开「体验演示数据」。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project RecoveryPocket.xcodeproj -scheme RecoveryPocket \
  -destination 'generic/platform=iOS Simulator' CODE_SIGN_IDENTITY=- build

python3 Verification/run_checks.py
```

源码包的四个目标均通过模拟器构建。回归检查使用合成数据。0.33.0 的 iPhone 和 Apple Watch Ultra 一代真机安装、同步与表盘刷新待验收。

真机开发需要配置自己的 Apple 开发 Team、各目标的 Bundle ID 和 App Group。修改 Bundle ID 时，同步更新手表的 `WKCompanionAppBundleIdentifier`。修改 App Group 时，同步更新各目标的 entitlements 和 `Shared/StatusStore.swift`。

## 数据与集成

App 通过系统授权只读 Apple 健康数据。默认使用本机解读。启用可选 AI 后端时，会向所选服务发送经整理的摘要。原始健康记录、配对文件、签名和个人调试资料不随源码分发。

- [可选的 Mac 桥接](Integration/CodexBridge/使用说明.md)
- [餐次数据接入约定](Integration/PhotoFood/接入约定.md)
- [Whoordan 来源与许可](ThirdParty/Whoordan/NOTICE.md)
- [历史算法审计](OpenSourceAudit/开源与算法审计.md)
