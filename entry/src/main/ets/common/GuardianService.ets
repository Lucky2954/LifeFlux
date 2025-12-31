import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { avSession as AVSessionManager } from '@kit.AVSessionKit';
import { NotificationHelper } from './NotificationHelper';
import { ReminderHelper } from './ReminderHelper';
import { FileLogger } from './FileLogger';

export class GuardianService {
  private static instance: GuardianService;
  private context: common.UIAbilityContext | undefined;
  
  private isRunning: boolean = false;
  private secondsRemaining: number = 0;
  private totalSeconds: number = 0;
  private isPaused: boolean = false;
  private targetEndTime: number = 0;

  private audioDriver: media.AVPlayer | undefined;
  private lastTickTime: number = 0;
  private backupTimerId: number = -1; // ✅ 辅助计时器 ID
  
  private session: AVSessionManager.AVSession | undefined;

  private constructor() {}

  public static getInstance(): GuardianService {
    if (!GuardianService.instance) {
      GuardianService.instance = new GuardianService();
    }
    return GuardianService.instance;
  }

  public isTimerRunning(): boolean {
    return this.isRunning;
  }

  public init(context: common.UIAbilityContext) {
    this.context = context;
    FileLogger.init(context);
    NotificationHelper.initNotificationSlot();
    
    AppStorage.setOrCreate('GS_SecondsRemaining', 0);
    AppStorage.setOrCreate('GS_TotalSeconds', 0);
    AppStorage.setOrCreate('GS_IsPaused', false);
    AppStorage.setOrCreate('GS_IsRunning', false);
  }

  // --- 外部控制接口 ---

  public async startTimer(durationSeconds?: number) {
    if (!this.context) return;
    FileLogger.write('Action', `开始计时 duration=${durationSeconds}`);

    await this.requestBackgroundTask();

    if (durationSeconds !== undefined) {
      this.totalSeconds = durationSeconds;
      this.secondsRemaining = durationSeconds;
      this.isPaused = false;
    } else {
      this.isPaused = false;
    }

    this.syncToAppStorage(true);

    const now = Date.now();
    this.targetEndTime = now + (this.secondsRemaining * 1000);
    this.lastTickTime = now;

    // 启动双重驱动
    await this.startAudioDriver();
    this.startBackupTimer(); 
    
    await ReminderHelper.publishTimerReminder(this.context, this.secondsRemaining);
    await this.createAVSession();
  }

  public async pauseTimer() {
    FileLogger.write('Action', '暂停计时');
    this.isPaused = true;
    this.targetEndTime = 0;
    
    this.stopBackupTimer();
    await this.stopAudioDriver();
    await this.stopBackgroundTask();
    await this.destroyAVSession();
    
    await ReminderHelper.cancelAllReminders();
    this.syncToAppStorage(false);
  }

  public async stopTimer(isFinish: boolean = false) {
    FileLogger.write('Action', `停止计时 isFinish=${isFinish}`);
    
    this.secondsRemaining = 0;
    this.targetEndTime = 0;
    this.isPaused = false;
    this.stopBackupTimer();

    if (isFinish) {
        // ✅ 关键：任务结束时不立即停止后台任务，确保闹铃能在后台播放
        await this.switchToAlarm();
        if (this.context) {
          await NotificationHelper.publishFinishNotification(this.context);
        }
    } else {
        // 手动停止：释放所有资源
        await this.stopAudioDriver();
        await this.stopBackgroundTask();
        await this.destroyAVSession();
        await NotificationHelper.cancelNotification();
        if (this.context) await NotificationHelper.stopAlarm();
    }

    this.syncToAppStorage(false);
    await ReminderHelper.cancelAllReminders();
  }

  public async ensureRunning() {
    if (this.isRunning && !this.isPaused) {
      if (!this.audioDriver || (this.audioDriver.state !== 'playing' && this.audioDriver.state !== 'prepared')) {
        FileLogger.write('System', '唤醒驱动...');
        await this.startAudioDriver();
        this.startBackupTimer();
      }
    }
  }

  // --- 计时驱动优化 ---

  private startBackupTimer() {
    this.stopBackupTimer();
    this.backupTimerId = setInterval(() => {
      this.tick();
    }, 1000);
  }

  private stopBackupTimer() {
    if (this.backupTimerId !== -1) {
      clearInterval(this.backupTimerId);
      this.backupTimerId = -1;
    }
  }

  // --- AVSession ---

  private async createAVSession() {
    if (!this.context || this.session) return;
    try {
      this.session = await AVSessionManager.createAVSession(this.context, 'GuardianSession', 'audio');
      await this.session.activate();
      this.updateAVSessionMetadata();
      FileLogger.write('System', 'AVSession 激活');
    } catch (e) {
      FileLogger.write('SystemError', 'AVSession 失败');
    }
  }

  private async updateAVSessionMetadata() {
    if (!this.session) return;
    try {
      await this.session.setAVMetadata({
        assetId: '0',
        title: '专注计时中',
        artist: 'Better',
        duration: this.totalSeconds * 1000
      });
    } catch (e) {}
  }

