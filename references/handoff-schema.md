# 阶段一交接包规范

## 目标

让阶段二 Agent 不读取原图、不遍历素材目录，也能完成消费者文案与生图提示词。策略 Markdown 供人审核，`phase1_handoff.json` 是机器交接的唯一事实源。

## 输出位置

在产品目录创建：

```text
outputs/<产品编号>_saima_handoff/
├── <产品编号>_赛马策略与必要信息.md
├── phase1_handoff.json
└── stage2_agent_instruction.txt
```

如果需要跨机器交接，可再建立 `reference_pack/`，只复制交接包 `assets` 中被任务引用的我品图片；同机 Agent 默认直接使用原绝对路径，不重复复制。

## 顶层字段

| 字段 | 要求 |
| --- | --- |
| `schema_version` | 固定 `1.0` |
| `status` | `draft` 或 `confirmed`；未经用户确认不得进入正式阶段二 |
| `product_root` | 产品素材文件夹绝对路径 |
| `strategy_markdown` | 对应策略 Markdown 绝对路径 |
| `product` | 产品编号、品牌、名称、类目、医疗器械标记、主推 SKU、可核验事实 |
| `claims` | 事实到消费者价值的翻译；每条必须绑定证据资产 |
| `compliance` | 全局禁用、需复核项和类目边界 |
| `visual_system` | 全局色系、质感、组件、产品锁定和连续性；任务行不重复 |
| `assets` | 阶段一已看过并选中的参考图卡片 |
| `links` | 已确认或待确认的链接宣传方向 |
| `tasks` | 主图、SKU 图和详情页的逐页任务骨架 |
| `stage2_contract` | 阶段二允许填写、禁止修改和输出格式 |

`stage2_contract` 必须包含 `forbidden_visible_terms`。这些是当前产品特有的高风险扩写，例如无证据的“精准定位”“稳定粘贴”“即开即用”，以及容易进入成图的内部审核语言。

## 资产卡 `assets[]`

每张被任务使用的图片必须有唯一资产卡：

```json
{
  "asset_id": "P001",
  "absolute_path": "E:\\...\\主图-01.jpg",
  "relative_path": "恒品现有链接素材\\主图-01.jpg",
  "owner": "self",
  "reference_type": "identity",
  "summary": "蓝色膝部预分切贴佩戴效果及恒品包装",
  "readable_text": ["恒品", "6片/盒"],
  "locked_elements": ["恒品 logo", "蓝色 T 型贴片", "包装色块"],
  "allowed_uses": ["产品身份基准", "首图产品外观"],
  "prohibited_uses": ["改写包装文字", "虚构规格"],
  "upload_to_image_api": true,
  "priority": 1
}
```

`owner` 使用 `self`、`competitor`、`platform`。`reference_type` 使用：

- `identity`：我品身份基准，允许上传且优先排第一；
- `evidence`：我品事实、材质、步骤或参数证据；
- `visual`：只借鉴构图、色调和质感；
- `selling_point`：只借鉴表达结构；
- `fixed_asset`：证照、备案、检测报告样张等不可改写信息资产；新流程中通常作为上传参考图使用，提示词要求画框展示且文字编号印章和版式不改，不再默认本地合成；
- `sku`：购买选择信息。

竞品资产的 `upload_to_image_api` 必须为 `false`。

## 链接 `links[]`

每条链接只保留一个主方向，并至少包含：`link_id`、`order`、`name`、`direction`、`audience`、`need`、`scene`、`core_claim_ids`、`supporting_claim_ids`、`visual_direction`。

`visual_direction` 是链接级视觉差异，不是全局母版的重复。它必须写清：场景氛围、主色/辅助色、光感、背景元素和信息组件方向。多条链接不得全部写成同一套蓝白背景或同一句视觉描述；阶段二和编译脚本会把它合并进每张图的最终提示词。

## 页面任务 `tasks[]`

阶段一必须完成页面角色和参考图绑定，阶段二只补文案与提示词差异：

```json
{
  "task_id": "L01-M01",
  "link_id": "L01",
  "type": "main",
  "sequence": 1,
  "role": "场景需求点击图",
  "objective": "让运动前不想裁剪的人快速理解预分切价值",
  "reference_asset_ids": ["P001", "P002"],
  "reference_bindings": [
    {"asset_id": "P001", "purpose": "唯一产品身份基准", "include_in_api": true}
  ],
  "required_claim_ids": ["C001"],
  "must_show": ["恒品品牌", "膝部预分切结构"],
  "visible_copy_required": ["膝部预分切"],
  "visual_brief": "右侧膝部佩戴，左侧产品和包装",
  "copy_brief": {
    "headline_goal": "直接说明膝部预分切",
    "subtitle_goal": "表达运动前少一步剪裁",
    "card_count": 4,
    "footer_goal": "资质或规格信任"
  },
  "prompt_constraints": ["产品正面印刷不可改写"],
  "dimensions": "1440x1440",
  "output_filename": "L01_main_01.png",
  "risk_level": "normal"
}
```

