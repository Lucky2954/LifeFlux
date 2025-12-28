# LifeFlux (人生流)

LifeFlux 是基于 **HarmonyOS NEXT** 开发的一款全域在线生活模拟与任务管理应用。它不仅是一个任务清单，更是一个通过时间管理来量化人生进程的工具。

## 🚀 核心功能

- **任务管理体系**：支持多级任务分类（一级大类 -> 二级明细），灵活规划生活与工作。
- **专注番茄钟**：内置可自定义时长的专注计时器，通过音频驱动实现高可靠性的后台计时。
- **后台持久运行**：利用 HarmonyOS 的 **AVSession (媒体会话)** 和 **后台长时任务** 技术，确保即使应用退到后台或锁屏，计时与提醒依然精准运行。
- **智能提醒**：
  - 任务进行时的实时进度通知。
  - 任务结束时的强提醒（闹铃 + 循环震动）。
- **数据云同步**：深度集成 **飞书多维表格 (Feishu Bitable)**，所有任务记录、时长统计自动同步上云，方便复盘与分析。
- **沉浸式体验**：全屏透明背景设计，提供极致的沉浸感与现代 UI 体验。

## 🛠️ 技术亮点

- **ArkTS & ArkUI**：采用最新的声明式 UI 开发范式。
- **GuardianService**：独创的守护服务单例，统一管理计时器、音频驱动与后台任务状态。
- **Audio & AVSession**：
  - 使用静音音频流（Silent Loop）实现系统级的后台保活。
  - 动态更新 AVSession 元数据，在播控中心实时显示任务剩余时间。
- **通知与震动**：
  - 自定义 `Notification` 发送常驻进度条。
  - 使用 `Vibrator` 模块实现自定义频率的触感反馈。

## 📦 目录结构

```
/AppScope       # 全局应用配置与资源
/entry
  ├── src/main/ets
  │    ├── entryability  # 应用入口 Ability
  │    ├── pages         # UI 页面 (Index.ets)
  │    └── common        # 核心逻辑模块
  │         ├── GuardianService.ts  # 守护服务 (核心)
  │         ├── FeishuService.ts    # 飞书 API 封装
  │         ├── NotificationHelper.ts # 通知管理
  │         ├── ReminderHelper.ts   # 系统代理提醒
  │         └── FileLogger.ts       # 本地日志工具
  └── resources          # 应用资源 (图片、音频、字符串)
```

## ⚙️ 环境要求

- **DevEco Studio**: NEXT Beta1 及以上版本
- **SDK**: HarmonyOS NEXT (API 11+)
- **权限**: 需开启通知权限及后台任务权限

## 📝 开发与贡献

欢迎提交 Issue 或 Pull Request 来完善 LifeFlux！

## 📄 许可证

MIT License
