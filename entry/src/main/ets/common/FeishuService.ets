import http from '@ohos.net.http';
import { BusinessError } from '@kit.BasicServicesKit';

// === 配置信息 ===
const APP_ID = 'cli_a9c3d1c24e78dcb6';
const APP_SECRET = 'n7Vio13lovAZQFe5Lf4IbgeqCPLTm3V0';
const BASE_TOKEN = 'TDvnbNd39aDmnXs3UEkcsxCUnMg';
const TABLE_CONFIG_ID = 'tblCxxjrlOFgwx8N';
const TABLE_LOG_ID = 'tblV6strNxM2cgHz';

// === 1. 定义严格的接口 (修复 any 问题) ===

// 定义飞书单选框的数据结构
class SelectOption {
  id: string = '';
  text: string = '';
}

interface FeishuResponse {
  code: number;
  msg: string;
  tenant_access_token?: string;
  data?: FeishuData;
}

interface FeishuData {
  items?: FeishuRecord[];
}

interface FeishuRecord {
  record_id: string;
  // [修复点1] 将 any 改为 Object，ArkTS 允许 Object 作为泛型值
  fields: Record<string, Object>;
}

// 你的业务数据结构
export class CategoryItem {
  id: string = '';
  level1: string = '';
  level2: string = '';
}

export class LogData {
  level1: string = '';
  level2: string = '';
  duration: number = 0;
  startTime:number = 0;
  endTime: number = 0;  // [新增] 结束时间的时间戳
  notes: string = '';
}

class AuthPayload {
  app_id: string = '';
  app_secret: string = '';
}

class RecordPayload {
  // [修复点2] 发送数据时，值可能是 string 或 number，使用联合类型
  fields: Record<string, string | number> = {};
}

// === 2. 服务类实现 ===

export class FeishuService {
  private static token: string = '';
  private static tokenPromise: Promise<string> | null = null;

  // 1. 获取 Tenant Access Token
  static async getAccessToken(): Promise<string> {
    // 如果已经有获取token的请求正在进行，直接返回该Promise
    if (FeishuService.tokenPromise) {
      return FeishuService.tokenPromise;
    }

    // 如果token已存在，直接返回
    if (FeishuService.token) {
      return FeishuService.token;
    }

    // 创建一个新的Promise来获取token
    FeishuService.tokenPromise = (async () => {
      let httpRequest = http.createHttp();
      let payload: AuthPayload = {
        app_id: APP_ID,
        app_secret: APP_SECRET
      };

      try {
        let response = await httpRequest.request(
          'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal',
          {
            method: http.RequestMethod.POST,
            header: { 'Content-Type': 'application/json' },
            extraData: payload
          }
        );

        // 类型断言
        let result = JSON.parse(response.result as string) as FeishuResponse;

        if (result.tenant_access_token) {
          FeishuService.token = result.tenant_access_token;
          return FeishuService.token;
        }
        return '';
      } catch (err) {
        console.error('获取Token失败:', JSON.stringify(err));
        return '';
      } finally {
        httpRequest.destroy();
        // 重置tokenPromise，允许后续请求重新获取token
        FeishuService.tokenPromise = null;
      }
    })();

    return FeishuService.tokenPromise;
  }

  // 2. 获取分类数据
  static async getCategories(): Promise<CategoryItem[]> {
    const token = await FeishuService.getAccessToken();
    if (!token) return [];

    let httpRequest = http.createHttp();
    let url = `https://open.feishu.cn/open-apis/bitable/v1/apps/${BASE_TOKEN}/tables/${TABLE_CONFIG_ID}/records`;

    try {
      let response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: { 'Authorization': `Bearer ${token}` }
      });

      let result = JSON.parse(response.result as string) as FeishuResponse;