`type` 使用 `main`、`detail`、`sku`。`risk_level` 使用 `normal`、`review`、`fixed_asset`。只有医疗器械且用户确认需要展示注册证/备案证明时，才把证照页设为 `fixed_asset`；非医疗器械产品不得为了补信任页而固定规划注册证/备案证明页。

多颜色产品的 `sku` 任务必须按颜色拆分，每个颜色一个任务，并绑定该颜色的产品身份参考图。全色系集合展示属于详情页收尾或人审说明，不应作为单张 SKU 图任务。

主图任务的 `copy_brief` 只写消费者最终能看到的表达目标，不写设计说明、构图说明、卖点提取过程、参考图用途、注意事项、复核提醒或合规限制。这些内容分别放入 `visual_brief`、`prompt_constraints`、`review_notes` 或链接级 `visual_direction`。

当规格、证号、SKU组合或使用边界必须逐字进入消费者文案时，增加 `visible_copy_required`。校验器会忽略空格和常见分隔符后检查，不满足则阶段二不得交付。

## 阶段二输出

阶段二不得覆盖交接包。另存 `phase2_output.json`：

```json
{
  "schema_version": "1.0",
  "handoff_source": "phase1_handoff.json",
  "tasks": [
    {
      "task_id": "L01-M01",
      "visible_copy": {
        "headline": "...",
        "subtitle": "...",
        "cards": ["..."],
        "footer": "..."
      },
      "prompt_delta": {
        "composition": "右侧真实佩戴，左侧产品和包装",
        "visual_evidence": ["膝部预分切结构", "6片/盒规格卡"],
        "page_specific_constraints": ["不混入组合SKU"]
      },
      "review_notes": []
    }
  ]
}
```

阶段二文件只允许顶层字段 `schema_version`、`handoff_source`、`tasks`。不得复制或修改产品事实、资质字段、资产摘要、链接方向和页面角色；不得包含任何绝对路径。完整提示词由脚本合并生成。

阶段二校验通过后，脚本可生成两个工作簿：

```text
<产品编号>_主图与详情页生图任务表.xlsx   # 展示版，多工作表，供人审阅
<产品编号>_脚本生图交接表.xlsx           # 执行版，只给脚本读取
```

执行版工作簿必须只包含工作表 `生图任务表`，且 A1:C1 固定为：

| 说明 | 参考图的位置 | 生成提示词 |
| --- | --- | --- |

每一行代表一张待生成图片，不设置分组标题行、空行、合计行或说明页。`说明` 只包含三段：这是第几个链接、这是主图/SKU 图/详情页、这是这一组第几张/总张数，例如 `链接1｜主图｜第1/5张`。不要在 `说明` 中写任务编号、图片角色、尺寸、输出文件名或执行模式。`参考图的位置` 写该行需要上传的我品参考图或证照/资料参考图绝对路径，多个路径用换行分隔；竞品路径不得出现。`生成提示词` 写第三阶段脚本可直接传入的极简 API 提示词，只包含参考图说明、画面规格、画面描述和页面中需要带出的文字。不要写任务编号、前后上下文、页面角色、审核提醒、复核备注、通用禁用词或“不要写某某”。证照/资料页若使用上传参考图，应在画面描述中要求证照放入画框或展示框，证照中文字、编号、印章和版式保持参考图原样。

## 校验

运行：

```powershell
node "C:\Users\HK\.codex\skills\saima-plan\scripts\validate_handoff.mjs" "<phase1_handoff.json>"
node "C:\Users\HK\.codex\skills\saima-plan\scripts\validate_phase2_output.mjs" "<phase1_handoff.json>" "<phase2_output.json>"
```

必须通过：字段完整、ID 唯一、引用存在、我品路径存在、竞品不上传、任务顺序有效。医疗器械是否需要证照页由产品属性、素材和用户确认共同决定；非医疗器械产品不要求证照任务。`status=draft` 可以测试阶段二，但正式生成 Excel 前必须由用户确认并改为 `confirmed`。
