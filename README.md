# Dingtalk-Cp-Bot

钉钉企业机器人：接收发货单号（`SP...`），调用领星查询发货数据，下载 FBA PDF，OCR 识别后做目的地核对并回复结果。

## 功能概览

- 支持钉钉文本消息，一次可提交多个发货单号。
- 支持消息去重、发货单并发锁、任务队列、失败重试、下载目录自动清理。
- 核对逻辑：
  - 优先使用 OCR 识别出的 FC 与领星 `destination_fulfillment_center_id` 直匹配。
  - 对 `加拿大/日本/阿联酋`，支持 OCR 文本包含 FC 的兜底通过。
  - 对 `美国/德国/英国/澳洲`，当 FC 不匹配时走地址簿结构化地址核对。
- 处理链路异常会自动通知 `.env` 中 `DING_TECH_USER_IDS` 配置的技术人员。

## 当前目录结构

当前仓库实际文件如下：

```text
.
├── app.py
├── handler.py
├── config.py
├── env.example
├── requirements.txt
├── Dockerfile
├── docker-compose.yml
├── downloads/
└── README.md
```

说明：
- `files/全站点地址.xlsx` 为可选外部文件（用于地址簿核对），默认路径由 `ADDRESS_BOOK_XLSX_PATH` 指定。
- 本仓库当前未包含 `sql/mysql_state.sql`，请手动建表（下文提供 SQL）。

## 环境要求

- Python 3.11+
- MySQL 5.7+/8.0+
- 可访问：
  - 钉钉 Stream
  - 领星 OpenAPI
  - 阿里云 OCR
- 依赖 Common 项目（`handler.py` 会从 `COMMON_DIR` 导入）：
  - `Api.DingTalkNotifier`
  - `Api.aliyun_client.AliyunOCRClient`
  - `Api.lingxing_client.LingXingClient`

## 快速开始（本地）

1. 安装依赖

```bash
pip install -r requirements.txt
```

2. 准备配置

```bash
cp env.example .env
```

至少填写：

- 钉钉：`DINGTALK_APP_KEY`、`DINGTALK_APP_SECRET`、`DINGTALK_ROBOT_CODE`
- 技术告警：`DING_TECH_USER_IDS`（支持英文逗号或分号分隔）
- 领星：`LINGXING_API_KEY`、`LINGXING_API_SECRET`
- OCR：`ALIBABA_CLOUD_ACCESS_KEY_ID`、`ALIBABA_CLOUD_ACCESS_KEY_SECRET`
- MySQL：`DB_HOST`、`DB_PORT`、`DB_USER`、`DB_PASSWORD`、`DB_NAME`
- Common 项目路径：`COMMON_DIR`

3. （可选）准备地址簿

- 默认路径：`files/全站点地址.xlsx`
- 用到的列：`收件人`、`目的港`
- sheet 名支持：
  - 美国
  - 德国
  - 英国
  - 澳洲（或 澳大利亚）

4. 初始化 MySQL 表

代码要求以下 3 张表存在：

- `dim_bot_cp_message_dedup`
- `dim_bot_cp_shipment_lock`
- `fact_bot_cp_call_log`

可直接执行：

```sql
CREATE TABLE IF NOT EXISTS dim_bot_cp_message_dedup (
  message_id VARCHAR(128) NOT NULL PRIMARY KEY COMMENT '钉钉消息ID（去重键）',
  expires_at DOUBLE NOT NULL COMMENT '过期时间戳（秒）'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='消息去重状态表';

CREATE TABLE IF NOT EXISTS dim_bot_cp_shipment_lock (
  shipment_sn VARCHAR(64) NOT NULL PRIMARY KEY COMMENT '发货单号',
  holder_id VARCHAR(128) NOT NULL COMMENT '锁持有者（request_id）',
  expires_at DOUBLE NOT NULL COMMENT '锁过期时间戳（秒）'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='发货单并发锁表';

CREATE TABLE IF NOT EXISTS fact_bot_cp_call_log (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '调用时间',
  user_id VARCHAR(64) COLLATE utf8mb4_unicode_ci NOT NULL COMMENT '钉钉用户ID',
  user_name VARCHAR(128) COLLATE utf8mb4_unicode_ci DEFAULT NULL COMMENT '用户名称',
  message_text TEXT COLLATE utf8mb4_unicode_ci COMMENT '用户发送的问题',
  PRIMARY KEY (id),
  KEY idx_user_id (user_id),
  KEY idx_created_at (created_at),
  KEY idx_user_created (user_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='CP机器人调用日志';
```

5. 启动

```bash
python3 app.py
```

## Docker 启动

```bash
docker compose up -d --build
```

注意：

- `docker-compose.yml` 当前仅挂载 `downloads` 和 `${COMMON_DIR}`。
- 如果容器内要做地址簿匹配，需要额外挂载地址簿文件目录，或把 `ADDRESS_BOOK_XLSX_PATH` 指向容器内可读路径。

## 使用方式

在钉钉发送文本，例如：

```text
SP260204001
```

或：

```text
SP260204001 SP260204012
```

机器人会先回：

- `已接收，正在核对...`
- 或 `已接收，前面X人，请稍等...`

常见即时反馈：

- 重复消息：`重复消息已忽略，请勿重复提交。`
- 非文本：`Only text messages are supported.`
- 空消息：`Please send shipment numbers like SP260119001.`
- 未识别单号：`No shipment number found. Example: SP260119001`

## 核对规则（当前实现）

- 地址匹配阈值（代码常量）：
  - `ADDRESS_MATCH_PASS_SCORE = 82`
  - `ADDRESS_MATCH_MIN_GAP = 8`
- 支持结构化地址核对国家：`US / DE / UK / AU`
- `加拿大/日本/阿联酋` 走 OCR 文本包含 FC 的兜底策略。
- 地址簿每次核对时都会重新加载，Excel 更新后通常不需要重启服务。

## 异常通知（DING_TECH_USER_IDS）

- 当处理链路发生异常时，会向 `DING_TECH_USER_IDS` 中每个用户发送告警。
- 告警内容包含：
  - `request_id`
  - 异常阶段 `stage`
  - 异常类型与信息
  - 截断后的 traceback

## 日志与数据说明

- 启动日志会打印配置检查信息。
- 请求日志包含 `req=...`，用于串联整条链路。
- `fact_bot_cp_call_log` 当前仅记录 `RECEIVED` 事件（即收到用户请求时落库）。

## 常见问题

- `Missing DB config ...`
  - 检查 `.env` 中 `DB_HOST/DB_USER/DB_NAME`。
- `MySQL tables missing ...`
  - 先执行上面的建表 SQL。
- `地址簿不存在` 或 `地址簿未加载到...`
  - 检查 `ADDRESS_BOOK_XLSX_PATH`、sheet 名、`收件人/目的港` 列。
- `OCR结果为空` / `OCR调用失败`
  - 检查 OCR 凭证与网络。
- `领星查询失败`
  - 检查领星 Key/Secret、Token 服务与网络连通性。