      if (result.code === 0 && result.data && result.data.items) {
        let items: CategoryItem[] = [];

        for (let item of result.data.items) {
          // [修复点3] 严格的类型解析逻辑
          let rawL1 = item.fields['一级分类'];
          let rawL2 = item.fields['二级分类'];

          let catItem = new CategoryItem();
          catItem.id = item.record_id;
          catItem.level1 = FeishuService.parseVal(rawL1);
          catItem.level2 = FeishuService.parseVal(rawL2);

          items.push(catItem);
        }
        return items;
      }
      return [];
    } catch (err) {
      console.error('获取分类失败:', JSON.stringify(err));
      return [];
    } finally {
      httpRequest.destroy();
    }
  }

  // [修复点4] 提取解析函数，避免使用 any
  // ArkTS 中使用 Object 来接收不确定的类型，然后通过 typeof 判断
  private static parseVal(val: Object | undefined | null): string {
    if (!val) return '';

    // 如果是字符串（旧数据）
    if (typeof val === 'string') {
      return val;
    }

    // 如果是对象（单选框数据），我们需要将其视为 SelectOption
    // 在 ArkTS 中，不能直接访问 val['text']，需要类型断言或 JSON 转换
    if (typeof val === 'object') {
      // 这里使用一个安全的转换方式：先转字符串再解析，或者使用 as 断言
      // 为了稳妥，我们假设它是符合 SelectOption 结构的
      // 注意：直接 as 可能会在运行时不安全，但在飞书场景下结构是固定的
      let option = val as SelectOption;
      // 检查属性是否存在
      if (option.text) {
        return option.text;
      }
      // 或者是 value 属性（兼容不同版本 API）
      // 这里为了规避类型检查，可以使用 JSON 转换大法（虽然性能稍低但最安全）
      let jsonStr = JSON.stringify(val);
      if (jsonStr.includes('"text":')) {
        let tempObj = JSON.parse(jsonStr) as SelectOption;
        return tempObj.text;
      }
    }

    return '';
  }

  // 3. 添加新的一级分类
  static async addCategory(level1Name: string): Promise<void> {
    const token = await FeishuService.getAccessToken();
    let httpRequest = http.createHttp();
    let url = `https://open.feishu.cn/open-apis/bitable/v1/apps/${BASE_TOKEN}/tables/${TABLE_CONFIG_ID}/records`;

    let payload: RecordPayload = {
      fields: {
        "一级分类": level1Name,
        "二级分类": "默认"
      }
    };

    try {
      await httpRequest.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json'
        },
        extraData: payload
      });
    } catch (err) {
      console.error('添加分类失败:', JSON.stringify(err));
    } finally {
      httpRequest.destroy();
    }
  }

  // 4. 添加二级分类
  static async addLevel2(level1: string, level2: string): Promise<void> {
    const token = await FeishuService.getAccessToken();
    let httpRequest = http.createHttp();
    let url = `https://open.feishu.cn/open-apis/bitable/v1/apps/${BASE_TOKEN}/tables/${TABLE_CONFIG_ID}/records`;

    let payload: RecordPayload = {
      fields: {
        "一级分类": level1,
        "二级分类": level2
      }
    };

    try {
      await httpRequest.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json'
        },
        extraData: payload
      });
    } catch (err) {
      console.error('添加二级分类失败:', JSON.stringify(err));
    } finally {
      httpRequest.destroy();
    }
  }

  // [新增方法] 格式化时长字符串
  private static formatDuration(minutes: number): string {
    if (minutes < 60) {
      return `${minutes}分钟`;
    } else {
      let hours = Math.floor(minutes / 60);
      let remainMins = minutes % 60;
      if (remainMins === 0) {
        return `${hours}小时`;
      } else {
        return `${hours}小时${remainMins}分钟`;
      }
    }
  }

  // 5. 保存活动记录
  static async saveActivityLog(logData: LogData): Promise<void> {
    const token = await FeishuService.getAccessToken();
    let httpRequest = http.createHttp();
    let url = `https://open.feishu.cn/open-apis/bitable/v1/apps/${BASE_TOKEN}/tables/${TABLE_LOG_ID}/records`;

    // 格式化时长
    let durationStr = FeishuService.formatDuration(logData.duration);
    let fields: Record<string, string | number> = {};
    fields["一级分类"] = logData.level1;
    fields["二级分类"] = logData.level2;
    // 注意：这里发送的是字符串，飞书对应列必须是文本类型
    fields["时长-分钟"] = durationStr;
    //fields["记录时间"] = new Date().getTime(); // 开始时间 (如果你的逻辑是这样)
    fields["开始时间"] = logData.startTime; // 开始时间 (如果你的逻辑是这样)
    fields["结束时间"] = logData.endTime;     // [新增] 结束时间
    fields["总结"] = logData.notes;

    let payload: RecordPayload = {
      fields: fields
    };

    try {
      await httpRequest.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json'
        },
        extraData: payload
      });
    } catch (err) {
      console.error('保存记录失败:', JSON.stringify(err));
    } finally {
      httpRequest.destroy();
    }
  }

  // 6. 删除记录
  static async deleteRecord(recordId: string): Promise<void>{
    const token = await FeishuService.getAccessToken();
    let httpRequest = http.createHttp();
    let url = `https://open.feishu.cn/open-apis/bitable/v1/apps/${BASE_TOKEN}/tables/${TABLE_CONFIG_ID}/records/${recordId}`;

    try {
      await httpRequest.request(url, {
        method: http.RequestMethod.DELETE,
        header: { 'Authorization': `Bearer ${token}` }
      });
    } catch (err) {
      console.error('删除记录失败:', JSON.stringify(err));
    } finally {
      httpRequest.destroy();
    }
  }
}