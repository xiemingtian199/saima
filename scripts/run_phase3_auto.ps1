param(
  [Parameter(Position = 0, Mandatory = $true)]
  [Alias("WorkbookPath")]
  [string]$Workbook,

  [string]$SearchRoot,
  [string[]]$SheetName,
  [int]$StartRow,
  [int]$EndRow,
  [string]$OutputDir,
  [switch]$PreviewOnly,
  [string]$ApiKey,
  [string]$BaseUrl,
  [string]$Model,
  [int]$TargetSize = 1440,
  [switch]$NoReferences,
  [switch]$AllowPromptOnlyFallback,
  [ValidateRange(0, 5)][int]$ReferenceRetryCount = 2,
  [ValidateRange(15, 600)][int]$ChatTimeoutSec = 90,
  [ValidateRange(15, 600)][int]$ImageTimeoutSec = 240,
  [ValidateRange(15, 600)][int]$DownloadTimeoutSec = 180,
  [string]$AdditionalPrompt,
  [string]$StyleCode,
  [switch]$SkipMainLongImages
)

$ErrorActionPreference = "Stop"

function Resolve-DefaultNodePath {
  $local = "C:\Users\HK\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
  if (Test-Path -LiteralPath $local) { return $local }
  return "node"
}

function Resolve-DefaultNodeModulesPath {
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

function Sanitize-Name {
  param([string]$Name)
  $clean = $Name -replace '[\\/:*?"<>|]', "_"
  $clean = $clean -replace "\s+", ""
  if (-not $clean) { return "sheet" }
  if ($clean.Length -gt 60) { $clean = $clean.Substring(0, 60) }
  return $clean
}

function Get-ConfiguredApiKey {
  param([string]$Explicit)
  if ($Explicit) { return $Explicit }
  $processValue = [Environment]::GetEnvironmentVariable("YUNWU_API_KEY", "Process")
  if ($processValue) { return $processValue }
  $userValue = [Environment]::GetEnvironmentVariable("YUNWU_API_KEY", "User")
  if ($userValue) { return $userValue }
  return $null
}

function Resolve-WorkbookPath {
  param([string]$InputPath, [string]$Root)

  $clean = $InputPath.Trim().Trim('"')
  if (Test-Path -LiteralPath $clean) {
    return (Resolve-Path -LiteralPath $clean).Path
  }

  $roots = New-Object System.Collections.ArrayList
  if ($Root) { [void]$roots.Add($Root) }
  [void]$roots.Add((Get-Location).Path)
  if (Test-Path -LiteralPath "E:\赛马计划") { [void]$roots.Add("E:\赛马计划") }
  if (Test-Path -LiteralPath "E:\电商产品赛马项目") { [void]$roots.Add("E:\电商产品赛马项目") }

  $fileName = [System.IO.Path]::GetFileName($clean)
  if (-not $fileName) { $fileName = $clean }
  $matches = @()
  foreach ($candidateRoot in @($roots | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })) {
    $matches += @(Get-ChildItem -LiteralPath $candidateRoot -Recurse -File -Filter $fileName -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -notlike "~$*" })
  }

  if ($matches.Count -eq 0 -and $fileName -notlike "*.xlsx") {
    foreach ($candidateRoot in @($roots | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })) {
      $matches += @(Get-ChildItem -LiteralPath $candidateRoot -Recurse -File -Filter "$fileName*.xlsx" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "~$*" })
    }
  }

  $best = @($matches | Sort-Object FullName -Unique | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
  if ($best) { return $best.FullName }

  throw "Workbook not found. Pass a full path or use -SearchRoot."
}

function Invoke-WorkbookInspect {
  param([string]$ResolvedWorkbookPath)
  $node = Resolve-DefaultNodePath
  Ensure-NodeModules -ModulesPath (Resolve-DefaultNodeModulesPath)
  $extractor = Join-Path $PSScriptRoot "extract_sheet_image_tasks.mjs"
  $inspectJson = Join-Path ([System.IO.Path]::GetTempPath()) ("saima_auto_inspect_{0}.json" -f ([guid]::NewGuid().ToString("N")))
  try {
    $null = & $node $extractor --workbook $ResolvedWorkbookPath --inspect --output $inspectJson
    if ($LASTEXITCODE -ne 0) { throw "Failed to inspect workbook." }
    return (Get-Content -LiteralPath $inspectJson -Raw -Encoding UTF8 | ConvertFrom-Json)
  } finally {
    if (Test-Path -LiteralPath $inspectJson) {
      Remove-Item -LiteralPath $inspectJson -Force
    }
  }
}

function Find-FirstHeader {
  param([object[]]$Headers, [string]$Pattern)
  $match = @($Headers | Where-Object { [string]$_ -match $Pattern } | Select-Object -First 1)
  if ($match) { return [string]$match }
  return ""
}

function Find-ReferenceHeaders {
  param([object[]]$Headers)
  return @($Headers | Where-Object {
    $text = [string]$_
    $text -match "\u53c2\u8003\u56fe|\u56fe\u7247\u8def\u5f84|\u56fe.*\u8def\u5f84" -and
      $text -notmatch "\u7528\u9014|\u7c7b\u578b|\u7f16\u53f7"
  } | ForEach-Object { [string]$_ })
}

