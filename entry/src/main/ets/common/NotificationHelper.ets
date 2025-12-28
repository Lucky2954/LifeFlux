import notificationManager from '@ohos.notificationManager';
import vibrator from '@ohos.vibrator';
import { common } from '@kit.AbilityKit';
import { wantAgent } from '@kit.AbilityKit';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class NotificationHelper {
  static readonly NOTIFICATION_ID = 1001;
  static player: media.AVPlayer | undefined;
  static silentPlayer: media.AVPlayer | undefined; // ✅ 新增：专门用于保活的静音播放器

  // ✅ 新增：震动定时器 ID，用于循环震动
  static vibrationTimerId: number = -1;

  // ✅ 新增：清理所有静态资源
  static async cleanup() {
    try {
      // 停止所有播放器
      if (NotificationHelper.player) {
        await NotificationHelper.player.stop();
        await NotificationHelper.player.release();
        NotificationHelper.player = undefined;
      }
      
      if (NotificationHelper.silentPlayer) {
        await NotificationHelper.silentPlayer.stop();
        await NotificationHelper.silentPlayer.release();
        NotificationHelper.silentPlayer = undefined;
      }
      
      // 清理定时器
      NotificationHelper.stopVibrationLoop();
      
      console.info('NotificationHelper 资源已清理');
    } catch (err) {
      console.error('清理NotificationHelper资源失败:', JSON.stringify(err));
    }
  }

  // 1. 初始化通知渠道
  static async initNotificationSlot() {
    try {
      const mySlotType = notificationManager.SlotType.SERVICE_INFORMATION;
      await notificationManager.addSlot(mySlotType);
      console.info('通知渠道初始化成功');
    } catch (err) {
      const error = err as BusinessError;
      console.error(`创建通知渠道失败: ${JSON.stringify(error)}`);
    }
  }

  // 2. 发送进度通知
  static async publishProgress(minutes: string, seconds: string, progress: number) {
    let wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [{ bundleName: "com.example.better", abilityName: "EntryAbility" }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    let agent = await wantAgent.getWantAgent(wantAgentInfo);

    let notificationRequest: notificationManager.NotificationRequest = {
      id: NotificationHelper.NOTIFICATION_ID,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: '⏳ 任务进行中',
          text: `剩余时间：${minutes}:${seconds}`,
          additionalText: `进度 ${progress}%`
        }
      },
      isOngoing: true,
      wantAgent: agent
    };

    try {
      await notificationManager.publish(notificationRequest);
    } catch (err) {
      const error = err as BusinessError;
      console.error(`通知发送失败: ${JSON.stringify(error)}`);
    }
  }

  // ✅ 新增：启动静音保活 (在开始计时时调用)
  static async startSilentKeepAlive(context: common.Context) {
    try {
      if (NotificationHelper.silentPlayer) {
        await NotificationHelper.silentPlayer.reset();
      } else {
        NotificationHelper.silentPlayer = await media.createAVPlayer();
      }

      NotificationHelper.silentPlayer.on('stateChange', async (state) => {
        if (state === 'initialized') {
          NotificationHelper.silentPlayer!.audioRendererInfo = {
            usage: audio.StreamUsage.STREAM_USAGE_MUSIC, // 必须是 MUSIC
            rendererFlags: 0
          };
          await NotificationHelper.silentPlayer!.prepare();
        } else if (state === 'prepared') {
          NotificationHelper.silentPlayer!.loop = true; // 循环播放

          // ✅ 关键策略：不要设为 0，设为极小值 (0.01) 防止被系统检测为无效播放
          NotificationHelper.silentPlayer!.setVolume(0.01);

          await NotificationHelper.silentPlayer!.play();
        }
      });

      // 读取白噪音文件
      let fileDescriptor = await context.resourceManager.getRawFd('silence.mp3');
      NotificationHelper.silentPlayer.fdSrc = fileDescriptor;

      console.info('✅ 音频驱动保活已启动');

    } catch (err) {
      console.error(`静音保活启动失败: ${JSON.stringify(err)}`);
    }
  }

  // ✅ 新增：停止静音保活 (在计时结束或暂停时调用)
  static async stopSilentKeepAlive() {
    if (NotificationHelper.silentPlayer) {
      try {
        await NotificationHelper.silentPlayer.stop();
        await NotificationHelper.silentPlayer.release();
        NotificationHelper.silentPlayer = undefined;
        console.info('🛑 静音保活已停止');
      } catch (err) {
        console.error(`停止静音失败: ${JSON.stringify(err)}`);
      }
    }
  }

  // 3. 发送结束通知
  static async publishFinishNotification() {
    let wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [{ bundleName: "com.example.better", abilityName: "EntryAbility" }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    let agent = await wantAgent.getWantAgent(wantAgentInfo);
    let notificationRequest: notificationManager.NotificationRequest = {
      id: NotificationHelper.NOTIFICATION_ID,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: '✅ 任务已结束',
          text: '时间到！请点击确认结束任务。',
          additionalText: '已完成'
        }
      },
      isOngoing: false,
      wantAgent: agent,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION
    };
    try {
      await notificationManager.publish(notificationRequest);
    } catch (err) {
      const error = err as BusinessError;
      console.error(`发送结束通知失败: ${JSON.stringify(error)}`);
    }
  }

  // 4. 取消通知
  static async cancelNotification() {
    try {
      await notificationManager.cancel(NotificationHelper.NOTIFICATION_ID);
    } catch (err) {
      const error = err as BusinessError;
      console.error(`取消通知失败: ${JSON.stringify(error)}`);
    }
  }

  // 5. 播放闹铃（包含同步震动）
  static async playAlarm(context: common.Context) {
    try {
      // 1. 清理旧状态
      if (NotificationHelper.player) {
        await NotificationHelper.stopAlarm();
      }

      // 2. 创建播放器
      NotificationHelper.player = await media.createAVPlayer();

      // 3. 监听状态
      NotificationHelper.player.on('stateChange', async (state, reason) => {
        switch (state) {
          case 'initialized':
            if (NotificationHelper.player) {
              // 强制使用闹钟通道
              let audioRendererInfo: audio.AudioRendererInfo = {
                usage: audio.StreamUsage.STREAM_USAGE_ALARM,
                rendererFlags: 0
              };
              NotificationHelper.player.audioRendererInfo = audioRendererInfo;
              await NotificationHelper.player.prepare();
            }
            break;
          case 'prepared':
            if (NotificationHelper.player) {
              NotificationHelper.player.loop = true; // 音乐循环
              await NotificationHelper.player.play(); // 音乐开始

              // ✅✅✅ 同步开始震动循环
              NotificationHelper.startVibrationLoop();
            }
            break;
        }
      });

      // 4. 读取资源
      let fileDescriptor = await context.resourceManager.getRawFd('alarm.mp3');
      NotificationHelper.player.fdSrc = fileDescriptor;
      console.info('✅ 闹铃逻辑启动');

    } catch (err) {
      const error = err as BusinessError;
      console.error(`播放音乐失败: ${JSON.stringify(error)}`);
      // 兜底：如果音乐挂了，至少震动还要响
      NotificationHelper.startVibrationLoop();
    }
  }

  // 6. 停止闹铃（同时停止震动）
  static async stopAlarm() {
    try {
      // 停止音乐
      if (NotificationHelper.player) {
        await NotificationHelper.player.stop();
        await NotificationHelper.player.release();
        NotificationHelper.player = undefined;
      }

      // ✅✅✅ 停止震动循环
      NotificationHelper.stopVibrationLoop();

      console.info('🛑 闹铃与震动已停止');
    } catch (err) {
      const error = err as BusinessError;
      console.error(`停止失败: ${JSON.stringify(error)}`);
    }
  }

  // ✅✅✅ 新增：开启循环震动
  // 逻辑：每隔 1.5秒 触发一次 1秒 的震动，形成 嗡(1s) - 停(0.5s) - 嗡(1s) 的效果
  static startVibrationLoop() {
    // 防止重复开启
    NotificationHelper.stopVibrationLoop();

    // 1. 立即触发第一次
    NotificationHelper.triggerVibration();

    // 2. 开启定时器循环触发
    NotificationHelper.vibrationTimerId = setInterval(() => {
      // 检查应用是否仍然活跃，如果定时器ID已重置则停止执行
      if (NotificationHelper.vibrationTimerId === -1) {
        return;
      }
      NotificationHelper.triggerVibration();
    }, 1500); // 间隔建议比震动时长稍长一点，防止重叠
  }

  // ✅✅✅ 新增：停止循环震动
  static stopVibrationLoop() {
    if (NotificationHelper.vibrationTimerId !== -1) {
      clearInterval(NotificationHelper.vibrationTimerId);
      NotificationHelper.vibrationTimerId = -1;
    }
    // 强制停止当前正在进行的震动
    try {
      vibrator.stopVibration();
    } catch (err) {
      // 忽略错误
    }
  }

  // 单次震动逻辑
  static async triggerVibration() {
    try {
      await vibrator.startVibration({
        type: 'time',
        duration: 1000, // 震动 1000 毫秒
      }, {
        id: 0,
        usage: 'alarm' // 设为闹钟用途，优先级高
      });
    } catch (err) {
      const error = err as BusinessError;
      console.error(`震动失败: ${JSON.stringify(error)}`);
    }
  }
}