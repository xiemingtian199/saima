import fs from "node:fs/promises";
import path from "node:path";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const [handoffPath, compiledPath, outputPath, requestedQaDir] = process.argv.slice(2);
if (!handoffPath || !compiledPath || !outputPath) {
  console.error("Usage: node build_phase2_workbook.mjs <phase1_handoff.json> <phase2_compiled.json> <output.xlsx> [qa-dir]");
  process.exit(2);
}

const readJson = async (file) => JSON.parse((await fs.readFile(file, "utf8")).replace(/^\uFEFF/, ""));
const handoff = await readJson(handoffPath);
const compiled = await readJson(compiledPath);
const qaDir = requestedQaDir || path.join(path.dirname(outputPath), "_workbook_qa");
await fs.mkdir(path.dirname(outputPath), { recursive: true });
await fs.mkdir(qaDir, { recursive: true });

const sourceTasks = new Map(handoff.tasks.map((task) => [task.task_id, task]));
const assets = new Map(handoff.assets.map((asset) => [asset.asset_id, asset]));
const links = new Map(handoff.links.map((link) => [link.link_id, link]));
const listText = (value) => Array.isArray(value) ? value.join("\n") : String(value || "");
const productFacts = handoff.product.facts || handoff.product.verified_facts || [];
const primarySku = handoff.product.primary_sku || handoff.product.main_sku || "";
const categoryBoundary = handoff.compliance.category_boundary || handoff.compliance.category_boundaries || "";
const visualDirection = [
  handoff.visual_system.palette || handoff.visual_system.global_palette,
  handoff.visual_system.style || handoff.visual_system.texture,
].filter(Boolean).join("；");

const summaryRows = [
  ["字段", "内容"],
  ["产品编号", handoff.product.product_id],
  ["品牌", handoff.product.brand],
  ["产品名称", handoff.product.name],
  ["备案/注册名称", handoff.product.registered_name || ""],
  ["类目", handoff.product.category],
  ["主推SKU", primarySku],
  ["可核验事实", listText(productFacts)],
  ["合规边界", categoryBoundary],
  ["全局视觉方向", visualDirection],
  ["产品锁定", listText(handoff.visual_system.product_lock)],
  ["阶段一交接文件", path.resolve(handoffPath)],
  ["阶段二增量文件", path.resolve(compiled.phase2_source)],
];
for (const link of handoff.links) {
  summaryRows.push([
    `链接${link.order}：${link.name}`,
    `方向：${link.direction}\n人群：${link.audience}\n需求：${link.need}\n场景：${link.scene}`,
  ]);
}

const assetRows = [["资产ID", "归属", "参考类型", "绝对路径", "画面摘要", "允许用途", "禁止用途", "允许上传API"]];
for (const asset of handoff.assets) {
  assetRows.push([
    asset.asset_id,
    asset.owner,
    asset.reference_type,
    asset.absolute_path,
    asset.summary,
    (asset.allowed_uses || []).join("｜"),
    (asset.prohibited_uses || []).join("｜"),
    asset.upload_to_image_api ? "是" : "否",
  ]);
}

const getReferenceUsage = (source) => (source.reference_bindings || [])
  .map((binding) => {
    const asset = assets.get(binding.asset_id);
    const mode = binding.include_in_api ? "上传API" : "不上传，仅用阶段一摘要";
    return `${binding.asset_id}｜${binding.purpose}｜${mode}`;
  })
  .join("\n");

const getPreviousRole = (source) => {
  if (source.type !== "detail" || source.sequence <= 1) return "首屏，无上一页";
  const previous = handoff.tasks.find((task) =>
    task.link_id === source.link_id && task.type === "detail" && task.sequence === source.sequence - 1
  );
  return previous ? `${previous.role} → ${source.role}` : "承接上一屏";
};

const promptHeaders = (idHeader, includePrevious = false) => [
  idHeader,
  "图片类型",
  "产品链接顺序",
  "链接宣传方向",
  "图片角色",
  ...(includePrevious ? ["承接上一页"] : []),
  "参考图（绝对路径）",
  "参考图用途",
  "成图可见主标题",
  "成图可见副标题",
  "辅助卖点卡",
  "底部信任条",
  "生图提示词（含成图可见文案）",
  "成图尺寸",
  "输出文件名",
  "执行模式",
  "复核备注",
];

const makePromptRows = (type, idHeader, includePrevious = false) => {
  const rows = [promptHeaders(idHeader, includePrevious)];
  const tasks = compiled.tasks
    .filter((task) => task.type === type)
    .sort((a, b) => {
      const linkA = links.get(a.link_id);
      const linkB = links.get(b.link_id);
      return (
        (Number(linkA?.order) || 999) - (Number(linkB?.order) || 999) ||
        (Number(a.sequence) || 999) - (Number(b.sequence) || 999) ||
        String(a.task_id).localeCompare(String(b.task_id), "zh-Hans-CN")
      );
    });
  for (const task of tasks) {
    const source = sourceTasks.get(task.task_id);
    const link = links.get(task.link_id);
    const references = task.api_reference_paths;
    const prompt = task.generation_prompt;
    rows.push([
      task.task_id,
      type === "main" ? "主图" : type === "sku" ? "SKU图" : "详情页",
      `${link.order}-${link.link_id}`,
      link.direction,
      task.role,
      ...(includePrevious ? [getPreviousRole(source)] : []),
      references.join("\n"),
      getReferenceUsage(source),
      task.visible_copy.headline,
      task.visible_copy.subtitle,
      task.visible_copy.cards.join("\n"),
      task.visible_copy.footer,
      prompt,
      task.dimensions,
      task.output_filename,
      task.execution_mode,
      (task.review_notes || []).join("\n"),
    ]);
  }
  return rows;
};

