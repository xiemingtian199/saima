import fs from "node:fs";
import path from "node:path";

const input = process.argv[2];
if (!input) {
  console.error("Usage: node validate_handoff.mjs <phase1_handoff.json>");
  process.exit(2);
}

const errors = [];
const warnings = [];
let data;
try {
  data = JSON.parse(fs.readFileSync(input, "utf8").replace(/^\uFEFF/, ""));
} catch (error) {
  console.error(`Cannot read JSON: ${error.message}`);
  process.exit(2);
}

const requiredTop = [
  "schema_version",
  "status",
  "product_root",
  "strategy_markdown",
  "product",
  "claims",
  "compliance",
  "visual_system",
  "assets",
  "links",
  "tasks",
  "stage2_contract",
];
for (const key of requiredTop) {
  if (data[key] === undefined || data[key] === null) errors.push(`missing top-level field: ${key}`);
}

if (data.schema_version !== "1.0") errors.push(`schema_version must be 1.0`);
if (!["draft", "confirmed"].includes(data.status)) errors.push(`status must be draft or confirmed`);
if (!Array.isArray(data.assets) || data.assets.length === 0) errors.push(`assets must be a non-empty array`);
if (!Array.isArray(data.links) || data.links.length === 0) errors.push(`links must be a non-empty array`);
if (!Array.isArray(data.tasks) || data.tasks.length === 0) errors.push(`tasks must be a non-empty array`);
if (!Array.isArray(data.claims) || data.claims.length === 0) errors.push(`claims must be a non-empty array`);

const unique = (items, field, label) => {
  const seen = new Set();
  for (const item of items || []) {
    const value = item?.[field];
    if (!value) errors.push(`${label} missing ${field}`);
    else if (seen.has(value)) errors.push(`duplicate ${label} ${field}: ${value}`);
    else seen.add(value);
  }
  return seen;
};

const assetIds = unique(data.assets, "asset_id", "asset");
const assetsById = new Map((data.assets || []).map((asset) => [asset.asset_id, asset]));
const linkIds = unique(data.links, "link_id", "link");
const claimIds = unique(data.claims, "claim_id", "claim");
unique(data.tasks, "task_id", "task");

for (const asset of data.assets || []) {
  if (!asset.absolute_path) errors.push(`asset ${asset.asset_id || "?"} missing absolute_path`);
  if (!asset.summary) errors.push(`asset ${asset.asset_id || "?"} missing summary`);
  if (asset.owner === "competitor" && asset.upload_to_image_api !== false) {
    errors.push(`competitor asset ${asset.asset_id} must set upload_to_image_api=false`);
  }
  if (asset.owner === "self" && asset.absolute_path && !fs.existsSync(asset.absolute_path)) {
    errors.push(`self asset path not found: ${asset.asset_id} -> ${asset.absolute_path}`);
  }
  if (asset.owner !== "self" && asset.absolute_path && !fs.existsSync(asset.absolute_path)) {
    warnings.push(`reference path not found: ${asset.asset_id} -> ${asset.absolute_path}`);
  }
}

for (const claim of data.claims || []) {
  for (const id of claim.evidence_asset_ids || []) {
    if (!assetIds.has(id)) errors.push(`claim ${claim.claim_id} references missing asset ${id}`);
  }
}

const orders = new Set();
const visualDirections = new Map();
const normalizeVisualDirection = (value) => String(value || "").replace(/[\s:：/｜|,，。；;、\-]/g, "").toLowerCase();
for (const link of data.links || []) {
  if (!Number.isInteger(link.order) || link.order < 1) errors.push(`link ${link.link_id} has invalid order`);
  if (orders.has(link.order)) errors.push(`duplicate link order: ${link.order}`);
  orders.add(link.order);
  const visualDirection = String(link.visual_direction || "").trim();
  if (!visualDirection) {
    errors.push(`link ${link.link_id} missing visual_direction`);
  } else {
    const normalizedVisualDirection = normalizeVisualDirection(visualDirection);
    if (visualDirections.has(normalizedVisualDirection)) {
      errors.push(
        `link ${link.link_id} visual_direction duplicates link ${visualDirections.get(normalizedVisualDirection)}; links need distinct scene/color/style direction`,
      );
    } else {
      visualDirections.set(normalizedVisualDirection, link.link_id);
    }
  }
  for (const id of [...(link.core_claim_ids || []), ...(link.supporting_claim_ids || [])]) {
    if (!claimIds.has(id)) errors.push(`link ${link.link_id} references missing claim ${id}`);
  }
}

for (const task of data.tasks || []) {
  if (!linkIds.has(task.link_id)) errors.push(`task ${task.task_id} references missing link ${task.link_id}`);
  if (!["main", "detail", "sku"].includes(task.type)) errors.push(`task ${task.task_id} has invalid type`);
  if (!Number.isInteger(task.sequence) || task.sequence < 1) errors.push(`task ${task.task_id} has invalid sequence`);
  if (!task.role || !task.objective || !task.visual_brief || !task.dimensions || !task.output_filename) {
    errors.push(`task ${task.task_id} is missing role/objective/visual_brief/dimensions/output_filename`);
  }
  for (const id of task.reference_asset_ids || []) {
    if (!assetIds.has(id)) errors.push(`task ${task.task_id} references missing asset ${id}`);
  }
  for (const id of task.required_claim_ids || []) {
    if (!claimIds.has(id)) errors.push(`task ${task.task_id} references missing claim ${id}`);
  }
  for (const binding of task.reference_bindings || []) {
    if (!assetIds.has(binding.asset_id)) errors.push(`task ${task.task_id} binding references missing asset ${binding.asset_id}`);
    const asset = assetsById.get(binding.asset_id);
    if (binding.include_in_api === true && asset?.upload_to_image_api === false) {
      errors.push(`task ${task.task_id} cannot upload asset ${binding.asset_id} to image API`);
    }
  }
  if (!task.copy_brief?.headline_goal || !task.copy_brief?.subtitle_goal || !task.copy_brief?.footer_goal) {
    errors.push(`task ${task.task_id} has incomplete copy_brief`);
  }
  if (task.risk_level === "fixed_asset") {
    const fixedBindings = (task.reference_bindings || []).filter(
      (binding) => assetsById.get(binding.asset_id)?.reference_type === "fixed_asset",
    );
    if (fixedBindings.length === 0) errors.push(`fixed_asset task ${task.task_id} has no fixed_asset reference`);
    if (fixedBindings.some((binding) => binding.include_in_api !== true)) {
      warnings.push(`fixed_asset task ${task.task_id} should upload the certificate/reference asset and constrain it in the prompt`);
    }
  }
}

if (data.product?.medical_device === true) {
  const fixed = (data.tasks || []).filter((task) => task.risk_level === "fixed_asset");
  if (fixed.length === 0) warnings.push(`medical-device handoff has no fixed_asset/certificate-frame task; confirm whether certificate display is intentionally omitted`);
}

if (data.status === "draft") warnings.push(`handoff status is draft; user confirmation is required before formal phase 2 delivery`);
if (data.strategy_markdown && !fs.existsSync(data.strategy_markdown)) warnings.push(`strategy_markdown path not found: ${data.strategy_markdown}`);

const report = {
  file: path.resolve(input),
  valid: errors.length === 0,
  counts: {
    assets: data.assets?.length || 0,
    claims: data.claims?.length || 0,
    links: data.links?.length || 0,
    tasks: data.tasks?.length || 0,
  },
  errors,
  warnings,
};
console.log(JSON.stringify(report, null, 2));
process.exit(errors.length === 0 ? 0 : 1);
