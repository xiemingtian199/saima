import fs from "node:fs";
import path from "node:path";

const [handoffPath, phase2Path] = process.argv.slice(2);
if (!handoffPath || !phase2Path) {
  console.error("Usage: node validate_phase2_output.mjs <phase1_handoff.json> <phase2_output.json>");
  process.exit(2);
}

const readJson = (file) => JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
let handoff;
let output;
try {
  handoff = readJson(handoffPath);
  output = readJson(phase2Path);
} catch (error) {
  console.error(`Cannot read JSON: ${error.message}`);
  process.exit(2);
}

const errors = [];
const warnings = [];
const allowedTop = new Set(["schema_version", "handoff_source", "tasks"]);
const allowedTask = new Set(["task_id", "visible_copy", "prompt_delta", "review_notes"]);
const allowedCopy = new Set(["headline", "subtitle", "cards", "footer"]);
const allowedDelta = new Set(["composition", "visual_evidence", "page_specific_constraints"]);
const absolutePathPattern = /[A-Za-z]:\\/;
const planningPattern = /讲清|直接说明|不含糊|围绕.{0,8}展开|证明.{0,8}价值|使用理由.{0,6}成立|不虚构|不[做作](?:为)?.{0,10}承诺|(?:人工|内部|发布前).{0,8}(?:核对|复核)|需(?:人工)?复核/;
const evidenceAsSellingPointPattern = /(?:报告编号|编号.{0,4}(?:清晰|明确|摆出来|可查|有记录)|报告.{0,4}(?:清晰|明确|摆出来|可查|有记录)|执行标准.{0,4}(?:清晰|明确)|标准.{0,4}(?:清晰|明确)|检测(?:报告|结果|项目|结论|合格|背书)|单项判定|符合\s*GB\s*15979|GB\s*15979(?:-2002)?|CTT\s*25030800143|资质背书|品质背书|标签.{0,4}(?:清晰|明确)|成分.{0,4}(?:清晰|明确)|配方.{0,4}(?:清晰|明确))/;
const mainVisibleRiskPattern = /植物乳杆菌|LN66|配方线索|配方清新双在线|说明书|使用前看说明|不(?:作|作为)治疗承诺|治疗承诺|不可吞服|儿童需成人指导/;
const mainVisibleProcessLeakPattern = /设计说明|构图|视觉证据|视觉参考|卖点提取|参考图|参考素材|注意事项|复核|审核|合规|当前页限制|提示词|模型|生成|不得|不要|禁止|避免/;
const normalizeForMatch = (value) => String(value || "").replace(/[\s:：/｜|,，。；;、\-]/g, "");

for (const key of Object.keys(output)) {
  if (!allowedTop.has(key)) errors.push(`unexpected top-level field: ${key}; phase 2 must be delta-only`);
}
for (const key of allowedTop) {
  if (!(key in output)) errors.push(`missing top-level field: ${key}`);
}
if (output.schema_version !== "1.0") errors.push("schema_version must be 1.0");
if (!Array.isArray(output.tasks)) errors.push("tasks must be an array");
if (typeof output.handoff_source !== "string" || !output.handoff_source) errors.push("handoff_source must be a non-empty string");
if (absolutePathPattern.test(JSON.stringify(output))) errors.push("phase 2 output must not contain absolute paths");

const sourceTasks = new Map((handoff.tasks || []).map((task) => [task.task_id, task]));
const seen = new Set();
const forbidden = [
  ...(handoff.stage2_contract?.forbidden_visible_terms || []),
  "100%有效",
  "绝对安全",
  "不过敏",
  "无刺激",
];

