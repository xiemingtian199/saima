import fs from "node:fs/promises";
import path from "node:path";

let sharp = null;
try {
  sharp = (await import("sharp")).default;
} catch {
  sharp = null;
}

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

function sanitizeName(value) {
  const clean = String(value || "image")
    .replace(/[\\/:*?"<>|]/g, "_")
    .replace(/\s+/g, "");
  return (clean || "image").slice(0, 64);
}

function normalizeBaseUrl(value) {
  let clean = String(value || "https://yunwu.ai").trim().replace(/\/+$/, "");
  clean = clean.replace(/\/chat\/completions$/, "").replace(/\/images\/generations$/, "");
  if (!clean.endsWith("/v1")) clean += "/v1";
  return clean;
}

function parseTargetDimensions(row, targetSize) {
  const numbers = String(row.outputSize || "").match(/\d{3,5}/g)?.map(Number) || [];
  if (numbers.length >= 2) return { width: numbers[0], height: numbers[1] };
  return { width: targetSize, height: targetSize };
}

function apiSizeFor(width, height) {
  const ratio = width / height;
  if (Math.abs(ratio - 1) < 0.12) return "1024x1024";
  return ratio > 1 ? "1536x1024" : "1024x1536";
}

function kindFor(row) {
  const text = String(row.imageType || "");
  if (text.includes("详情")) return "detail";
  if (/SKU/i.test(text)) return "sku";
  if (text.includes("主图")) return "main";
  return "image";
}

function buildPrompt(row, dimensions, additionalPrompt) {
  return `${row.prompt || ""}

${additionalPrompt || ""}

Final output requirements: e-commerce ${row.imageType || "image"} image, target aspect ratio ${dimensions.width} x ${dimensions.height}. Natural background fills the full canvas edge to edge. Do not include external platform names, shop names, competitor names, QR codes, phone numbers, URLs, or any text beyond the specified visible copy.`;
}

async function callImageApi({ baseUrl, apiKey, model, prompt, size, timeoutSec }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutSec * 1000);
  try {
    const response = await fetch(`${baseUrl}/images/generations`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json; charset=utf-8",
      },
      body: JSON.stringify({ model, prompt, size, n: 1 }),
      signal: controller.signal,
    });
    const text = await response.text();
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${text.slice(0, 800)}`);
    }
    const json = JSON.parse(text);
    const item = json.data?.[0];
    if (item?.b64_json) return { buffer: Buffer.from(item.b64_json, "base64"), api: { mode: "images_generations", responseCreated: json.created, requestedApiSize: size } };
    if (item?.url) {
      const imageResponse = await fetch(item.url, { signal: controller.signal });
      if (!imageResponse.ok) throw new Error(`Image download HTTP ${imageResponse.status}`);
      return { buffer: Buffer.from(await imageResponse.arrayBuffer()), api: { mode: "images_generations", url: item.url, responseCreated: json.created, requestedApiSize: size } };
    }
    throw new Error("images/generations returned no b64_json or url.");
  } finally {
    clearTimeout(timer);
  }
}

async function saveContactSheet(finalDir, outputPath) {
  if (!sharp) return;
  const files = (await fs.readdir(finalDir, { withFileTypes: true }))
    .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith(".png"))
    .map((entry) => entry.name)
    .sort();
  if (files.length === 0) return;
  const thumbW = 240;
  const thumbH = 240;
  const labelH = 44;
  const gap = 16;
  const cols = Math.min(4, files.length);
  const rows = Math.ceil(files.length / cols);
  const canvasW = cols * thumbW + (cols + 1) * gap;
  const canvasH = rows * (thumbH + labelH) + (rows + 1) * gap;
  const composites = [];
  for (let i = 0; i < files.length; i++) {
    const col = i % cols;
    const row = Math.floor(i / cols);
    const left = gap + col * (thumbW + gap);
    const top = gap + row * (thumbH + labelH + gap);
    const input = await sharp(path.join(finalDir, files[i]))
      .resize(thumbW, thumbH, { fit: "cover" })
      .png()
      .toBuffer();
    composites.push({ input, left, top });
    const safeLabel = files[i].replace(/[<&>]/g, "_").slice(0, 32);
    const svg = Buffer.from(`<svg width="${thumbW}" height="${labelH}" xmlns="http://www.w3.org/2000/svg"><rect width="100%" height="100%" fill="#ffffff"/><text x="8" y="26" font-size="16" font-family="Arial" fill="#111">${safeLabel}</text></svg>`);
    composites.push({ input: svg, left, top: top + thumbH });
  }
  await sharp({
    create: { width: canvasW, height: canvasH, channels: 3, background: "#f3f4f6" },
  })
    .composite(composites)
    .png()
    .toFile(outputPath);
}

async function saveFinalImage(buffer, finalPath, dimensions) {
  if (!sharp) {
    await fs.writeFile(finalPath, buffer);
    return { resized: false, width: null, height: null };
  }
  await sharp(buffer)
    .resize(dimensions.width, dimensions.height, { fit: "cover", position: "center", background: "#ffffff" })
    .png()
    .toFile(finalPath);
  const meta = await sharp(finalPath).metadata();
  return { resized: true, width: meta.width, height: meta.height };
}

async function getImageMetadata(filePath) {
  if (!sharp) return { width: null, height: null };
  const meta = await sharp(filePath).metadata();
  return { width: meta.width, height: meta.height };
}

const tasksPath = readFlag("--tasks");
const outputDir = readFlag("--output-dir");
const baseUrl = normalizeBaseUrl(readFlag("--base-url", process.env.YUNWU_API_BASE_URL || "https://yunwu.ai"));
const model = readFlag("--model", process.env.YUNWU_IMAGE_MODEL || "gpt-image-2");
const apiKey = readFlag("--api-key", process.env.YUNWU_API_KEY || "");
const startRow = Number(readFlag("--start-row", "0"));
const endRow = Number(readFlag("--end-row", "0"));
const targetSize = Number(readFlag("--target-size", "1440"));
const timeoutSec = Number(readFlag("--timeout-sec", "300"));
const retries = Number(readFlag("--retries", "2"));
const additionalPrompt = readFlag("--additional-prompt", "");
const skipModes = new Set(String(readFlag("--skip-execution-modes", "fixed_asset_composite")).split(",").map((item) => item.trim()).filter(Boolean));
const continueOnError = hasFlag("--continue-on-error");

if (!tasksPath || !outputDir) {
  console.error("Usage: node generate_images_from_tasks_node.mjs --tasks <tasks.json> --output-dir <dir> [--start-row 2 --end-row 11]");
  process.exit(2);
}
if (!apiKey) {
  throw new Error("Missing API key. Set YUNWU_API_KEY or pass --api-key.");
}

const rawDir = path.join(outputDir, "raw");
const finalDir = path.join(outputDir, "final_images");
const metaDir = path.join(outputDir, "metadata");
await fs.mkdir(rawDir, { recursive: true });
await fs.mkdir(finalDir, { recursive: true });
await fs.mkdir(metaDir, { recursive: true });

const data = JSON.parse(await fs.readFile(tasksPath, "utf8"));
let rows = data.rows || [];
if (startRow > 0 && endRow > 0) {
  rows = rows.filter((row) => Number(row.rowNumber) >= startRow && Number(row.rowNumber) <= endRow);
}
rows = rows.filter((row) => !skipModes.has(String(row.executionMode || "")));

const results = [];
const failures = [];
let index = 0;
for (const row of rows) {
  index += 1;
  const dimensions = parseTargetDimensions(row, targetSize);
  const apiSize = apiSizeFor(dimensions.width, dimensions.height);
  const prompt = buildPrompt(row, dimensions, additionalPrompt);
  const safeName = sanitizeName(row.outputFileName || row.imageNo || `row${row.rowNumber}`);
  const linkTag = sanitizeName(row.linkOrder || "link");
  const kind = kindFor(row);
  const prefix = `${linkTag}_${kind}_row${String(row.rowNumber).padStart(3, "0")}_${safeName}`;
  const rawPath = path.join(rawDir, `${prefix}.raw.png`);
  const finalPath = path.join(finalDir, `${prefix}_${dimensions.width}x${dimensions.height}.png`);
  const metaPath = path.join(metaDir, `${prefix}.json`);

  console.log(`Generating ${index}/${rows.length}: Excel row ${row.rowNumber}, ${row.imageNo || safeName}, API size ${apiSize}, final ${dimensions.width}x${dimensions.height}`);
  let apiResult = null;
  let lastError = null;
  for (let attempt = 1; attempt <= retries + 1; attempt++) {
    try {
      apiResult = await callImageApi({ baseUrl, apiKey, model, prompt, size: apiSize, timeoutSec });
      break;
    } catch (error) {
      lastError = error;
      console.log(`Attempt ${attempt} failed for row ${row.rowNumber}: ${String(error.message || error).slice(0, 500)}`);
      if (attempt <= retries) await new Promise((resolve) => setTimeout(resolve, Math.min(15000, attempt * 5000)));
    }
  }
  if (!apiResult) {
    const failure = { rowNumber: row.rowNumber, imageNo: row.imageNo, error: String(lastError?.message || lastError) };
    failures.push(failure);
    await fs.writeFile(metaPath, JSON.stringify({ ...failure, failed: true, promptLength: prompt.length }, null, 2), "utf8");
    if (!continueOnError) throw new Error(`Failed row ${row.rowNumber}: ${failure.error}`);
    continue;
  }

  await fs.writeFile(rawPath, apiResult.buffer);
  const finalMeta = await saveFinalImage(apiResult.buffer, finalPath, dimensions);
  const rawMeta = await getImageMetadata(rawPath);
  const meta = {
    index,
    imageNo: row.imageNo,
    imageType: row.imageType,
    linkOrder: row.linkOrder,
    role: row.role,
    sourceRowNumber: row.rowNumber,
    rawPath,
    finalPath,
    rawSize: { width: rawMeta.width, height: rawMeta.height },
    finalSize: { width: finalMeta.width, height: finalMeta.height },
    api: apiResult.api,
    promptLength: prompt.length,
    referencesUsed: [],
    createdAt: new Date().toISOString(),
  };
  await fs.writeFile(metaPath, JSON.stringify(meta, null, 2), "utf8");
  results.push(meta);
}

const contactSheet = path.join(outputDir, "generated_images_contact_sheet.png");
await saveContactSheet(finalDir, contactSheet);

const summary = {
  workbookPath: data.workbookPath,
  sheetName: data.sheetName,
  outputDir,
  finalDir,
  contactSheet,
  baseUrl,
  model,
  count: results.length,
  failureCount: failures.length,
  failures,
  results,
  createdAt: new Date().toISOString(),
};
await fs.writeFile(path.join(outputDir, "run_summary.json"), JSON.stringify(summary, null, 2), "utf8");
console.log(JSON.stringify({ outputDir, finalDir, contactSheet, sheetName: data.sheetName, count: results.length, failureCount: failures.length }, null, 2));
