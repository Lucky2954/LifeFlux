import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { avSession as AVSessionManager } from '@kit.AVSessionKit'; // ✅ 引入 AVSessionKit
import { NotificationHelper } from './NotificationHelper';
import { ReminderHelper } from './ReminderHelper';
import { FileLogger } from './FileLogger'; // ✅ 引入日志工具

export class GuardianService {
  private static instance: GuardianService;
  private context: common.UIAbilityContext | undefined;
  
  // 守护状态
  private isRunning: boolean = false;
  
  // 计时器相关
  private secondsRemaining: number = 0;
  private totalSeconds: number = 0;
  private isPaused: boolean = false;
  private targetEndTime: number = 0;

  // ✅ 音频驱动核心
  private audioDriver: media.AVPlayer | undefined;
  private lastTickTime: number = 0;
  
  // ✅ AVSession 保活核心
  private session: AVSessionManager.AVSession | undefined;

  private constructor() {}

  public static getInstance(): GuardianService {
    if (!GuardianService.instance) {
      GuardianService.instance = new GuardianService();
    }
    return GuardianService.instance;
  }

  // ✅ 新增：同步查询是否在运行（比 StorageProp 更快更准）
  public isTimerRunning(): boolean {
    return this.isRunning; // isRunning 已经在内部维护了
  }

  public init(context: common.UIAbilityContext) {
    this.context = context;
    FileLogger.init(context); // 初始化日志
    
    AppStorage.setOrCreate('GS_SecondsRemaining', 0);
    AppStorage.setOrCreate('GS_TotalSeconds', 0);
    AppStorage.setOrCreate('GS_IsPaused', false);
    AppStorage.setOrCreate('GS_IsRunning', false);
    
    FileLogger.write('Init', '服务初始化完成');
  }

  // --- 外部控制接口 ---

  public async startTimer(durationSeconds?: number) {
    if (!this.context) return;
    FileLogger.write('Action', `请求开始计时, duration=${durationSeconds}`);

    // 1. 申请后台长时任务
    await this.requestBackgroundTask();

    // 2. 初始化或恢复数据
    if (durationSeconds !== undefined) {
      this.totalSeconds = durationSeconds;
      this.secondsRemaining = durationSeconds;
      this.isPaused = false;
    } else {
      this.isPaused = false;
    }

    // 更新状态到 UI
    this.syncToAppStorage(true);

    // 3. 计算目标结束时间
    const now = new Date().getTime();
    this.targetEndTime = now + (this.secondsRemaining * 1000);
    this.lastTickTime = now;

    // 4. 设置系统代理提醒 (兜底)
    await ReminderHelper.publishTimerReminder(this.context, this.secondsRemaining);

    // 5. 启动音频驱动 (替代 setInterval)
    await this.startAudioDriver();
    
    // 6. 创建并激活 AVSession (核心保活)
    await this.createAVSession();
  }

  public async pauseTimer() {
    FileLogger.write('Action', '暂停计时');
    this.isPaused = true;
    this.targetEndTime = 0;
    
    // 暂停时停止音频驱动
    await this.stopAudioDriver();
    await this.stopBackgroundTask(); // 放弃后台权限
    await this.destroyAVSession(); // 销毁会话
    
    await ReminderHelper.cancelAllReminders();
    this.syncToAppStorage(false);
  }

  public async stopTimer(isFinish: boolean = false) {
    // 🔍 增加调用栈追踪，揪出凶手！
    const stack = new Error().stack;
    FileLogger.write('Action', `停止计时 isFinish=${isFinish}, Caller:\n${stack}`);
    
    this.secondsRemaining = 0;
    this.targetEndTime = 0;
    this.isPaused = false;

    // 停止后台任务（但保留 Audio 如果是 Finish 状态）
    await this.stopBackgroundTask();
    
    // 销毁 AVSession (任务结束了，播控条也该没了，或者保留？通常结束了就没了)
    await this.destroyAVSession();
    
    await NotificationHelper.cancelNotification();
    await ReminderHelper.cancelAllReminders();
    
    if (isFinish) {
        // ✅ 任务完成：切换到闹铃模式 (复用驱动)
        await this.switchToAlarm();
        await NotificationHelper.publishFinishNotification();
    } else {
        // ❌ 手动终止：完全停止
        await this.stopAudioDriver();
        if (this.context) await NotificationHelper.stopAlarm();
    }

    this.syncToAppStorage(false);
  }

