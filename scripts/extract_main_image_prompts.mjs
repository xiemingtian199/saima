import fs from "node:fs/promises";
import path from "node:path";
import { FileBlob, SpreadsheetFile } from "@oai/artifact-tool";

const [, , workbookPath, outputPath, requestedSheetName] = process.argv;

if (!workbookPath || !outputPath) {
  console.error(
    "Usage: node extract_main_image_prompts.mjs <workbook.xlsx> <output.json> [sheet-name]",
  );
  process.exit(2);
}

const input = await FileBlob.load(workbookPath);
const workbook = await SpreadsheetFile.importXlsx(input);

const sheetSummary = await workbook.inspect({
  kind: "sheet",
  include: "id,name",
  maxChars: 4000,
});

const parsedSheets = sheetSummary.ndjson
  .trim()
  .split(/\r?\n/)
  .filter(Boolean)
  .map((line) => JSON.parse(line));
const sheetNames = parsedSheets.map((item) => String(item.name || "").trim());

let sheetName = requestedSheetName?.trim();
if (sheetName && !sheetNames.includes(sheetName)) {
  throw new Error(`未找到工作表“${sheetName}”。现有工作表: ${sheetNames.join(" | ")}`);
}
if (!sheetName) {
  sheetName =
    sheetNames.find((name) => name === "生图任务表") ||
    sheetNames.find((name) => name === "主图提示词") ||
    sheetNames.find((name) => name.includes("提示词"));
}
if (!sheetName) {
  throw new Error(`未找到生图提示词工作表。工作表摘要: ${sheetSummary.ndjson}`);
}
const sheet = workbook.worksheets.getItem(sheetName);

const values = sheet.getUsedRange(true).values;
if (!values || values.length < 2) {
  throw new Error(`${sheetName} 工作表没有可读取的数据行。`);
}

const headers = values[0].map((value) => String(value ?? "").trim());
const findHeader = (patterns) =>
  headers.findIndex((header) => patterns.some((pattern) => pattern.test(header)));

const descriptionIndex = findHeader([/^说明$/, /任务说明/, /图片说明/]);
const imageNoIndex = findHeader([
  /主图编号/,
  /详情页编号/,
  /SKU图编号/i,
  /任务编号/,
  /^编号$/,
  /图片编号/,
]);
const refIndex = findHeader([/^参考图的位置$/, /参考图/, /参考图片/, /参考素材/]);
const promptIndex = findHeader([/^生成提示词$/, /生图提示词/, /提示词/, /Prompt/i]);
const imageTypeIndex = findHeader([/图片类型/, /任务类型/]);
const linkOrderIndex = findHeader([/产品链接顺序/, /链接顺序/]);
const roleIndex = findHeader([/图片角色/, /页面角色/]);
const sizeIndex = findHeader([/成图尺寸/, /输出尺寸/, /图片尺寸/]);
const outputNameIndex = findHeader([/输出文件名/, /文件名/]);
const executionModeIndex = findHeader([/执行模式/, /生成模式/]);

const visibleCopyIndices = headers
  .map((header, index) =>
    /成图可见主标题|成图可见副标题|辅助卖点卡|辅助信息|辅助文案|底部信任条/.test(
      header,
    )
      ? index
      : -1,
  )
  .filter((index) => index >= 0);
const internalPlanningCopyPattern =
  /主要成分(?:先|要)?讲清|主要成分直接说明|主要成分不含糊|看得见材质|材质细节也值得看|围绕.+(?:展开|组织)|组织场景|证明.+价值|使用理由才成立|单片大小也要讲清|先看基材|材质微距|完整展开/;

if ((imageNoIndex < 0 && descriptionIndex < 0) || promptIndex < 0) {
  throw new Error(`无法识别必要列。表头: ${headers.join(" | ")}`);
}

