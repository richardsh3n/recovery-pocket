# Recovery Pocket 0.4

原生 iPhone、Apple Watch、iPhone 桌面/锁屏组件、Watch 表盘组件四个目标。打开 RecoveryPocket.xcodeproj，选择 RecoveryPocket 方案。最低系统 iOS 17 / watchOS 10。

GitHub 源码快照：2026-10-06。开发 Team 已留空；真机安装前请配置自己的签名、Bundle ID 和 App Group。个人健康缓存、真机截图、安装记录与设备审计资料不包含在仓库中。

## 产品

暖白、深绿与消耗橙色的平面视觉；今日、身体、趋势、记录、我的五个入口。支持日期回看、电量曲线选点、训练与消耗时段、短休息计时、手动自评与事件记录，以及身体指标和个人历史比较。睡眠与日间 HRV 分开呈现。演示数据明确标记，并与真实记录隔离。

0.4 精简首页空状态，把详细统计折叠，新增可查看的实际模型输入和缺少时间覆盖提示；指标图表设置合理最小纵轴跨度，避免将小幅波动放大。本轮仅首页空状态取得有效新截图；其他页面互动、大字号、VoiceOver 和真实组件显示仍需继续验收。

## 数据与模型

HealthKit 只读：睡眠、HRV SDNN、心率、静息心率、活动能量、训练、步数、正念时段、呼吸率、睡眠腕温、血氧。没有服务器、账户或健康上传。前台、手动刷新及 HealthKit 系统通知触发读取，系统不保证连续实时更新。

睡眠 HRV 与心率独立建立个人历史基线；日间 SDNN 匹配来源、背景、时段与测量长度。电量用有界睡眠恢复曲线和持续时段账本；短时 HRV 只限制相应时段的清醒补充，按时间的清醒消耗限制在观测覆盖窗口，训练不重复扣心率负荷，缺失不补休息。新解释页提供样本数、HRV 实测分钟、分项变化与内部估计范围。

**全部分数仍是实验估计。** 起点 50、时间参数、热量系数和映射未经个人校准，内部范围不是经过验证的置信区间。不是 Garmin 的算法，也没有证明生理预测准确性。独立的 Whoordan 恢复对照保留 Apache 2.0 许可，要求真实静息心率；不替代全天电量。

## 验证

110 项核心逻辑检查通过，使用合成数据。四目标通过 Xcode 27 模拟器和真机 SDK 签名编译，手机安装与启动已确认。Ultra 一代实机兼容性和真实 Watch 同步尚未验收，当前使用 49mm Ultra 模拟器。MacPreview 是旧版合成演示，不能代表当前原生界面。

```sh
swiftc RecoveryPocket/RecoveryEngine.swift RecoveryPocket/RecoveryModelV2.swift Shared/BatteryModel.swift CoreTests/main.swift -o /tmp/recovery-pocket-tests
/tmp/recovery-pocket-tests
```

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project RecoveryPocket.xcodeproj -scheme RecoveryPocket -destination 'generic/platform=iOS Simulator' CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

真实安装为四目标配置同一开发 Team、Bundle ID 和 App Group。开发签名有有效期，后台读取和组件刷新由系统控制。未操作用量 Reset。

## 资料

- [开源审计及历史候选](OpenSourceAudit/开源与算法审计.md)
- [Whoordan 许可与适配](ThirdParty/Whoordan)
- [HealthKit 授权](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
- [App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)
- [WatchConnectivity](https://developer.apple.com/documentation/WatchConnectivity/transferring-data-with-watch-connectivity)
- [WidgetKit](https://developer.apple.com/documentation/widgetkit)


## 上传验证

核心合成数据检查与无签名 iOS 模拟器编译在上传前重新执行。交互验收及真实 Watch 同步仍未完成；分数是未经个人校准的实验估计。