for (const task of output.tasks || []) {
  for (const key of Object.keys(task)) {
    if (!allowedTask.has(key)) errors.push(`task ${task.task_id || "?"} has unexpected field: ${key}`);
  }
  if (!task.task_id) {
    errors.push("phase 2 task missing task_id");
    continue;
  }
  if (seen.has(task.task_id)) errors.push(`duplicate task_id: ${task.task_id}`);
  seen.add(task.task_id);
  const source = sourceTasks.get(task.task_id);
  if (!source) {
    errors.push(`unknown task_id: ${task.task_id}`);
    continue;
  }

  if (!task.visible_copy || typeof task.visible_copy !== "object") {
    errors.push(`task ${task.task_id} missing visible_copy`);
  } else {
    for (const key of Object.keys(task.visible_copy)) {
      if (!allowedCopy.has(key)) errors.push(`task ${task.task_id} visible_copy has unexpected field: ${key}`);
    }
    const { headline, subtitle, cards, footer } = task.visible_copy;
    if (![headline, subtitle, footer].every((v) => typeof v === "string" && v.trim())) {
      errors.push(`task ${task.task_id} headline/subtitle/footer must be non-empty strings`);
    }
    if (!Array.isArray(cards) || cards.some((v) => typeof v !== "string" || !v.trim())) {
      errors.push(`task ${task.task_id} cards must be a non-empty string array`);
    } else if (Number.isInteger(source.copy_brief?.card_count) && cards.length !== source.copy_brief.card_count) {
      errors.push(`task ${task.task_id} card count ${cards.length} does not match required ${source.copy_brief.card_count}`);
    }
    const visible = [headline, subtitle, ...(cards || []), footer].filter(Boolean).join(" ");
    if (planningPattern.test(visible)) errors.push(`task ${task.task_id} contains internal planning language`);
    if (evidenceAsSellingPointPattern.test(visible)) {
      errors.push(`task ${task.task_id} turns evidence/standards/report identifiers into visible selling copy`);
    }
    if (source.type === "main" && mainVisibleRiskPattern.test(visible)) {
      errors.push(`task ${task.task_id} contains main-image visible compliance or unverified formula copy`);
    }
    if (source.type === "main" && mainVisibleProcessLeakPattern.test(visible)) {
      errors.push(`task ${task.task_id} contains main-image visible design/process/control copy`);
    }
    for (const phrase of forbidden) {
      if (phrase && visible.includes(phrase)) errors.push(`task ${task.task_id} contains forbidden visible phrase: ${phrase}`);
    }
    for (const required of source.visible_copy_required || []) {
      if (!normalizeForMatch(visible).includes(normalizeForMatch(required))) {
        errors.push(`task ${task.task_id} missing required visible copy: ${required}`);
      }
    }
  }

  if (!task.prompt_delta || typeof task.prompt_delta !== "object") {
    errors.push(`task ${task.task_id} missing prompt_delta`);
  } else {
    for (const key of Object.keys(task.prompt_delta)) {
      if (!allowedDelta.has(key)) errors.push(`task ${task.task_id} prompt_delta has unexpected field: ${key}`);
    }
    if (typeof task.prompt_delta.composition !== "string" || !task.prompt_delta.composition.trim()) {
      errors.push(`task ${task.task_id} prompt_delta.composition must be a non-empty string`);
    }
    for (const key of ["visual_evidence", "page_specific_constraints"]) {
      if (!Array.isArray(task.prompt_delta[key]) || task.prompt_delta[key].some((v) => typeof v !== "string")) {
        errors.push(`task ${task.task_id} prompt_delta.${key} must be a string array`);
      }
    }
  }
  if (!Array.isArray(task.review_notes) || task.review_notes.some((v) => typeof v !== "string")) {
    errors.push(`task ${task.task_id} review_notes must be a string array`);
  }
}

for (const id of sourceTasks.keys()) {
  if (!seen.has(id)) errors.push(`missing phase 2 task: ${id}`);
}
if ((output.tasks || []).length !== sourceTasks.size) {
  errors.push(`task count mismatch: expected ${sourceTasks.size}, got ${(output.tasks || []).length}`);
}

const report = {
  file: path.resolve(phase2Path),
  valid: errors.length === 0,
  counts: { expected: sourceTasks.size, actual: output.tasks?.length || 0 },
  errors,
  warnings,
};
console.log(JSON.stringify(report, null, 2));
process.exit(errors.length === 0 ? 0 : 1);
