import fs from "node:fs/promises";
import path from "node:path";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const [handoffPath, compiledPath, outputPath, requestedQaDir] = process.argv.slice(2);
if (!handoffPath || !compiledPath || !outputPath) {
  console.error(
    "Usage: node build_generation_handoff_workbook.mjs <phase1_handoff.json> <phase2_compiled.json> <output.xlsx> [qa-dir]",
  );
  process.exit(2);
}

const readJson = async (file) => JSON.parse((await fs.readFile(file, "utf8")).replace(/^\uFEFF/, ""));
const handoff = await readJson(handoffPath);
const compiled = await readJson(compiledPath);
const qaDir = requestedQaDir || path.join(path.dirname(outputPath), "_generation_handoff_qa");

await fs.mkdir(path.dirname(outputPath), { recursive: true });
await fs.mkdir(qaDir, { recursive: true });

const links = new Map((handoff.links || []).map((link) => [link.link_id, link]));
const typeOrder = { main: 1, sku: 2, detail: 3 };
const typeLabel = { main: "主图", sku: "SKU图", detail: "详情页" };
const groupKey = (task) => `${task.link_id || "NO_LINK"}::${task.type || "image"}`;
const groupCounts = new Map();
for (const task of compiled.tasks || []) {
  const key = groupKey(task);
  groupCounts.set(key, (groupCounts.get(key) || 0) + 1);
}

const groupPositions = new Map();
const sortedTasks = [...(compiled.tasks || [])].sort((a, b) => {
  const linkA = links.get(a.link_id);
  const linkB = links.get(b.link_id);
  return (
    (Number(linkA?.order) || 999) - (Number(linkB?.order) || 999) ||
    (typeOrder[a.type] || 99) - (typeOrder[b.type] || 99) ||
    (Number(a.sequence) || 999) - (Number(b.sequence) || 999) ||
    String(a.task_id).localeCompare(String(b.task_id), "zh-Hans-CN")
  );
});

function makeDescription(task) {
  const link = links.get(task.link_id);
  const linkText = link ? `链接${link.order}` : task.link_id || "未分链接";
  const taskType = typeLabel[task.type] || "图片";
  const key = groupKey(task);
  const current = (groupPositions.get(key) || 0) + 1;
  groupPositions.set(key, current);
  const total = groupCounts.get(key) || 1;
  return `${linkText}｜${taskType}｜第${current}/${total}张`;
}

function makeReferences(task) {
  const references = task.api_reference_paths || [];
  return references.join("\n");
}

function makePrompt(task) {
  return task.generation_prompt || "";
}

const rows = [["说明", "参考图的位置", "生成提示词"]];
for (const task of sortedTasks) {
  rows.push([makeDescription(task), makeReferences(task), makePrompt(task)]);
}

const workbook = Workbook.create();
const sheet = workbook.worksheets.add("生图任务表");
sheet.showGridLines = true;

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
header.format.rowHeightPx = 30;

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
  body.format.rowHeightPx = 150;
}

sheet.getRangeByIndexes(0, 0, rows.length, 1).format.columnWidthPx = 260;
sheet.getRangeByIndexes(0, 1, rows.length, 1).format.columnWidthPx = 520;
sheet.getRangeByIndexes(0, 2, rows.length, 1).format.columnWidthPx = 900;
sheet.freezePanes.freezeRows(1);
sheet.tables.add(`A1:C${rows.length}`, true, "GenerationTaskHandoff");

const inspect = await workbook.inspect({
  kind: "table",
  range: `生图任务表!A1:C${Math.min(rows.length, 8)}`,
  include: "values,formulas",
  tableMaxRows: 8,
  tableMaxCols: 3,
  tableMaxCellChars: 260,
  maxChars: 6000,
});
await fs.writeFile(path.join(qaDir, "generation_handoff_inspection.txt"), inspect.ndjson, "utf8");
const preview = await workbook.render({
  sheetName: "生图任务表",
  range: `A1:C${Math.min(rows.length, 8)}`,
  scale: 1,
  format: "png",
});
await fs.writeFile(
  path.join(qaDir, "生图任务表_preview.png"),
  new Uint8Array(await preview.arrayBuffer()),
);

const exported = await SpreadsheetFile.exportXlsx(workbook);
await exported.save(outputPath);
console.log(
  JSON.stringify(
    {
      outputPath: path.resolve(outputPath),
      qaDir: path.resolve(qaDir),
      sheet: "生图任务表",
      headers: rows[0],
      rowCount: rows.length - 1,
    },
    null,
    2,
  ),
);
