import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { wantAgent } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';

// 🟢 修复方案：定义一个临时接口来替代 any
// 既然你知道 item 里一定有 reminderId，就显式地定义出来
interface ReminderItem {
  reminderId: number;
}

// 定义ReminderRequest的扩展接口，包含reminderId属性
interface ReminderRequestWithId {
  reminderId?: number;
}

// 定义WantAgent接口，包含必要的属性
interface WantAgent {
  pkgName: string;
  abilityName: string;
}

export class ReminderHelper {
  // 1. 发布倒计时提醒
  static async publishTimerReminder(context: common.UIAbilityContext, seconds: number) {
    // 🛡️ 安全检查
    await ReminderHelper.cancelAllReminders();

    if (seconds <= 0) {
      return;
    }

    let wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }
      ],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      // 🟢 修复1：使用正确的类型声明
      let agent = await wantAgent.getWantAgent(wantAgentInfo);

      const timerReq: reminderAgentManager.ReminderRequestTimer = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER,
        triggerTimeInSeconds: seconds,
        actionButton: [
          {
            title: '回到应用',
            type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE
          }
        ],
        title: '⏳ 专注任务完成',
        content: '预设时间已到，点击查看详情',
        expiredContent: '时间到！',
        snoozeTimes: 0,
        ringDuration: 10,
        slotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        // 🟢 修复：使用类型断言匹配期望的类型
        wantAgent: agent as WantAgent,
        notificationId: 9999
      };

      const reminderId = await reminderAgentManager.publishReminder(timerReq);
      console.info(`✅ [代理提醒] 已托管给系统, ID: ${reminderId}`);

    } catch (err) {
      const error = err as BusinessError;
      console.error(`❌ [代理提醒] 设置失败: ${error.message}`);
    }
  }

  // 2. 取消当前应用所有的代理提醒
  static async cancelAllReminders() {
    try {
      const reminders = await reminderAgentManager.getValidReminders();
      for (let item of reminders) {
        // 🟢 修复3：使用安全的属性访问方式
        let id = (item as ReminderRequestWithId).reminderId;

        if (id) {
          console.info(`🧹 清理旧提醒 ID: ${id}`);
          await reminderAgentManager.cancelReminder(id);
        }
      }
    } catch (err) {
      // 这里的 err 通常是 unknown，转为 string 或 BusinessError 处理
      console.error(`❌ 清理提醒失败: ${JSON.stringify(err)}`);
    }
  }
}