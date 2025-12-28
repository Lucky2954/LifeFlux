import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { NotificationHelper } from '../common/NotificationHelper';

import { GuardianService } from '../common/GuardianService'; // 引入守护服务

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  // 1. 定义变量保存 windowStage，以便后续使用
  private windowStage: window.WindowStage | undefined = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    
    // ✅ 初始化守护服务单例
    GuardianService.getInstance().init(this.context);
  }

  // ✅✅✅ 关键修复：处理“热启动”逻辑
  // 当应用在后台（计时器运行中）被 startAbility 调用时，会走这里
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', 'Ability onNewWant Triggered');

    if (this.windowStage) {
      // 异步获取主窗口
      this.windowStage.getMainWindow().then((win) => {
        // 1. 强制显示窗口（防止窗口处于隐藏状态）
        win.showWindow();

        // 2. 核心：将窗口提升到应用的最顶层
        // 配合 module.json5 的 singleton 模式，这能让界面覆盖在其他应用之上
        win.raiseToAppTop();

        // 3. 确保全屏布局（保持你的透明背景设计）
        win.setWindowLayoutFullScreen(true);
      }).catch((err: Error) => {
        hilog.error(DOMAIN, 'testTag', 'Failed to get main window: ' + JSON.stringify(err));
      },
      );
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 2. 保存 windowStage 实例
    this.windowStage = windowStage;

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
    });

    windowStage.getMainWindow().then((win) => {
      win.setWindowBackgroundColor('#00000000');
      win.setWindowLayoutFullScreen(true);
    });
  }

  onForeground(): void { hilog.info(DOMAIN, 'testTag', 'Ability onForeground'); }
  onBackground(): void { hilog.info(DOMAIN, 'testTag', 'Ability onBackground'); }
  async onDestroy(): Promise<void> {
    hilog.info(DOMAIN, 'testTag', 'Ability onDestroy');
    // ❌ 不要在这里清理资源！这会导致后台保活失败。
    // GuardianService 会自己管理资源的生命周期。
    // await NotificationHelper.cleanup();
  }
  onWindowStageDestroy(): void { hilog.info(DOMAIN, 'testTag', 'Ability onWindowStageDestroy'); }
}