const workbook = Workbook.create();

function writeTableSheet(name, rows, widths, tableName, rowHeight = 72) {
  const sheet = workbook.worksheets.add(name);
  sheet.showGridLines = false;
  const range = sheet.getRangeByIndexes(0, 0, rows.length, rows[0].length);
  range.values = rows;
  range.format = {
    font: { size: 10, color: "#172033" },
    wrapText: true,
    verticalAlignment: "top",
  };
  const header = sheet.getRangeByIndexes(0, 0, 1, rows[0].length);
  header.format = {
    fill: "#0F6B8F",
    font: { bold: true, color: "#FFFFFF", size: 10 },
    wrapText: true,
    verticalAlignment: "center",
    borders: { preset: "outside", style: "thin", color: "#0A4E69" },
  };
  if (rows.length > 1) {
    const body = sheet.getRangeByIndexes(1, 0, rows.length - 1, rows[0].length);
    body.format = {
      fill: "#FFFFFF",
      wrapText: true,
      verticalAlignment: "top",
      borders: {
        insideHorizontal: { style: "thin", color: "#E2E8F0" },
        bottom: { style: "thin", color: "#CBD5E1" },
      },
    };
    body.format.rowHeightPx = rowHeight;
  }
  header.format.rowHeightPx = 34;
  widths.forEach((width, index) => {
    sheet.getRangeByIndexes(0, index, rows.length, 1).format.columnWidthPx = width;
  });
  sheet.freezePanes.freezeRows(1);
  if (rows[0].length > 8) sheet.freezePanes.freezeColumns(5);
  sheet.tables.add(`A1:${columnName(rows[0].length)}${rows.length}`, true, tableName);
  return sheet;
}

function columnName(count) {
  let value = count;
  let result = "";
  while (value > 0) {
    const remainder = (value - 1) % 26;
    result = String.fromCharCode(65 + remainder) + result;
    value = Math.floor((value - 1) / 26);
  }
  return result;
}

writeTableSheet("产品策略摘要", summaryRows, [190, 760], "StrategySummary", 64);
writeTableSheet("参考资产索引", assetRows, [80, 80, 110, 520, 320, 260, 260, 100], "AssetIndex", 70);

const mainRows = makePromptRows("main", "主图编号");
const skuRows = makePromptRows("sku", "SKU图编号");
const detailRows = makePromptRows("detail", "详情页编号", true);
const commonWidths = [100, 90, 120, 250, 220, 460, 320, 220, 240, 280, 230, 760, 120, 220, 160, 320];
writeTableSheet("主图提示词", mainRows, commonWidths, "MainPromptTasks", 170);
writeTableSheet("SKU图提示词", skuRows, commonWidths, "SkuPromptTasks", 150);
writeTableSheet("详情页提示词", detailRows, [100, 90, 120, 250, 220, 220, 460, 320, 220, 240, 280, 230, 760, 120, 220, 160, 320], "DetailPromptTasks", 170);

const checks = [];
for (const spec of [
  { name: "产品策略摘要", range: `A1:B${Math.min(summaryRows.length, 10)}` },
  { name: "参考资产索引", range: `A1:H${Math.min(assetRows.length, 7)}` },
  { name: "主图提示词", range: `A1:P${Math.min(mainRows.length, 4)}` },
  { name: "SKU图提示词", range: `A1:P${Math.min(skuRows.length, 3)}` },
  { name: "详情页提示词", range: `A1:Q${Math.min(detailRows.length, 4)}` },
]) {
  const inspect = await workbook.inspect({
    kind: "table",
    range: `${spec.name}!${spec.range}`,
    include: "values,formulas",
    tableMaxRows: 8,
    tableMaxCols: 18,
    tableMaxCellChars: 180,
    maxChars: 6000,
  });
  checks.push(`--- ${spec.name} ---\n${inspect.ndjson}`);
  const preview = await workbook.render({ sheetName: spec.name, range: spec.range, scale: 1, format: "png" });
  await fs.writeFile(path.join(qaDir, `${spec.name}_preview.png`), new Uint8Array(await preview.arrayBuffer()));
}

const formulaErrors = await workbook.inspect({
  kind: "match",
  searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A",
  options: { useRegex: true, maxResults: 100 },
  summary: "formula error scan",
  maxChars: 2000,
});
checks.push(`--- FORMULA_ERRORS ---\n${formulaErrors.ndjson}`);
await fs.writeFile(path.join(qaDir, "workbook_inspection.txt"), checks.join("\n"), "utf8");

const exported = await SpreadsheetFile.exportXlsx(workbook);
await exported.save(outputPath);
console.log(JSON.stringify({
  outputPath: path.resolve(outputPath),
  qaDir: path.resolve(qaDir),
  sheets: ["产品策略摘要", "参考资产索引", "主图提示词", "SKU图提示词", "详情页提示词"],
  counts: { main: mainRows.length - 1, sku: skuRows.length - 1, detail: detailRows.length - 1 },
}, null, 2));
