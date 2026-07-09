# 阶段三：无文本 Agent 自动化生图

## 确认门槛

阶段三只运行本地脚本，不调用 Codex 或其他文本 Agent。仅在阶段一状态为 `confirmed`、阶段二已确认后正式执行。调用 API 前预览：

- 最新确认的 Excel 绝对路径；
- 工作表名称；默认使用独立脚本交接表中的 `生图任务表`；
- Excel 左侧可见起始行和结束行，包含首尾；
- 有效提示词张数；
- 解析后的目标尺寸。

没有明确行号不得默认全表生成。没有 `-Execute` 时只预览，不调用 API。预览阶段必须已经解析出每行目标尺寸；缺少明确尺寸时停止修交接数据，不得默认方图继续跑。

## 入口

构建/刷新 Excel，不调用 API：

```powershell
& "C:\Users\HK\.codex\skills\saima-plan\scripts\run_stage3_automated.ps1" `
  -HandoffPath "<phase1_handoff.json>" `
  -Phase2Path "<phase2_output.json>"
```

预览工作表和 Excel 行号，不调用 API：

```powershell
& "C:\Users\HK\.codex\skills\saima-plan\scripts\run_stage3_automated.ps1" `
  -HandoffPath "<phase1_handoff.json>" `
  -Phase2Path "<phase2_output.json>" `
  -PromptSheetName "主图提示词" `
  -StartRow 2 `
  -EndRow 6
```

用户确认预览内容后，原命令增加 `-Execute`。该开关和明确行号共同代表正式执行授权：

```powershell
& "C:\Users\HK\.codex\skills\saima-plan\scripts\run_stage3_automated.ps1" `
  -HandoffPath "<phase1_handoff.json>" `
  -Phase2Path "<phase2_output.json>" `
  -PromptSheetName "主图提示词" `
  -StartRow 2 `
  -EndRow 6 `
  -OutputDir "<输出文件夹>" `
  -Execute
```

该脚本自动完成：阶段二校验 → 提示词合并 → Excel 构建与渲染 → 行号抽取 → 按脚本交接表调用图像 API → 运行摘要。证照/资料页如存在，也作为上传参考图进入图像 API，不再走本地固定资产合成。

构建后会同时输出：

- 展示版 Excel：保留多工作表结构，供人审阅；
- 脚本生图交接表：独立工作簿，只包含 `生图任务表`，表头固定为 `说明`、`参考图的位置`、`生成提示词`。`说明` 只包含链接序号、图片类型和组内序号，例如 `链接1｜主图｜第1/5张`。

如果使用 `run_stage3_automated.ps1` 且未传 `-PromptSheetName`，行号默认从脚本生图交接表的 `生图任务表` 读取。

## 执行

底层使用 `scripts/saima_generate_images.ps1`，API Key 只从 `YUNWU_API_KEY` 读取，不打印明文。默认 Base URL 为 `https://yunwu.ai/v1`，模型为 `gpt-image-2`。

正式生图只上传我品、包装、SKU、说明书和资质资产；拒绝竞品、店铺截图和外部品牌。品牌商品有参考图时不得静默回退到纯提示词生成。

最终图片文件名必须以产品款式编码开头。赛马专用入口优先使用 `phase1_handoff.json` 中的 `product.product_id`；通用表格入口会从 Excel 文件名、输出路径或参考图路径识别类似 `JR0384`、`YL0293` 的编码。识别不到时必须显式传 `-StyleCode`，不得输出无款式编码的最终图片名。

```powershell
& "C:\Users\HK\.codex\skills\saima-plan\scripts\run_phase3_auto.ps1" `
  -Workbook "<脚本生图交接表.xlsx>" `
  -StartRow <start> `
  -EndRow <end> `
  -OutputDir "<output>" `
  -PreviewOnly
```

用户确认预览后：使用 `run_phase3_auto.ps1` 时去掉 `-PreviewOnly`；使用 `run_stage3_automated.ps1` 时增加 `-Execute`。脚本必须按 Excel 行号逐行执行，并在输出摘要中反馈每行状态、生成数量、跳过数量和异常项。

尺寸和画面完整性属于前置脚本问题，不交给 Agent 逐图质检解决。脚本必须根据 `outputSize` 生成目标比例；缺少尺寸时直接报错。生成错尺寸时不得拉伸、硬裁切或用后处理冒充正确尺寸。

## 主图长图扩展

阶段二主图提示词只生成 1440×1440 方图。第三阶段正式执行时，底层脚本默认检查每个链接的主图方图组：当同一链接下主图方图正好完成 5 张后，再逐张调用 API 生成对应 1440×1920 长图。

长图生成规则：

- 使用刚生成完成的 1440×1440 方图作为唯一参考图；
- 提示词必须要求模型不要改动方图中的文字、图标、产品、包装、Logo、颜色和卖点结构；
- 只允许因 1440×1920 竖版比例转换，轻微调整图标、卖点卡、留白和层级排布；
- 方图和长图必须看起来像同一版图片的不同尺寸。

长图输出到 `main_long_1440x1920/`，方图仍输出到 `final_images/`。如只需方图，运行脚本时传 `-SkipMainLongImages`。

## 任务分流

- `image_generation`：只上传交接包中允许上传的我品资产，竞品路径由合并脚本过滤。
- 证照/资料参考：作为我品参考图上传，由提示词要求画框展示并保持证照/资料文字编号印章和版式不改；非医疗器械产品不固定规划注册证或备案证明页。

## 产品身份与返工

- 第一张参考图必须是目标形态匹配的清晰身份基准；包装印刷、Logo、数字、图标和色块不可改写。
- 外盒任务用外盒身份图，单包任务用单包身份图，不用组合图代替唯一身份基准。
- 包装错误时按原 Excel 行号单独重跑，减少同屏产品、降低透视复杂度，只保留身份基准和一张必要场景参考。
- 没有匹配素材时停止该行并补素材，不反复消耗 API 猜包装。
- 医疗器械证照页可上传证照原图作为参考图，但必须逐图核对证号、日期、主体、印章和表格字段；出现改写、乱码、缺失或新增则判废。

## 汇总交付

第三阶段默认不让 Agent 做逐图视觉质检，也不默认生成总览图或质检截图，避免额外 token 和中间产物。脚本只做前置尺寸解析、API 调用、基础状态记录和文件汇总。

正式输出后，脚本必须把本次所有最终 PNG 汇总到同一个 `final_delivery/` 文件夹，包含主图方图、主图长图、SKU 图和详情页图。用户在该文件夹内人工质检。

交付汇总文件夹中的图片也必须沿用款式编码前缀，例如 `JR0384_链接2_详情页_第03张.png`。`run_summary.json` 只记录行号、数量、尺寸、异常和 `final_delivery` 路径；总览图仅在显式要求时生成。
