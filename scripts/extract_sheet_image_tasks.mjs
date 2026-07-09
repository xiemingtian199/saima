import fs from "node:fs/promises";
import path from "node:path";
import { FileBlob, SpreadsheetFile } from "@oai/artifact-tool";

const args = process.argv.slice(2);

function readFlag(name, fallback = undefined) {
  const index = args.indexOf(name);
  if (index < 0) return fallback;
  const value = args[index + 1];
  if (!value || value.startsWith("--")) return "";
  return value;
}

function hasFlag(name) {
  return args.includes(name);
}

function splitList(value) {
  return String(value || "")
    .split(/[|,，]+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function columnLetterToIndex(value) {
  const clean = String(value || "").trim().toUpperCase();
  if (!/^[A-Z]+$/.test(clean)) return -1;
  let result = 0;
  for (const ch of clean) {
    result = result * 26 + (ch.charCodeAt(0) - 64);
  }
  return result - 1;
}

function resolveColumn(headers, selector, options = {}) {
  const { required = false, label = "列" } = options;
  const raw = String(selector || "").trim();
  if (!raw) {
    if (required) throw new Error(`缺少${label}。可用表头: ${headers.join(" | ")}`);
    return -1;
  }

  if (/^\d+$/.test(raw)) {
    const index = Number(raw) - 1;
    if (index >= 0 && index < headers.length) return index;
  }

  const letterIndex = columnLetterToIndex(raw);
  if (letterIndex >= 0 && letterIndex < headers.length) return letterIndex;

  let index = headers.findIndex((header) => header === raw);
  if (index >= 0) return index;

  index = headers.findIndex((header) => header.toLowerCase() === raw.toLowerCase());
  if (index >= 0) return index;

  index = headers.findIndex((header) => header.includes(raw));
  if (index >= 0) return index;

  if (required) {
    throw new Error(`找不到${label}“${raw}”。可用表头: ${headers.join(" | ")}`);
  }
  return -1;
}

function autoFind(headers, patterns) {
  return headers.findIndex((header) => patterns.some((pattern) => pattern.test(header)));
}

function normalizeReferences(rawValues, workbookDir) {
  return rawValues
    .flatMap((value) =>
      String(value ?? "")
        .split(/[\n\r;；]+/)
        .map((part) => part.trim())
        .filter(Boolean),
    )
    .map((part) => (path.isAbsolute(part) ? part : path.resolve(workbookDir, part)));
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

function parseSizeFromText(value) {
  const match = String(value ?? "").match(/(?:尺寸|成图尺寸)?\s*([0-9]{3,5})\s*[x×]\s*([0-9]{3,5})/i);
  return match ? `${match[1]}x${match[2]}` : "";
}

const workbookPath = readFlag("--workbook");
const outputPath = readFlag("--output");
const requestedSheetName = readFlag("--sheet");
const inspectOnly = hasFlag("--inspect");

if (!workbookPath) {
  console.error(
    "Usage: node extract_sheet_image_tasks.mjs --workbook <workbook.xlsx> [--output <output.json>] [--sheet <sheet>] --prompt-column <header|letter|number> [--reference-columns <col1,col2>] [--id-column <col>]",
  );
  process.exit(2);
}

if (!inspectOnly && !outputPath) {
  console.error("Missing --output <output.json>.");
  process.exit(2);
}

const input = await FileBlob.load(workbookPath);
const workbook = await SpreadsheetFile.importXlsx(input);
const sheetSummary = await workbook.inspect({
  kind: "sheet",
  include: "id,name",
  maxChars: 6000,
});

const parsedSheets = sheetSummary.ndjson
  .trim()
  .split(/\r?\n/)
  .filter(Boolean)
  .map((line) => JSON.parse(line));
const sheetNames = parsedSheets.map((item) => String(item.name || "").trim());

function chooseSheetName() {
  const requested = String(requestedSheetName || "").trim();
  if (requested) {
    if (!sheetNames.includes(requested)) {
      throw new Error(`未找到工作表“${requested}”。现有工作表: ${sheetNames.join(" | ")}`);
    }
    return requested;
  }
  return (
    sheetNames.find((name) => name === "生图任务表") ||
    sheetNames.find((name) => name === "主图提示词") ||
    sheetNames.find((name) => name.includes("提示词")) ||
    sheetNames[0]
  );
}

function getHeaders(sheetName) {
  const sheet = workbook.worksheets.getItem(sheetName);
  const values = sheet.getUsedRange(true).values || [];
  const headers = (values[0] || []).map((value) => String(value ?? "").trim());
  return { values, headers };
}

if (inspectOnly) {
  const sheets = sheetNames.map((name) => {
    const { values, headers } = getHeaders(name);
    return {
      name,
      headerRow: 1,
      rowCount: Math.max(0, values.length - 1),
      headers,
    };
  });
  const inspectPayload = { workbookPath: path.resolve(workbookPath), sheets };
  if (outputPath) {
    await fs.mkdir(path.dirname(path.resolve(outputPath)), { recursive: true });
    await fs.writeFile(outputPath, JSON.stringify(inspectPayload, null, 2), "utf8");
    console.log(
      JSON.stringify(
        {
          workbookPath: path.resolve(workbookPath),
          sheetCount: sheets.length,
          outputPath: path.resolve(outputPath),
        },
        null,
        2,
      ),
    );
  } else {
    console.log(JSON.stringify(inspectPayload, null, 2));
  }
  process.exit(0);
}

const sheetName = chooseSheetName();
const { values, headers } = getHeaders(sheetName);
if (!values || values.length < 2) {
  throw new Error(`${sheetName} 工作表没有可读取的数据行。`);
}

const promptIndex = resolveColumn(headers, readFlag("--prompt-column"), {
  required: true,
  label: "生图提示词列",
});
const idIndex = resolveColumn(headers, readFlag("--id-column"), { label: "编号列" });
const descriptionIndex = autoFind(headers, [/^说明$/, /任务说明/, /图片说明/]);
const refSelectors = splitList(readFlag("--reference-columns"));
const refIndices =
  refSelectors.length > 0
    ? refSelectors
        .map((selector) => resolveColumn(headers, selector, { label: "参考图列" }))
        .filter((index) => index >= 0)
    : [];

const imageTypeIndex =
  resolveColumn(headers, readFlag("--image-type-column"), { label: "图片类型列" }) >= 0
    ? resolveColumn(headers, readFlag("--image-type-column"), { label: "图片类型列" })
    : autoFind(headers, [/图片类型/, /任务类型/]);
const linkOrderIndex =
  resolveColumn(headers, readFlag("--link-order-column"), { label: "链接顺序列" }) >= 0
    ? resolveColumn(headers, readFlag("--link-order-column"), { label: "链接顺序列" })
    : autoFind(headers, [/产品链接顺序/, /链接顺序/]);
const roleIndex =
  resolveColumn(headers, readFlag("--role-column"), { label: "图片角色列" }) >= 0
    ? resolveColumn(headers, readFlag("--role-column"), { label: "图片角色列" })
    : autoFind(headers, [/图片角色/, /页面角色/]);
const sizeIndex =
  resolveColumn(headers, readFlag("--size-column"), { label: "尺寸列" }) >= 0
    ? resolveColumn(headers, readFlag("--size-column"), { label: "尺寸列" })
    : autoFind(headers, [/成图尺寸/, /输出尺寸/, /图片尺寸/]);
const outputNameIndex =
  resolveColumn(headers, readFlag("--output-name-column"), { label: "输出文件名列" }) >= 0
    ? resolveColumn(headers, readFlag("--output-name-column"), { label: "输出文件名列" })
    : autoFind(headers, [/输出文件名/, /文件名/]);
const executionModeIndex =
  resolveColumn(headers, readFlag("--execution-mode-column"), { label: "执行模式列" }) >= 0
    ? resolveColumn(headers, readFlag("--execution-mode-column"), { label: "执行模式列" })
    : autoFind(headers, [/执行模式/, /生成模式/]);

const workbookDir = path.dirname(path.resolve(workbookPath));
const rows = values
  .slice(1)
  .map((row, offset) => {
    const rowNumber = offset + 2;
    const prompt = String(row[promptIndex] ?? "").trim();
    const idHeader = idIndex >= 0 ? headers[idIndex] : "";
    const descriptionRaw =
      descriptionIndex >= 0
        ? row[descriptionIndex]
        : idIndex >= 0 && /说明/.test(idHeader)
          ? row[idIndex]
          : "";
    const parsedDescription = parseDescription(descriptionRaw);
    const rawImageNo = idIndex >= 0 ? String(row[idIndex] ?? "").trim() : "";
    const imageNo =
      idIndex >= 0
        ? /说明/.test(idHeader)
          ? parsedDescription.imageNo || rawImageNo
          : rawImageNo
        : parsedDescription.imageNo || `row${String(rowNumber).padStart(3, "0")}`;
    const referenceRawValues = refIndices.map((index) => row[index]);
    const references = normalizeReferences(referenceRawValues, workbookDir);
    return {
      rowNumber,
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
                : "图片"),
      linkOrder: linkOrderIndex >= 0 ? String(row[linkOrderIndex] ?? "").trim() : parsedDescription.linkOrder,
      role: roleIndex >= 0 ? String(row[roleIndex] ?? "").trim() : parsedDescription.role,
      outputSize: sizeIndex >= 0 ? String(row[sizeIndex] ?? "").trim() : parsedDescription.outputSize || parseSizeFromText(prompt),
      outputFileName:
        outputNameIndex >= 0 ? String(row[outputNameIndex] ?? "").trim() : parsedDescription.outputFileName,
      executionMode:
        executionModeIndex >= 0
          ? String(row[executionModeIndex] ?? "").trim() || "image_generation"
          : parsedDescription.executionMode || "image_generation",
      referenceRaw: referenceRawValues.map((value) => String(value ?? "").trim()).join("\n"),
      references,
      prompt,
    };
  })
  .filter((row) => row.imageNo || row.prompt || row.references.length > 0);

await fs.mkdir(path.dirname(path.resolve(outputPath)), { recursive: true });
await fs.writeFile(
  outputPath,
  JSON.stringify(
    {
      workbookPath: path.resolve(workbookPath),
      sheetName,
      headers,
      selectedColumns: {
        idColumn: idIndex >= 0 ? headers[idIndex] : null,
        referenceColumns: refIndices.map((index) => headers[index]),
        promptColumn: headers[promptIndex],
      },
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
      workbookPath: path.resolve(workbookPath),
      sheetName,
      selectedColumns: {
        idColumn: idIndex >= 0 ? headers[idIndex] : null,
        referenceColumns: refIndices.map((index) => headers[index]),
        promptColumn: headers[promptIndex],
      },
      rowCount: rows.length,
      outputPath: path.resolve(outputPath),
    },
    null,
    2,
  ),
);