  // --- AVSession 保活逻辑 ---

  private async createAVSession() {
    if (!this.context) return;
    try {
      this.session = await AVSessionManager.createAVSession(this.context, 'GuardianSession', 'audio');
      await this.session.activate();
      
      // 设置元数据
      let metadata: AVSessionManager.AVMetadata = {
        assetId: '0',
        title: '专注计时中',
        artist: 'Better',
        duration: this.totalSeconds * 1000
      };
      await this.session.setAVMetadata(metadata);
      
      // 设置播放状态：播放中，速度1.0
      let playbackState: AVSessionManager.AVPlaybackState = {
        state: AVSessionManager.PlaybackState.PLAYBACK_STATE_PLAY,
        position: {
          elapsedTime: 0,
          updateTime: new Date().getTime()
        },
        speed: 1.0,
        bufferedTime: 0,
        duration: this.totalSeconds * 1000
      };
      await this.session.setAVPlaybackState(playbackState);

      FileLogger.write('System', 'AVSession 创建并激活成功');
    } catch (e) {
      FileLogger.write('SystemError', 'AVSession 创建失败: ' + JSON.stringify(e));
    }
  }

  private async destroyAVSession() {
    if (this.session) {
      try {
        await this.session.destroy();
        this.session = undefined;
        FileLogger.write('System', 'AVSession 已销毁');
      } catch (e) {
        FileLogger.write('SystemError', 'AVSession 销毁失败: ' + JSON.stringify(e));
      }
    }
  }

  // --- 音频驱动核心逻辑 ---

  private async startAudioDriver() {
    if (this.audioDriver) {
      await this.audioDriver.reset();
    } else {
      this.audioDriver = await media.createAVPlayer();
    }

    this.audioDriver.on('stateChange', async (state) => {
      switch (state) {
        case 'initialized':
          this.audioDriver!.audioRendererInfo = {
            usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
            rendererFlags: 0
          };
          await this.audioDriver!.prepare();
          break;
        case 'prepared':
          this.audioDriver!.loop = true;
          // 如果是闹铃模式，音量设为 1.0，否则 0.01
          // 这里通过一个标记位或者简单的逻辑判断？
          // 简单起见，startAudioDriver 默认是静音保活。闹铃逻辑单独处理。
          this.audioDriver!.setVolume(0.01); 
          await this.audioDriver!.play();
          FileLogger.write('Audio', '驱动已启动 (Playing)');
          break;
        case 'error':
          FileLogger.write('AudioError', '播放器出错');
          break;
      }
    });

    this.audioDriver.on('timeUpdate', (time: number) => {
       const now = Date.now();
       if (now - this.lastTickTime >= 1000) {
           this.tick();
           this.lastTickTime = now;
       }
    });

    try {
      if (this.context) {
        let fileDescriptor = await this.context.resourceManager.getRawFd('silence.mp3');
        this.audioDriver.fdSrc = fileDescriptor;
      }
    } catch (e) {
      FileLogger.write('AudioError', '加载 silence.mp3 失败: ' + JSON.stringify(e));
    }
  }
  