function Get-AutoSheetTask {
  param($Sheet)
  $headers = @($Sheet.headers)
  $promptColumn = Find-FirstHeader -Headers $headers -Pattern "\u751f\u56fe\u63d0\u793a\u8bcd|\u63d0\u793a\u8bcd"
  if (-not $promptColumn) { return $null }

  $referenceColumns = Find-ReferenceHeaders -Headers $headers
  if (-not $NoReferences -and $referenceColumns.Count -eq 0) { return $null }

  $idColumn = Find-FirstHeader -Headers $headers -Pattern "^\u8bf4\u660e$|\u7f16\u53f7|ID|\u5e8f\u53f7"
  $firstRow = 2
  $lastRow = [int]$Sheet.rowCount + 1
  if ($lastRow -lt $firstRow) { return $null }

  $start = if ($StartRow -gt 0) { $StartRow } else { $firstRow }
  $end = if ($EndRow -gt 0) { $EndRow } else { $lastRow }
  if ($start -gt $end) { throw "StartRow cannot be greater than EndRow." }

  return [PSCustomObject]@{
    SheetName = [string]$Sheet.name
    IdColumn = $idColumn
    ReferenceColumns = $referenceColumns
    PromptColumn = $promptColumn
    StartRow = $start
    EndRow = $end
    DataRows = [int]$Sheet.rowCount
  }
}

function Select-AutoTasks {
  param($Inspection)
  $tasks = New-Object System.Collections.ArrayList
  $candidateSheets = @($Inspection.sheets)
  if (-not $SheetName -or $SheetName.Count -eq 0) {
    $simpleSheets = @($candidateSheets | Where-Object { [string]$_.name -eq "\u751f\u56fe\u4efb\u52a1\u8868" })
    if ($simpleSheets.Count -gt 0) { $candidateSheets = $simpleSheets }
  }
  foreach ($sheet in $candidateSheets) {
    if ($SheetName -and $SheetName.Count -gt 0) {
      $matched = @($SheetName | Where-Object { $sheet.name -eq $_ -or $sheet.name -like $_ })
      if ($matched.Count -eq 0) { continue }
    }
    $task = Get-AutoSheetTask -Sheet $sheet
    if ($task) { [void]$tasks.Add($task) }
  }
  return @($tasks)
}

$resolvedWorkbook = Resolve-WorkbookPath -InputPath $Workbook -Root $SearchRoot
Write-Output "Workbook: $resolvedWorkbook"

if (-not $PreviewOnly) {
  $resolvedKey = Get-ConfiguredApiKey -Explicit $ApiKey
  if (-not $resolvedKey) {
    throw "Missing API key. Configure YUNWU_API_KEY or pass -ApiKey."
  }
}

$inspection = Invoke-WorkbookInspect -ResolvedWorkbookPath $resolvedWorkbook
$tasks = Select-AutoTasks -Inspection $inspection
if ($tasks.Count -eq 0) {
  throw "No runnable prompt sheets found. Expected headers like prompt column and reference image column."
}

if (-not $OutputDir) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $OutputDir = Join-Path (Split-Path -Parent $resolvedWorkbook) "generated_images_auto_$stamp"
}

Write-Output "Auto-detected sheets:"
foreach ($task in $tasks) {
  Write-Output ("- {0}: rows {1}-{2}, prompt [{3}], refs [{4}]" -f $task.SheetName, $task.StartRow, $task.EndRow, $task.PromptColumn, (@($task.ReferenceColumns) -join ", "))
}
Write-Output "Output root: $OutputDir"
if ($PreviewOnly) {
  Write-Output "PreviewOnly: API will not be called."
} else {
  Write-Output "Auto execution: API will be called for detected image_generation rows."
}

$runner = Join-Path $PSScriptRoot "generate_images_from_sheet.ps1"
$results = New-Object System.Collections.ArrayList

foreach ($task in $tasks) {
  $sheetOut = Join-Path $OutputDir (Sanitize-Name -Name $task.SheetName)
  $params = @{
    WorkbookPath = $resolvedWorkbook
    SheetName = $task.SheetName
    PromptColumn = $task.PromptColumn
    StartRow = $task.StartRow
    EndRow = $task.EndRow
    OutputDir = $sheetOut
    TargetSize = $TargetSize
    ReferenceRetryCount = $ReferenceRetryCount
    ChatTimeoutSec = $ChatTimeoutSec
    ImageTimeoutSec = $ImageTimeoutSec
    DownloadTimeoutSec = $DownloadTimeoutSec
  }
  if ($task.IdColumn) { $params.IdColumn = $task.IdColumn }
  if (@($task.ReferenceColumns).Count -gt 0) { $params.ReferenceImageColumns = @($task.ReferenceColumns) }
  if ($ApiKey) { $params.ApiKey = $ApiKey }
  if ($BaseUrl) { $params.BaseUrl = $BaseUrl }
  if ($Model) { $params.Model = $Model }
  if ($NoReferences) { $params.NoReferences = $true }
  if ($AllowPromptOnlyFallback) { $params.AllowPromptOnlyFallback = $true }
  if ($AdditionalPrompt) { $params.AdditionalPrompt = $AdditionalPrompt }
  if ($StyleCode) { $params.StyleCode = $StyleCode }
  if ($SkipMainLongImages) { $params.SkipMainLongImages = $true }
  if (-not $PreviewOnly) { $params.Execute = $true }

  Write-Output ("Running sheet: {0}" -f $task.SheetName)
  & $runner @params
  if ($LASTEXITCODE -ne 0) { throw "Sheet failed: $($task.SheetName)" }

  [void]$results.Add([PSCustomObject]@{
    sheetName = $task.SheetName
    outputDir = $sheetOut
    startRow = $task.StartRow
    endRow = $task.EndRow
  })
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$summaryPath = Join-Path $OutputDir "auto_run_summary.json"
[PSCustomObject]@{
  workbookPath = $resolvedWorkbook
  outputRoot = (Resolve-Path -LiteralPath $OutputDir).Path
  previewOnly = [bool]$PreviewOnly
  sheetCount = $results.Count
  sheets = $results
  createdAt = (Get-Date).ToString("s")
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Output "Auto stage3 finished."
Write-Output "Summary: $summaryPath"
