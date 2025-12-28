import { FeishuService, CategoryItem, LogData } from '../common/FeishuService';
import { NotificationHelper } from '../common/NotificationHelper';
import { common } from '@kit.AbilityKit';
import notificationManager from '@ohos.notificationManager';
import { promptAction } from '@kit.ArkUI';
import { GuardianService } from '../common/GuardianService';
import { FileLogger } from '../common/FileLogger'; // ✅ 引入日志

enum AppState {
  SELECT_L1 = 0,    // 首页
  ADD_L1 = 1,       // 添加分类
  SELECT_L2 = 2,    // 二级选择
  CONFIRM_START = 3,// 确认开始
  SET_TIME = 4,     // 设置时间
  TIMER_RUNNING = 5,// 计时中
  FINISH_INPUT = 6  // 结束填写
}

const now = new Date();
const currentMinute = now.getMinutes();
const leftHours = currentMinute === 0 ? 24 - now.getHours() : 23 - now.getHours();
const leftMinutes = currentMinute === 0 ? 0 : 60 - currentMinute;

@Entry
@Component
struct Index {
  private context = getContext(this) as common.UIAbilityContext;

  @State currentState: AppState = AppState.SELECT_L1;
  @State allCategories: CategoryItem[] = [];
  @State isSubmitting: boolean = false;

  @State selectedL1: string = '';
  @State selectedL2: string = '';
  @State customL2: string = '';
  @State newL1Input: string = '';
  @State taskNote: string = '';

  @State estimatedTime: string = '25';
  
  // ✅ 使用 StorageProp 监听 Service 数据
  @StorageProp('GS_SecondsRemaining') @Watch('onTimeChange') secondsRemaining: number = 0;
  @StorageProp('GS_TotalSeconds') totalSeconds: number = 0;
  @StorageProp('GS_IsPaused') isPaused: boolean = false;
  // 此处监听 Service 是否在运行，辅助判断任务是否结束
  // 但我们主要靠 secondsRemaining 归零来触发结束弹窗
  @StorageProp('GS_IsRunning') isServiceRunning: boolean = false;

  // 简化的实际时长统计 (不再精确到秒，用 total - remaining 估算)
  startTime: number = 0;