  // ✅ 切换到闹铃模式 (复用驱动)
  private async switchToAlarm() {
    if (!this.audioDriver || !this.context) return;
    FileLogger.write('Audio', '切换到闹铃模式');
    
    // 移除 timeUpdate 监听，防止闹铃时还在 tick
    this.audioDriver.off('timeUpdate');
    
    await this.audioDriver.reset();
    
    // 重新配置回调 (因为 reset 后 state 会变)
    this.audioDriver.on('stateChange', async (state) => {
      switch (state) {
        case 'initialized':
           // 闹铃用 ALARM 流
           this.audioDriver!.audioRendererInfo = {
            usage: audio.StreamUsage.STREAM_USAGE_ALARM,
            rendererFlags: 0
          };
          await this.audioDriver!.prepare();
          break;
        case 'prepared':
          this.audioDriver!.loop = true;
          this.audioDriver!.setVolume(1.0); // 最大音量
          await this.audioDriver!.play();
          
          // 同时开启震动
          NotificationHelper.startVibrationLoop();
          break;
      }
    });
    
    try {
        let fileDescriptor = await this.context.resourceManager.getRawFd('alarm.mp3');
        this.audioDriver.fdSrc = fileDescriptor;
    } catch(e) {
        FileLogger.write('AudioError', '加载 alarm.mp3 失败');
    }
  }

  private async stopAudioDriver() {
    if (this.audioDriver) {
      try {
        await this.audioDriver.stop();
        await this.audioDriver.release();
        this.audioDriver = undefined;
        FileLogger.write('Audio', '驱动已停止');
      } catch (e) {
        FileLogger.write('AudioError', '停止失败: ' + JSON.stringify(e));
      }
    }
  }

  // --- 业务逻辑 ---

  private tick() {
    if (this.isPaused) return;

    const now = new Date().getTime();
    const diff = Math.ceil((this.targetEndTime - now) / 1000);

    // 记录心跳日志 (每10秒记一次，防止刷屏)
    // 同时校准 AVSession 进度
    if (diff % 10 === 0) {
       FileLogger.write('Tick', `剩余: ${diff}s`);
       this.syncAVSession(diff);
    }

    if (diff <= 0) {
      this.secondsRemaining = 0;
      this.stopTimer(true);
    } else {
      this.secondsRemaining = diff;
      this.updateNotification();
      AppStorage.set('GS_SecondsRemaining', this.secondsRemaining);
    }
  }

  private async syncAVSession(secondsLeft: number) {
      if (!this.session) return;
      const elapsedTime = (this.totalSeconds - secondsLeft) * 1000;
      try {
          let playbackState: AVSessionManager.AVPlaybackState = {
            state: AVSessionManager.PlaybackState.PLAYBACK_STATE_PLAY,
            position: {
              elapsedTime: elapsedTime,
              updateTime: new Date().getTime()
            },
            speed: 1.0,
            bufferedTime: 0,
            duration: this.totalSeconds * 1000
          };
          await this.session.setAVPlaybackState(playbackState);
      } catch (e) { /* ignore */ }
  }

  private updateNotification() {
    const m = Math.floor(this.secondsRemaining / 60).toString().padStart(2, '0');
    const s = (this.secondsRemaining % 60).toString().padStart(2, '0');
    let progress = 0;
    if (this.totalSeconds > 0) {
      progress = Math.floor(((this.totalSeconds - this.secondsRemaining) / this.totalSeconds) * 100);
    }
    NotificationHelper.publishProgress(m, s, progress);
  }

  private syncToAppStorage(running: boolean) {
    AppStorage.set('GS_SecondsRemaining', this.secondsRemaining);
    AppStorage.set('GS_TotalSeconds', this.totalSeconds);
    AppStorage.set('GS_IsPaused', this.isPaused);
    AppStorage.set('GS_IsRunning', running);
  }

  // --- 后台权限申请 ---

  private async requestBackgroundTask() {
    if (!this.context) return;
    let wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [{ bundleName: this.context.abilityInfo.bundleName, abilityName: this.context.abilityInfo.name }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      let agent = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        agent
      );
      FileLogger.write('System', '后台权限申请成功');
    } catch (e) {
      FileLogger.write('SystemError', '后台权限申请失败: ' + JSON.stringify(e));
    }
  }

  private async stopBackgroundTask() {
    if (!this.context) return;
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      FileLogger.write('System', '后台权限已释放');
    } catch (e) {}
  }
}
