param(
  [Parameter(Mandatory = $true)][string]$WorkbookPath,
  [string]$SheetName,
  [string]$IdColumn,
  [string[]]$ReferenceImageColumns,
  [Parameter(Mandatory = $false)][string]$PromptColumn,
  [string]$ImageTypeColumn,
  [string]$LinkOrderColumn,
  [string]$RoleColumn,
  [string]$SizeColumn,
  [string]$OutputNameColumn,
  [string]$ExecutionModeColumn,
  [int]$StartRow,
  [int]$EndRow,
  [string]$OutputDir,
  [switch]$Execute,
  [switch]$InspectOnly,
  [string]$ApiKey,
  [string]$BaseUrl,
  [string]$Model,
  [int]$TargetSize = 1440,
  [string]$NodePath,
  [string]$NodeModulesPath,
  [switch]$NoReferences,
  [switch]$AllowPromptOnlyFallback,
  [ValidateRange(0, 5)][int]$ReferenceRetryCount = 2,
  [ValidateRange(15, 600)][int]$ChatTimeoutSec = 90,
  [ValidateRange(15, 600)][int]$ImageTimeoutSec = 240,
  [ValidateRange(15, 600)][int]$DownloadTimeoutSec = 180,
  [string]$AdditionalPrompt,
  [string]$StyleCode,
  [string[]]$ReferenceAllowPatterns,
  [string[]]$RejectReferencePatterns,
  [string[]]$SkipExecutionModes = @("fixed_asset_composite"),
  [switch]$SkipMainLongImages
)

$ErrorActionPreference = "Stop"

function Resolve-DefaultNodePath {
  if ($NodePath -and (Test-Path -LiteralPath $NodePath)) { return $NodePath }
  $local = "C:\Users\HK\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
  if (Test-Path -LiteralPath $local) { return $local }
  return "node"
}

function Resolve-DefaultNodeModulesPath {
  if ($NodeModulesPath -and (Test-Path -LiteralPath $NodeModulesPath)) { return $NodeModulesPath }
  $local = "C:\Users\HK\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\node_modules"
  if (Test-Path -LiteralPath $local) { return $local }
  return $null
}

function Ensure-NodeModules {
  param([string]$ModulesPath)
  if (-not $ModulesPath) { return }
  $link = Join-Path $PSScriptRoot "node_modules"
  if (Test-Path -LiteralPath $link) { return }
  New-Item -ItemType Junction -Path $link -Target $ModulesPath | Out-Null
}