  private async destroyAVSession() {
    if (this.session) {
      await this.session.destroy();
      this.session = undefined;
    }
  }

  // --- 音频驱动 ---

  private async startAudioDriver() {
    if (!this.audioDriver) {
      this.audioDriver = await media.createAVPlayer();
    } else {
      await this.audioDriver.reset();
    }

    this.audioDriver.on('stateChange', async (state) => {
      if (state === 'initialized') {
        this.audioDriver!.audioRendererInfo = { usage: audio.StreamUsage.STREAM_USAGE_MUSIC, rendererFlags: 0 };
        await this.audioDriver!.prepare();
      } else if (state === 'prepared') {
        this.audioDriver!.loop = true;
        this.audioDriver!.setVolume(0.05); // ✅ 略微提升音量增加保活权重
        await this.audioDriver!.play();
      } else if (state === 'paused' && this.isRunning && !this.isPaused) {
        await this.audioDriver!.play(); // 自动恢复
      }
    });

    this.audioDriver.on('timeUpdate', () => this.tick());

    try {
      if (this.context) {
        let fd = await this.context.resourceManager.getRawFd('silence.mp3');
        this.audioDriver.fdSrc = fd;
      }
    } catch (e) {}
  }
  
  private async switchToAlarm() {
    if (!this.audioDriver || !this.context) return;
    FileLogger.write('Audio', '后台切换闹铃');
    
    this.audioDriver.off('timeUpdate');
    await this.audioDriver.reset();
    
    this.audioDriver.on('stateChange', async (state) => {
      if (state === 'initialized') {
        this.audioDriver!.audioRendererInfo = { usage: audio.StreamUsage.STREAM_USAGE_ALARM, rendererFlags: 0 };
        await this.audioDriver!.prepare();
      } else if (state === 'prepared') {
        this.audioDriver!.loop = true;
        this.audioDriver!.setVolume(1.0);
        await this.audioDriver!.play();
        NotificationHelper.startVibrationLoop();
      }
    });
    
    try {
      this.audioDriver.fdSrc = await this.context.resourceManager.getRawFd('alarm.mp3');
    } catch(e) {}
  }

  private async stopAudioDriver() {
    if (this.audioDriver) {
      await this.audioDriver.stop();
      await this.audioDriver.release();
      this.audioDriver = undefined;
    }
  }

  // --- 逻辑核心 ---

  private tick() {
    if (this.isPaused || !this.isRunning) return;

    const now = Date.now();
    // 采用 targetEndTime 绝对时间校准，防止计时漂移
    const diff = Math.ceil((this.targetEndTime - now) / 1000);

    if (diff <= 0) {
      this.secondsRemaining = 0;
      this.stopTimer(true); // 触发结束
    } else {
      if (now - this.lastTickTime >= 1000) {
        this.secondsRemaining = diff;
        this.updateNotification();
        AppStorage.set('GS_SecondsRemaining', this.secondsRemaining);
        this.lastTickTime = now;
        
        // 每10秒校准一次 AVSession
        if (diff % 10 === 0) this.syncAVSession(diff);
      }
    }
  }

  private async syncAVSession(secondsLeft: number) {
      if (!this.session) return;
      try {
          await this.session.setAVPlaybackState({
            state: AVSessionManager.PlaybackState.PLAYBACK_STATE_PLAY,
            position: { elapsedTime: (this.totalSeconds - secondsLeft) * 1000, updateTime: Date.now() },
            speed: 1.0,
            duration: this.totalSeconds * 1000
          });
      } catch (e) {}
  }

  private updateNotification() {
    if (!this.context) return;
    const m = Math.floor(this.secondsRemaining / 60).toString().padStart(2, '0');
    const s = (this.secondsRemaining % 60).toString().padStart(2, '0');
    let progress = Math.max(0, Math.min(100, Math.floor(((this.totalSeconds - this.secondsRemaining) / this.totalSeconds) * 100)));
    NotificationHelper.publishProgress(this.context, m, s, progress);
  }

  private syncToAppStorage(running: boolean) {
    this.isRunning = running;
    AppStorage.set('GS_SecondsRemaining', this.secondsRemaining);
    AppStorage.set('GS_TotalSeconds', this.totalSeconds);
    AppStorage.set('GS_IsPaused', this.isPaused);
    AppStorage.set('GS_IsRunning', running);
  }

  private async requestBackgroundTask() {
    if (!this.context) return;
    try {
      let wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: this.context.abilityInfo.bundleName, abilityName: this.context.abilityInfo.name }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      let agent = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(this.context, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      FileLogger.write('System', '后台权限开启');
    } catch (e) {
      FileLogger.write('SystemError', '权限开启失败');
    }
  }

  private async stopBackgroundTask() {
    if (!this.context) return;
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      FileLogger.write('System', '后台权限释放');
    } catch (e) {}
  }
}
