import fs from "node:fs";
import path from "node:path";

const [handoffPath, phase2Path, outputPath] = process.argv.slice(2);
if (!handoffPath || !phase2Path || !outputPath) {
  console.error("Usage: node compile_phase2_output.mjs <phase1_handoff.json> <phase2_output.json> <phase2_compiled.json>");
  process.exit(2);
}

const readJson = (file) => JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
const handoff = readJson(handoffPath);
const phase2 = readJson(phase2Path);
const allowedTop = new Set(["schema_version", "handoff_source", "tasks"]);
for (const key of Object.keys(phase2)) {
  if (!allowedTop.has(key)) throw new Error(`Unsafe phase 2 field: ${key}; validate delta-only output first`);
}
if (/[A-Za-z]:\\/.test(JSON.stringify(phase2))) {
  throw new Error("Unsafe phase 2 output: absolute paths are forbidden");
}
if (!Array.isArray(phase2.tasks) || phase2.tasks.length !== handoff.tasks.length) {
  throw new Error(`Phase 2 task count mismatch: expected ${handoff.tasks.length}, got ${phase2.tasks?.length || 0}`);
}
const assets = new Map(handoff.assets.map((asset) => [asset.asset_id, asset]));
const deltas = new Map(phase2.tasks.map((task) => [task.task_id, task]));
const links = new Map((handoff.links || []).map((link) => [link.link_id, link]));

const formatCopy = (copy) => [
  `主标题：${copy.headline}`,
  `副标题：${copy.subtitle}`,
  Array.isArray(copy.cards) && copy.cards.length ? `辅助信息：${copy.cards.join("｜")}` : "",
  copy.footer ? `底部条：${copy.footer}` : "",
].filter(Boolean).join("\n");

const formatReferencePrompt = (apiBindings) => {
  if (!apiBindings.length) return "参考图：无上传参考图，按画面描述生成。";
  const first = apiBindings[0].asset?.reference_type === "identity"
    ? "第一张为产品身份基准，"
    : "";
  const multiple = apiBindings.length > 1 ? `共${apiBindings.length}张参考图，按上传顺序使用；` : "";
  return `参考图：使用已上传参考图，${multiple}${first}产品颜色、结构、Logo、包装和印刷以参考图为准。`;
};

const formatImagePrompt = ({ source, delta, apiBindings }) => [
  formatReferencePrompt(apiBindings),
  `画面规格：${source.dimensions}。`,
  `画面描述：${[
    delta.prompt_delta.composition,
    ...(delta.prompt_delta.visual_evidence || []),
  ].filter(Boolean).join("；")}。`,
  `页面中需要带出的文字：\n${formatCopy(delta.visible_copy)}`,
].join("\n");

const compiledTasks = handoff.tasks.map((source) => {
  const delta = deltas.get(source.task_id);
  const link = links.get(source.link_id);
  const linkVisualDirection = String(link?.visual_direction || "").trim();
  if (!delta) throw new Error(`Missing phase 2 task: ${source.task_id}`);
  if (!delta.visible_copy || !delta.prompt_delta || !Array.isArray(delta.review_notes)) {
    throw new Error(`Invalid phase 2 task structure: ${source.task_id}`);
  }

  const apiBindings = source.reference_bindings
    .map((binding) => ({ binding, asset: assets.get(binding.asset_id) }))
    .filter(({ binding, asset }) =>
      binding.include_in_api === true &&
      asset?.upload_to_image_api === true &&
      asset?.owner === "self"
    )
    .sort((a, b) => (a.asset.priority || 99) - (b.asset.priority || 99));

  const fixedAssets = source.reference_bindings
    .map((binding) => assets.get(binding.asset_id))
    .filter((asset) => asset?.reference_type === "fixed_asset");

  const executionMode = "image_generation";
  const generationPrompt = formatImagePrompt({ source, delta, apiBindings });

  return {
    task_id: source.task_id,
    link_id: source.link_id,
    type: source.type,
    sequence: source.sequence,
    role: source.role,
    dimensions: source.dimensions,
    output_filename: source.output_filename,
    execution_mode: executionMode,
    api_reference_paths: apiBindings.map(({ asset }) => asset.absolute_path),
    fixed_asset_paths: fixedAssets.map((asset) => asset.absolute_path),
    link_visual_direction: linkVisualDirection,
    visible_copy: delta.visible_copy,
    generation_prompt: generationPrompt,
    composition_instructions: null,
    review_notes: delta.review_notes,
  };
});

const compiled = {
  schema_version: "1.0",
  handoff_source: path.resolve(handoffPath),
  phase2_source: path.resolve(phase2Path),
  product_id: handoff.product.product_id,
  tasks: compiledTasks,
};

fs.writeFileSync(outputPath, `${JSON.stringify(compiled, null, 2)}\n`, "utf8");
console.log(JSON.stringify({ output: path.resolve(outputPath), tasks: compiledTasks.length }, null, 2));