function parseDescription(value) {
  const description = String(value ?? "").trim();
  const parts = description.split(/[|｜]/).map((part) => part.trim()).filter(Boolean);
  const legacyTaskId = /^[A-Z]\d{2,}-[A-Z]\d{2,}$/i.test(parts[0] || "") ? parts[0] : "";
  const rest = parts.length > 1 ? parts.slice(1).join("｜") : description;
  const linkMatch = description.match(/链接\s*([0-9A-Za-z]+)/);
  const indexMatch = description.match(/第\s*(\d+)(?:\s*\/\s*(\d+))?\s*张/);
  const sizeMatch = description.match(/尺寸\s*([0-9]{3,5}\s*[x×]\s*[0-9]{3,5})/i);
  const outputMatch = description.match(/(?:输出文件名|文件名)\s*[:：]\s*([^|｜\s]+)/);
  const imageType = /详情/.test(description) ? "详情页" : /SKU/i.test(description) ? "SKU图" : /主图/.test(description) ? "主图" : "";
  const typeKey = imageType === "主图" ? "main" : imageType === "SKU图" ? "sku" : imageType === "详情页" ? "detail" : "image";
  const linkOrder = linkMatch ? linkMatch[1] : "";
  const groupIndex = indexMatch ? Number(indexMatch[1]) : null;
  const groupTotal = indexMatch && indexMatch[2] ? Number(indexMatch[2]) : null;
  const imageNo = legacyTaskId || [
    linkOrder ? `L${linkOrder}` : "",
    typeKey,
    groupIndex ? String(groupIndex).padStart(2, "0") : "",
  ].filter(Boolean).join("-");
  return {
    description,
    imageNo,
    imageType,
    linkOrder,
    groupIndex,
    groupTotal,
    role: rest,
    outputSize: sizeMatch ? sizeMatch[1].replace(/\s+/g, "") : "",
    outputFileName: outputMatch ? outputMatch[1] : "",
    executionMode: "",
  };
}

const visibleCopyIssues = values.slice(1).flatMap((row, offset) =>
  visibleCopyIndices.flatMap((index) => {
    const value = String(row[index] ?? "").trim();
    return internalPlanningCopyPattern.test(value)
      ? [{ rowNumber: offset + 2, header: headers[index], value }]
      : [];
  }),
);
if (visibleCopyIssues.length > 0) {
  throw new Error(
    `消费者可见文案包含内部策划措辞，请返回第二阶段重写：${JSON.stringify(visibleCopyIssues)}`,
  );
}

const workbookDir = path.dirname(path.resolve(workbookPath));
const rows = values
  .slice(1)
  .map((row, offset) => {
    const parsedDescription = parseDescription(descriptionIndex >= 0 ? row[descriptionIndex] : "");
    const imageNo =
      imageNoIndex >= 0 ? String(row[imageNoIndex] ?? "").trim() : parsedDescription.imageNo;
    const referenceRaw = refIndex >= 0 ? String(row[refIndex] ?? "").trim() : "";
    const prompt = String(row[promptIndex] ?? "").trim();
    const references = referenceRaw
      .split(/[\n\r;；]+/)
      .map((part) => part.trim())
      .filter(Boolean)
      .map((part) => (path.isAbsolute(part) ? part : path.resolve(workbookDir, part)));

    return {
      rowNumber: offset + 2,
      imageNo,
      groupIndex: parsedDescription.groupIndex,
      groupTotal: parsedDescription.groupTotal,
      imageType:
        imageTypeIndex >= 0
          ? String(row[imageTypeIndex] ?? "").trim()
          : parsedDescription.imageType ||
            (sheetName.includes("详情")
              ? "详情页"
              : /SKU/i.test(sheetName)
                ? "SKU图"
                : "主图"),
      linkOrder: linkOrderIndex >= 0 ? String(row[linkOrderIndex] ?? "").trim() : parsedDescription.linkOrder,
      role: roleIndex >= 0 ? String(row[roleIndex] ?? "").trim() : parsedDescription.role,
      outputSize: sizeIndex >= 0 ? String(row[sizeIndex] ?? "").trim() : parsedDescription.outputSize,
      outputFileName:
        outputNameIndex >= 0 ? String(row[outputNameIndex] ?? "").trim() : parsedDescription.outputFileName,
      executionMode:
        executionModeIndex >= 0
          ? String(row[executionModeIndex] ?? "").trim()
          : parsedDescription.executionMode || "image_generation",
      referenceRaw,
      references,
      prompt,
    };
  })
  .filter((row) => row.imageNo || row.prompt);

await fs.mkdir(path.dirname(outputPath), { recursive: true });
await fs.writeFile(
  outputPath,
  JSON.stringify(
    {
      workbookPath: path.resolve(workbookPath),
      sheetName,
      headers,
      rows,
    },
    null,
    2,
  ),
  "utf8",
);

console.log(
  JSON.stringify(
    {
      sheetName,
      headers,
      rowCount: rows.length,
      outputPath: path.resolve(outputPath),
    },
    null,
    2,
  ),
);
