param(
  [Parameter(Mandatory = $true)][string]$HandoffPath,
  [Parameter(Mandatory = $true)][string]$Phase2Path,
  [string]$WorkbookPath,
  [string]$GenerationWorkbookPath,
  [string]$CompiledPath,
  [string]$QaDir,
  [string]$GenerationQaDir,
  [string]$PromptSheetName,
  [int]$StartRow,
  [int]$EndRow,
  [string]$OutputDir,
  [switch]$Execute,
  [string]$NodePath = "C:\Users\HK\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe",
  [string]$NodeModulesPath = "C:\Users\HK\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\node_modules",
  [string[]]$ReferenceAllowPatterns = @("恒品现有链接素材", "产品图", "SKU", "包装", "说明书", "资质", "注册证", "备案", "主图", "详情"),
  [string[]]$RejectReferencePatterns = @("竞品", "tmall.com", "阿里健康", "科巢", "scoornest", "London", "UK"),
  [string]$StyleCode,
  [switch]$SkipMainLongImages
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
if (-not (Test-Path -LiteralPath $HandoffPath)) { throw "Handoff not found: $HandoffPath" }
if (-not (Test-Path -LiteralPath $Phase2Path)) { throw "Phase 2 output not found: $Phase2Path" }
if (-not (Test-Path -LiteralPath $NodePath)) { throw "Bundled Node.js not found: $NodePath" }

$handoff = Get-Content -Raw -Encoding UTF8 $HandoffPath | ConvertFrom-Json
if (-not $StyleCode -and $handoff.product.product_id) { $StyleCode = [string]$handoff.product.product_id }
$baseDir = Split-Path -Parent (Resolve-Path -LiteralPath $Phase2Path)
if (-not $CompiledPath) { $CompiledPath = Join-Path $baseDir "phase2_compiled.json" }
if (-not $WorkbookPath) { $WorkbookPath = Join-Path $baseDir "$($handoff.product.product_id)_主图与详情页生图任务表.xlsx" }
if (-not $GenerationWorkbookPath) { $GenerationWorkbookPath = Join-Path $baseDir "$($handoff.product.product_id)_脚本生图交接表.xlsx" }
if (-not $QaDir) { $QaDir = Join-Path $baseDir "_workbook_qa" }
if (-not $GenerationQaDir) { $GenerationQaDir = Join-Path $baseDir "_generation_handoff_qa" }

$validator = Join-Path $scriptRoot "validate_phase2_output.mjs"
$compiler = Join-Path $scriptRoot "compile_phase2_output.mjs"
$workbookBuilder = Join-Path $scriptRoot "build_phase2_workbook.mjs"
$generationWorkbookBuilder = Join-Path $scriptRoot "build_generation_handoff_workbook.mjs"
$extractor = Join-Path $scriptRoot "extract_main_image_prompts.mjs"
$generator = Join-Path $scriptRoot "saima_generate_images.ps1"
$fixedComposer = Join-Path $scriptRoot "compose_fixed_assets.ps1"

& $NodePath $validator $HandoffPath $Phase2Path | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Phase 2 validation failed." }

& $NodePath $compiler $HandoffPath $Phase2Path $CompiledPath | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Phase 2 compilation failed." }

& $NodePath $workbookBuilder $HandoffPath $CompiledPath $WorkbookPath $QaDir | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Workbook build failed." }

& $NodePath $generationWorkbookBuilder $HandoffPath $CompiledPath $GenerationWorkbookPath $GenerationQaDir | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Generation handoff workbook build failed." }

$baseSummary = [ordered]@{
  mode = if ($Execute) { "execute" } else { "preview" }
  handoffPath = (Resolve-Path -LiteralPath $HandoffPath).Path
  phase2Path = (Resolve-Path -LiteralPath $Phase2Path).Path
  compiledPath = (Resolve-Path -LiteralPath $CompiledPath).Path
  workbookPath = (Resolve-Path -LiteralPath $WorkbookPath).Path
  generationWorkbookPath = (Resolve-Path -LiteralPath $GenerationWorkbookPath).Path
  qaDir = (Resolve-Path -LiteralPath $QaDir).Path
  generationQaDir = (Resolve-Path -LiteralPath $GenerationQaDir).Path
  generationSheetName = "生图任务表"
}

if (-not $PromptSheetName -and $StartRow -le 0 -and $EndRow -le 0) {
  $baseSummary.status = "workbook_built"
  $baseSummary.next = "Use generationWorkbookPath sheet 生图任务表. Provide -StartRow and -EndRow; run without -Execute for preview, then rerun with -Execute after confirmation."
  Write-Output ([PSCustomObject]$baseSummary | ConvertTo-Json -Depth 6)
  return
}

if (-not $PromptSheetName) { $PromptSheetName = "生图任务表" }
if ($StartRow -le 0 -or $EndRow -le 0) { throw "Both StartRow and EndRow are required." }
if ($StartRow -gt $EndRow) { throw "StartRow cannot be greater than EndRow." }

$promptWorkbookPath = if ($PromptSheetName -eq "生图任务表") { $GenerationWorkbookPath } else { $WorkbookPath }

$workDir = Join-Path $baseDir "_stage3_work"
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$rowsJson = Join-Path $workDir "selected_sheet_rows.json"
& $NodePath $extractor $promptWorkbookPath $rowsJson $PromptSheetName | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Workbook row extraction failed." }
$sheetData = Get-Content -Raw -Encoding UTF8 $rowsJson | ConvertFrom-Json
$selectedRows = @($sheetData.rows | Where-Object {
  [int]$_.rowNumber -ge $StartRow -and [int]$_.rowNumber -le $EndRow
})
if ($selectedRows.Count -eq 0) { throw "No tasks found in Excel rows $StartRow-$EndRow." }

$selectedCompiledTasks = @()
if ($PromptSheetName -eq "生图任务表") {
  $compiledData = Get-Content -Raw -Encoding UTF8 $CompiledPath | ConvertFrom-Json
  $linkOrders = @{}
  foreach ($link in @($handoff.links)) {
    $linkOrders[[string]$link.link_id] = [int]$link.order
  }
  $typeOrders = @{ main = 1; sku = 2; detail = 3 }
  $orderedCompiledTasks = @($compiledData.tasks | Sort-Object `
    @{ Expression = { if ($linkOrders.ContainsKey([string]$_.link_id)) { $linkOrders[[string]$_.link_id] } else { 999 } }; Ascending = $true },
    @{ Expression = { if ($typeOrders.ContainsKey([string]$_.type)) { $typeOrders[[string]$_.type] } else { 99 } }; Ascending = $true },
    @{ Expression = { [int]$_.sequence }; Ascending = $true },
    @{ Expression = { [string]$_.task_id }; Ascending = $true })
  $selectedCompiledTasks = @($selectedRows | ForEach-Object {
    $index = [int]$_.rowNumber - 2
    if ($index -ge 0 -and $index -lt $orderedCompiledTasks.Count) { $orderedCompiledTasks[$index] }
  })
}

$normalRows = @($selectedRows | Where-Object { [string]$_.executionMode -ne "fixed_asset_composite" })
$fixedRows = @($selectedRows | Where-Object { [string]$_.executionMode -eq "fixed_asset_composite" })
$preview = [ordered]@{}
foreach ($key in $baseSummary.Keys) { $preview[$key] = $baseSummary[$key] }
$preview.status = if ($Execute) { "executing" } else { "awaiting_confirmation" }
$preview.promptWorkbookPath = (Resolve-Path -LiteralPath $promptWorkbookPath).Path
$preview.promptSheetName = $PromptSheetName
$preview.startRow = $StartRow
$preview.endRow = $EndRow
$preview.selectedCount = $selectedRows.Count
$preview.imageGenerationCount = $normalRows.Count
$preview.fixedAssetCount = $fixedRows.Count
$preview.rows = @($selectedRows | Select-Object rowNumber, imageNo, imageType, role, outputSize, outputFileName, executionMode)

if (-not $Execute) {
  Write-Output ([PSCustomObject]$preview | ConvertTo-Json -Depth 8)
  return
}

if (-not $OutputDir) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $OutputDir = Join-Path $baseDir "stage3_generated_$stamp"
}
if ([string]$handoff.status -ne "confirmed") {
  throw "Formal execution requires phase1_handoff.json status=confirmed. Current status: $($handoff.status)"
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

if ($normalRows.Count -gt 0) {
  $generatorParams = @{
    WorkbookPath = $promptWorkbookPath
    PromptSheetName = $PromptSheetName
    StartRow = $StartRow
    EndRow = $EndRow
    OutputDir = (Join-Path $OutputDir "generated")
    NodePath = $NodePath
    NodeModulesPath = $NodeModulesPath
    ReferenceAllowPatterns = $ReferenceAllowPatterns
    RejectReferencePatterns = $RejectReferencePatterns
    SkipExecutionModes = @("fixed_asset_composite")
    StyleCode = $StyleCode
  }
  if ($SkipMainLongImages) { $generatorParams.SkipMainLongImages = $true }
  & $generator @generatorParams | Out-Host
}

if ($fixedRows.Count -gt 0) {
  $fixedIds = @()
  if ($selectedCompiledTasks.Count -gt 0) {
    $fixedIds = @($selectedCompiledTasks | Where-Object { [string]$_.execution_mode -eq "fixed_asset_composite" } | ForEach-Object { [string]$_.task_id })
  }
  if ($fixedIds.Count -eq 0) {
    $fixedIds = @($fixedRows | ForEach-Object { [string]$_.imageNo })
  }
  & $fixedComposer `
    -CompiledJson $CompiledPath `
    -OutputDir (Join-Path $OutputDir "fixed_assets") `
    -TaskIds $fixedIds `
    -StyleCode $StyleCode | Out-Host
}

$finalSummary = [ordered]@{}
foreach ($key in $preview.Keys) { $finalSummary[$key] = $preview[$key] }
$finalSummary.status = "completed"
$finalSummary.outputDir = (Resolve-Path -LiteralPath $OutputDir).Path
$summaryPath = Join-Path $OutputDir "stage3_automation_summary.json"
[PSCustomObject]$finalSummary | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $summaryPath
Write-Output ([PSCustomObject]$finalSummary | ConvertTo-Json -Depth 8)