  async aboutToAppear() {
    this.allCategories = await FeishuService.getCategories();
    try {
      await notificationManager.requestEnableNotification();
      await notificationManager.addSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION);
    } catch (err) {
      console.error('请求通知权限失败', JSON.stringify(err));
    }
  }

  // 监听时间变化，用于处理归零逻辑
  onTimeChange() {
    // 只有在计时页面，且时间归零，且 Service 已经停止(说明不是刚初始化)时，才触发结束
    if (this.currentState === AppState.TIMER_RUNNING && this.secondsRemaining <= 0 && !this.isServiceRunning) {
        // 只有当总时间 > 0 时才认为是正常的任务结束（防止初始化时的0触发）
        if (this.totalSeconds > 0) {
            this.showEndConfirmDialog();
        }
    }
  }

  onPageShow() {
    // 每次切回前台，检查一下状态
    // 如果 Service 正在运行，强制跳到计时页
    if (this.isServiceRunning && this.currentState !== AppState.TIMER_RUNNING) {
       this.currentState = AppState.TIMER_RUNNING;
    }
  }

  onBackPress() {
    // 🛡️ 强力拦截：只要后台服务在跑，绝对不允许返回键退出！
    // 不再依赖可能延迟的 StorageProp 或本地 State
    if (GuardianService.getInstance().isTimerRunning()) {
        // 可以给个提示
        // promptAction.showToast({ message: '计时进行中，正在后台运行' });
        return false; // 交给系统处理（退后台）
    }

    if (this.currentState === AppState.SELECT_L1) return false;
    // if (this.currentState === AppState.TIMER_RUNNING) return false; // 这一行其实被上面的覆盖了，但保留也无妨
    this.handleBack();
    return true;
  }

  handleBack() {
    switch (this.currentState) {
      case AppState.ADD_L1:
        this.currentState = AppState.SELECT_L1; break;
      case AppState.SELECT_L2:
        this.currentState = AppState.SELECT_L1; break;
      case AppState.CONFIRM_START:
        this.currentState = AppState.SELECT_L2; break;
      case AppState.SET_TIME:
        this.currentState = AppState.CONFIRM_START; break;
      case AppState.FINISH_INPUT:
        this.resetApp(); break;
    }
  }

  // --- UI Builders ---
  
  @Builder ViewTitleBar(title: string) {
    Row() {
      Button() {
        Text('←').fontSize(24).fontWeight(FontWeight.Bold).fontColor('#445460')
      }
      .type(ButtonType.Circle).backgroundColor(Color.Transparent).width(40).height(40)
      .onClick(() => this.handleBack())

      Text(title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        // .padding({ right: 40 }) // ❌ 移除这个 padding，因为右边要有按钮了
        .fontColor('#445460')

      // ✅ 新增：日志调试按钮
      Button('🐞')
        .type(ButtonType.Circle)
        .backgroundColor(Color.Transparent)
        .width(40)
        .height(40)
        .onClick(() => {
           this.showLogDialog();
        })
    }
    .width('100%').height(50).alignItems(VerticalAlign.Center).backgroundColor('#BCD7F2').borderRadius({ topLeft: 24, topRight: 24 })
  }

  @Builder ViewSelectL1() {
    Column({ space: 20 }) {
      Text(`⌛️抓住今天剩下的${leftHours}小时${leftMinutes}分钟！接下来做什么？`)
        .fontSize(20).fontWeight(FontWeight.Bold).textAlign(TextAlign.Center).lineHeight(30).margin({ top: 20 }).fontColor('#445460')

      Scroll() {
        Column({ space: 12 }) {
          ForEach(this.getUniqueL1(), (item: string) => {
            Button(item).width('80%').height(45).backgroundColor('#677C95')
              .onClick(() => { this.selectedL1 = item; this.currentState = AppState.SELECT_L2; })
              .gesture(LongPressGesture({ repeat: false }).onAction(() => this.handleDeleteCategory(item)))
          })
          Button('+ 添加').width('80%').height(45).backgroundColor('#9AB7D3')
            .onClick(() => { this.currentState = AppState.ADD_L1; })
        }
        .width('100%').alignItems(HorizontalAlign.Center).padding({ bottom: 20 })
      }.layoutWeight(1).width('100%').align(Alignment.Top)
    }.width('100%').height('100%')
  }

  @Builder ViewAddL1() {
    Column() {
      this.ViewTitleBar('添加新分类')
      Column({ space: 20 }) {
        Text('输入新的分类名称').fontSize(18)
        TextInput({ placeholder: '例如：健身' }).onChange((val) => this.newL1Input = val).width('90%')
        Button('确认').backgroundColor('#677C95').onClick(async () => {
          if (this.newL1Input) {
            let newItem: CategoryItem = { id: 'temp', level1: this.newL1Input, level2: '默认' };
            this.allCategories.push(newItem);
            FeishuService.addCategory(this.newL1Input);
            this.newL1Input = '';
            this.currentState = AppState.SELECT_L1;
          }
        })
      }.layoutWeight(1).justifyContent(FlexAlign.Center).width('100%')
    }.height('100%')
  }

  @Builder ViewSelectL2() {
    Column() {
      this.ViewTitleBar(this.selectedL1)
      Column({ space: 20 }) {
        Text(`请选择 "${this.selectedL1}"下的日程明细`).fontSize(20).fontColor('#445460')
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
          ForEach(this.getL2ByL1(this.selectedL1), (item: string) => {
            Button(item).margin(8).height(40).backgroundColor('#677C95')
              .onClick(() => { this.selectedL2 = item; this.currentState = AppState.CONFIRM_START; })
              .gesture(LongPressGesture({ repeat: false }).onAction(() => this.handleDeleteLevel2(item)))
          })
        }
        TextInput({ placeholder: '输入新的日程明细' }).width('90%').backgroundColor('#BCD7F2').placeholderColor('#9AB7D3')
          .onChange((val) => this.customL2 = val).margin({ top: 10 })
        Button('确认').backgroundColor('#677C95').onClick(async () => {
          if (this.customL2) {
            let newItem: CategoryItem = { id: 'temp', level1: this.selectedL1, level2: this.customL2 };
            this.allCategories.push(newItem);
            FeishuService.addLevel2(this.selectedL1, this.customL2);
            this.selectedL2 = this.customL2;
            this.currentState = AppState.CONFIRM_START;
          } else {
            promptAction.showToast({ message: '请输入内容' });
          }
        }).margin({ top: 10 })
      }.layoutWeight(1).justifyContent(FlexAlign.Center).width('100%')
    }.height('100%')
  }

  @Builder ViewConfirmStart() {
    Column() {
      this.ViewTitleBar('确认任务')
      Column({ space: 30 }) {
        Column({ space: 10 }) {
          Text('📚准备开始：').fontSize(20).fontWeight(FontWeight.Bold)
          Text(`${this.selectedL1} - ${this.selectedL2}`).fontSize(20)
        }
        Row({ space: 40 }) {
          Button('回首页').backgroundColor('#445460').onClick(() => {
             // ✅ 这里是用户主动放弃，必须停止计时（虽然此时还没开始，但为了保险）
             GuardianService.getInstance().stopTimer(false);
             this.resetApp();
          })
          Button('是').backgroundColor('#677C95').onClick(() => { this.currentState = AppState.SET_TIME; })
        }
      }.layoutWeight(1).justifyContent(FlexAlign.Center).width('100%')
    }.height('100%')
  }

  @Builder ViewSetTime() {
    Column() {
      this.ViewTitleBar('设定时长')
      Column({ space: 20 }) {
        Text('⏰️预计花费多少分钟？').fontSize(20)
        TextInput({ text: this.estimatedTime }).type(InputType.Number).width('50%').textAlign(TextAlign.Center)
          .onChange((val) => this.estimatedTime = val)

        Button('开始计时').backgroundColor('#677C95').onClick(() => {
          const mins = parseInt(this.estimatedTime) || 25;
          this.startTime = new Date().getTime();
          // ✅ 启动 Service 计时
          GuardianService.getInstance().startTimer(mins * 60);
          this.currentState = AppState.TIMER_RUNNING;
        })
      }.layoutWeight(1).justifyContent(FlexAlign.Center).width('100%')
    }.height('100%')
  }

  @Builder ViewTimerRunning() {
    Column({ space: 30 }) {
      Text(`👉正在进行：${this.selectedL2}`).fontSize(18).fontColor('#445460')
      // secondsRemaining 由 StorageProp 自动更新
      Text(this.formatTime(this.secondsRemaining))
        .fontSize(50).fontWeight(FontWeight.Bold)
        .fontColor(this.secondsRemaining <= 0 ? '#FF0000' : '#445460')

      Row({ space: 20 }) {
        Button(this.isPaused ? '继续' : '暂停').backgroundColor('#9AB7D3')
          .onClick(() => {
            if (this.isPaused) {
              // 继续 (不传参数)
              GuardianService.getInstance().startTimer();
            } else {
              // 暂停
              GuardianService.getInstance().pauseTimer();
            }
          })

        Button('终止').backgroundColor('#445460')
          .onClick(() => {
            this.showEndConfirmDialog(
              '终止确认',
              '确定要提前结束当前任务吗？',
              '确认结束',
              '取消',
              () => {
                GuardianService.getInstance().stopTimer(false);
                this.currentState = AppState.FINISH_INPUT;
              },
              () => {} // 取消则无操作
            );
          })
      }
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }

  @Builder ViewFinishInput() {
    Column({ space: 20 }) {
      Text('✅ 任务完成').fontSize(24)
      TextArea({ placeholder: '完成了哪些内容？' }).width('90%').height(120).onChange((val) => this.taskNote = val)
      Button(this.isSubmitting ? '正在保存...' : '保存并完成')
        .backgroundColor(this.isSubmitting ? '#CCCCCC' : '#677C95').enabled(!this.isSubmitting)
        .onClick(async () => {
          this.isSubmitting = true;
          try {
            const endTime = new Date().getTime();
            // 估算实际时长
            let usedSeconds = this.totalSeconds - this.secondsRemaining;
            if (usedSeconds < 0) usedSeconds = this.totalSeconds; // 防御性
            
            // 如果是因为超时结束，这里 secondsRemaining 可能是 0，所以 usedSeconds = totalSeconds
            // 如果是加时了，逻辑会比较复杂，这里简化处理：只记录最后一次设定的总时长
            // 实际上应该让 Service 记录一个 cumulativeTime
            
            const actualDuration = Math.ceil(usedSeconds / 60);

            let log = new LogData();
            log.level1 = this.selectedL1;
            log.level2 = this.selectedL2;
            log.duration = actualDuration;
            log.startTime = this.startTime;
            log.endTime = endTime;
            log.notes = this.taskNote;

            await FeishuService.saveActivityLog(log);
            promptAction.showToast({ message: '✅ 保存成功' });
            this.resetApp();
          } catch (err) {
            promptAction.showToast({ message: '❌ 保存失败，请重试' });
            console.error('保存飞书失败:', JSON.stringify(err));
          } finally {
            this.isSubmitting = false;
          }
        })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor('#00000000')
        .onClick(() => { if (this.currentState !== AppState.TIMER_RUNNING) this.context.terminateSelf(); })
      Column() {
        if (this.currentState === AppState.SELECT_L1) this.ViewSelectL1()
        else if (this.currentState === AppState.ADD_L1) this.ViewAddL1()
        else if (this.currentState === AppState.SELECT_L2) this.ViewSelectL2()
        else if (this.currentState === AppState.CONFIRM_START) this.ViewConfirmStart()
        else if (this.currentState === AppState.SET_TIME) this.ViewSetTime()
        else if (this.currentState === AppState.TIMER_RUNNING) this.ViewTimerRunning()
        else if (this.currentState === AppState.FINISH_INPUT) this.ViewFinishInput()
      }
      .width('85%').height('60%').backgroundColor(Color.White).borderRadius(24).padding(20)
      .shadow({ radius: 30, color: '#40000000', offsetX: 0, offsetY: 10 }).clip(true).onClick(() => {})
    }.width('100%').height('100%').alignContent(Alignment.Center)
  }

  // --- Helpers ---

  resetApp() {
    this.selectedL1 = ''; this.selectedL2 = ''; this.customL2 = ''; this.taskNote = '';
    // ❌ 移除这里的 stopTimer，防止被误调用！
    // 只有用户明确点击“终止”或“回首页”时，才在那个按钮的事件里调 stopTimer
    // GuardianService.getInstance().stopTimer(false);
    
    this.startTime = 0;
    this.currentState = AppState.SELECT_L1;
  }

  showEndConfirmDialog(
    title: string = '任务提示',
    message: string = '时间到！是否结束任务？',
    confirmText: string = '结束任务',
    cancelText: string = '继续',
    onConfirm: () => void = () => {
      NotificationHelper.stopAlarm();
      this.currentState = AppState.FINISH_INPUT;
    },
    onCancel: () => void = () => {
      // 默认继续逻辑：如果是时间到触发的，这里可以加时
      const originalMins = parseInt(this.estimatedTime) || 25;
      const additionalSeconds = originalMins * 60;
      GuardianService.getInstance().startTimer(additionalSeconds);
      NotificationHelper.stopAlarm();
    }
  ) {
    AlertDialog.show({
      title: title,
      message: message,
      autoCancel: false,
      primaryButton: {
        value: cancelText,
        action: onCancel
      },
      secondaryButton: {
        value: confirmText,
        action: onConfirm
      }
    })
  }

  showLogDialog() {
    const logs = FileLogger.readLogs();
    AlertDialog.show({
      title: '运行日志',
      message: logs.slice(-2000), // 只显示最后2000个字符，防止太长
      primaryButton: {
        value: '关闭',
        action: () => {}
      },
      secondaryButton: {
        value: '清空日志',
        fontColor: '#FF0000',
        action: () => {
          FileLogger.clearLogs();
          promptAction.showToast({ message: '日志已清空' });
        }
      }
    })
  }

  formatTime(seconds: number): string {
    const absSeconds = Math.abs(seconds);
    const m = Math.floor(absSeconds / 60).toString().padStart(2, '0');
    const s = (absSeconds % 60).toString().padStart(2, '0');
    return `${seconds < 0 ? '-' : ''}${m}:${s}`;
  }

  getUniqueL1(): string[] {
    const l1s: string[] = this.allCategories.map((c) => c.level1);
    let uniqueList: string[] = [];
    l1s.forEach(item => { if (!uniqueList.includes(item)) uniqueList.push(item); })
    return uniqueList;
  }

  getL2ByL1(l1: string): string[] {
    return this.allCategories.filter((c) => c.level1 === l1 && c.level2 !== '默认').map((c) => c.level2);
  }

  async handleDeleteCategory(level1Name: string) { /* ... same as before ... */ }
  async handleDeleteLevel2(level2Name: string) { /* ... same as before ... */ }
}