function Split-ColumnInput {
  param([string]$Value)
  if (-not $Value) { return @() }
  return @($Value -split "[,，|]" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Show-WorkbookInspection {
  param($Inspection)
  Write-Output "工作表与表头："
  foreach ($sheet in @($Inspection.sheets)) {
    Write-Output "[$($sheet.name)] 数据行: $($sheet.rowCount)"
    Write-Output ("  " + (@($sheet.headers) -join " | "))
  }
}

function Get-SheetInspection {
  param($Inspection, [string]$Name)
  $sheet = @($Inspection.sheets | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
  if (-not $sheet) {
    throw "未找到工作表 '$Name'。请先用 -InspectOnly 查看可用工作表。"
  }
  return $sheet
}

function Choose-DefaultSheetName {
  param($Inspection)
  $names = @($Inspection.sheets | ForEach-Object { [string]$_.name })
  $candidate = @($names | Where-Object { $_ -eq "生图任务表" } | Select-Object -First 1)
  if ($candidate) { return $candidate }
  $candidate = @($names | Where-Object { $_ -eq "主图提示词" } | Select-Object -First 1)
  if ($candidate) { return $candidate }
  $candidate = @($names | Where-Object { $_ -like "*提示词*" } | Select-Object -First 1)
  if ($candidate) { return $candidate }
  if ($names.Count -gt 0) { return $names[0] }
  throw "工作簿没有可用工作表。"
}

function Read-RequiredText {
  param([string]$Value, [string]$Prompt)
  if ($Value) { return $Value }
  $answer = Read-Host $Prompt
  if (-not $answer) { throw "缺少必填输入：$Prompt" }
  return $answer.Trim()
}

function Read-OptionalText {
  param([string]$Value, [string]$Prompt)
  if ($Value) { return $Value }
  $answer = Read-Host $Prompt
  if (-not $answer) { return "" }
  return $answer.Trim()
}

function Read-RequiredInt {
  param([int]$Value, [string]$Prompt)
  if ($Value -gt 0) { return $Value }
  $answer = Read-Host $Prompt
  if (-not ($answer -match "^\d+$")) { throw "请输入正整数：$Prompt" }
  return [int]$answer
}

$workbookResolved = (Resolve-Path -LiteralPath $WorkbookPath).Path
$node = Resolve-DefaultNodePath
$modules = Resolve-DefaultNodeModulesPath
Ensure-NodeModules -ModulesPath $modules

$extractor = Join-Path $PSScriptRoot "extract_sheet_image_tasks.mjs"
$inspectionPath = Join-Path ([System.IO.Path]::GetTempPath()) ("saima_inspect_{0}.json" -f ([guid]::NewGuid().ToString("N")))
try {
  $null = & $node $extractor --workbook $workbookResolved --inspect --output $inspectionPath
  if ($LASTEXITCODE -ne 0) { throw "读取 Excel 表头失败。" }
  $inspection = Get-Content -LiteralPath $inspectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
} finally {
  if (Test-Path -LiteralPath $inspectionPath) {
    Remove-Item -LiteralPath $inspectionPath -Force
  }
}

if ($InspectOnly) {
  Show-WorkbookInspection -Inspection $inspection
  return
}

if (-not $SheetName) {
  $defaultSheet = Choose-DefaultSheetName -Inspection $inspection
  Show-WorkbookInspection -Inspection $inspection
  $answer = Read-Host "请输入工作表名，直接回车使用 [$defaultSheet]"
  $SheetName = if ($answer) { $answer.Trim() } else { $defaultSheet }
}

$sheetInfo = Get-SheetInspection -Inspection $inspection -Name $SheetName
Write-Output "当前工作表 [$SheetName] 表头："
Write-Output ("  " + (@($sheetInfo.headers) -join " | "))

$isSimpleHandoffSheet = $SheetName -eq "生图任务表" -and
  (@($sheetInfo.headers) -contains "说明") -and
  (@($sheetInfo.headers) -contains "参考图的位置") -and
  (@($sheetInfo.headers) -contains "生成提示词")

if (-not $PromptColumn -and $isSimpleHandoffSheet) { $PromptColumn = "生成提示词" }
$PromptColumn = Read-RequiredText -Value $PromptColumn -Prompt "请输入生图提示词列名/列字母/列序号"

if ($null -eq $ReferenceImageColumns) {
  if ($isSimpleHandoffSheet) {
    $ReferenceImageColumns = @("参考图的位置")
  } else {
    $refAnswer = Read-OptionalText -Value "" -Prompt "请输入参考图列名/列字母/列序号，多个用逗号分隔；无参考图直接回车"
    $ReferenceImageColumns = Split-ColumnInput -Value $refAnswer
  }
}

if (-not $IdColumn -and $isSimpleHandoffSheet) { $IdColumn = "说明" }
if (-not $IdColumn) {
  $IdColumn = Read-OptionalText -Value "" -Prompt "请输入编号列名/列字母/列序号；无编号列直接回车，脚本会使用行号"
}

$StartRow = Read-RequiredInt -Value $StartRow -Prompt "请输入起始 Excel 行号"
$EndRow = Read-RequiredInt -Value $EndRow -Prompt "请输入结束 Excel 行号"
if ($StartRow -gt $EndRow) {
  throw "起始行不能大于结束行。"
}

if (-not $OutputDir) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $OutputDir = Join-Path (Split-Path -Parent $workbookResolved) "generated_images_$stamp"
}

$workDir = Join-Path $OutputDir "_working"
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$tasksJson = Join-Path $workDir "sheet_image_tasks.json"

$extractArgs = @(
  "--workbook", $workbookResolved,
  "--output", $tasksJson,
  "--sheet", $SheetName,
  "--prompt-column", $PromptColumn
)
if ($IdColumn) { $extractArgs += @("--id-column", $IdColumn) }
if ($ReferenceImageColumns -and $ReferenceImageColumns.Count -gt 0) {
  $extractArgs += @("--reference-columns", (@($ReferenceImageColumns) -join ","))
}
if ($ImageTypeColumn) { $extractArgs += @("--image-type-column", $ImageTypeColumn) }
if ($LinkOrderColumn) { $extractArgs += @("--link-order-column", $LinkOrderColumn) }
if ($RoleColumn) { $extractArgs += @("--role-column", $RoleColumn) }
if ($SizeColumn) { $extractArgs += @("--size-column", $SizeColumn) }
if ($OutputNameColumn) { $extractArgs += @("--output-name-column", $OutputNameColumn) }
if ($ExecutionModeColumn) { $extractArgs += @("--execution-mode-column", $ExecutionModeColumn) }

& $node $extractor @extractArgs | Out-Host
if ($LASTEXITCODE -ne 0) { throw "抽取 Excel 生图任务失败。" }

$generator = Join-Path $PSScriptRoot "saima_generate_images.ps1"
$generateParams = @{
  WorkbookPath = $workbookResolved
  PromptsJsonPath = $tasksJson
  OutputDir = $OutputDir
  StartRow = $StartRow
  EndRow = $EndRow
  TargetSize = $TargetSize
  ReferenceRetryCount = $ReferenceRetryCount
  ChatTimeoutSec = $ChatTimeoutSec
  ImageTimeoutSec = $ImageTimeoutSec
  DownloadTimeoutSec = $DownloadTimeoutSec
  SkipExecutionModes = $SkipExecutionModes
}
if ($SkipMainLongImages) { $generateParams.SkipMainLongImages = $true }
if (-not $Execute) { $generateParams.PreviewOnly = $true }
if ($ApiKey) { $generateParams.ApiKey = $ApiKey }
if ($BaseUrl) { $generateParams.BaseUrl = $BaseUrl }
if ($Model) { $generateParams.Model = $Model }
if ($NodePath) { $generateParams.NodePath = $NodePath }
if ($NodeModulesPath) { $generateParams.NodeModulesPath = $NodeModulesPath }
if ($NoReferences) { $generateParams.NoReferences = $true }
if ($AllowPromptOnlyFallback) { $generateParams.AllowPromptOnlyFallback = $true }
if ($AdditionalPrompt) { $generateParams.AdditionalPrompt = $AdditionalPrompt }
if ($StyleCode) { $generateParams.StyleCode = $StyleCode }
if ($ReferenceAllowPatterns) { $generateParams.ReferenceAllowPatterns = $ReferenceAllowPatterns }
if ($RejectReferencePatterns) { $generateParams.RejectReferencePatterns = $RejectReferencePatterns }

if (-not $Execute) {
  Write-Output "当前为预览模式：不会调用 API。确认无误后追加 -Execute 正式生图。"
}

& $generator @generateParams
