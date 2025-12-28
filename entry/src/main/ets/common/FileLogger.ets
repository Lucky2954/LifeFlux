import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

export class FileLogger {
  private static logPath: string = '';

  static init(context: common.UIAbilityContext) {
    // 日志保存在应用沙箱的 files 目录下
    FileLogger.logPath = context.filesDir + '/app_debug.log';
  }

  static async write(tag: string, message: string) {
    if (!FileLogger.logPath) return;
    
    const time = new Date().toLocaleTimeString();
    const content = `[${time}] ${tag}: ${message}\n`;

    try {
      // 追加写入模式
      let file = fs.openSync(FileLogger.logPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      fs.writeSync(file.fd, content);
      fs.closeSync(file);
    } catch (e) {
      console.error('日志写入失败', e);
    }
  }

  static readLogs(): string {
    if (!FileLogger.logPath) return 'Log path not initialized';
    try {
      if (!fs.accessSync(FileLogger.logPath)) return '暂无日志';
      return fs.readTextSync(FileLogger.logPath);
    } catch (e) {
      return '读取日志失败: ' + JSON.stringify(e);
    }
  }

  static clearLogs() {
    if (!FileLogger.logPath) return;
    try {
      fs.unlinkSync(FileLogger.logPath);
    } catch (e) {}
  }
}
