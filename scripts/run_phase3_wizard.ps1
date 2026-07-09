param(
  [string]$WorkbookPath,
  [string]$SearchRoot,
  [string]$SheetName,
  [string]$IdColumn,
  [string[]]$ReferenceImageColumns,
  [string]$PromptColumn,
  [int]$StartRow,
  [int]$EndRow,
  [string]$OutputDir,
  [switch]$Execute,
  [switch]$PreviewOnly,
  [string]$ApiKey,
  [string]$BaseUrl,
  [string]$Model,
  [int]$TargetSize = 1440,
  [switch]$NoReferences,
  [switch]$AllowPromptOnlyFallback,
  [ValidateRange(0, 5)][int]$ReferenceRetryCount = 2,
  [string]$AdditionalPrompt
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

function Convert-ToColumnLetter {
  param([int]$Index)
  $n = $Index + 1
  $letters = ""
  while ($n -gt 0) {
    $mod = ($n - 1) % 26
    $letters = [char](65 + $mod) + $letters
    $n = [math]::Floor(($n - 1) / 26)
  }
  return $letters
}

function Read-WithDefault {
  param([string]$Prompt, [string]$Default = "")
  if ($Default) {
    $answer = Read-Host "$Prompt; press Enter for [$Default]"
    if (-not $answer) { return $Default }
    return $answer.Trim()
  }
  $answer = Read-Host $Prompt
  if (-not $answer) { return "" }
  return $answer.Trim()
}

function Split-Selectors {
  param([string]$Value)
  if (-not $Value) { return @() }
  return @($Value -split "[,|]" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Select-Workbook {
  param([string]$ExplicitPath, [string]$Root)

  if ($ExplicitPath) {
    if (-not (Test-Path -LiteralPath $ExplicitPath)) { throw "Workbook not found: $ExplicitPath" }
    return (Resolve-Path -LiteralPath $ExplicitPath).Path
  }

  $roots = New-Object System.Collections.ArrayList
  if ($Root) { [void]$roots.Add($Root) }
  [void]$roots.Add((Get-Location).Path)
  if (Test-Path -LiteralPath "E:\赛马计划") { [void]$roots.Add("E:\赛马计划") }
  if (Test-Path -LiteralPath "E:\电商产品赛马项目") { [void]$roots.Add("E:\电商产品赛马项目") }

  $uniqueRoots = @($roots | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })
  $workbooks = @()
  foreach ($candidateRoot in $uniqueRoots) {
    $found = @(Get-ChildItem -LiteralPath $candidateRoot -Recurse -File -Filter "*.xlsx" -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -notlike "~$*" } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 20)
    $workbooks += $found
  }
  $workbooks = @($workbooks | Sort-Object FullName -Unique | Sort-Object LastWriteTime -Descending | Select-Object -First 30)

  if ($workbooks.Count -gt 0) {
    Write-Output "Recent Excel files:"
    for ($i = 0; $i -lt $workbooks.Count; $i++) {
      $item = $workbooks[$i]
      Write-Output ("[{0}] {1}  {2}" -f ($i + 1), $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm"), $item.FullName)
    }
    $answer = Read-Host "Enter workbook number, or paste full workbook path; press Enter for [1]"
    if (-not $answer) {
      return $workbooks[0].FullName
    }
    $answer = $answer.Trim().Trim('"')
    if ($answer -match "^\d+$") {
      $index = [int]$answer - 1
      if ($index -ge 0 -and $index -lt $workbooks.Count) {
        return $workbooks[$index].FullName
      }
      throw "Workbook number is out of range."
    }
    if ($answer -and (Test-Path -LiteralPath $answer)) {
      return (Resolve-Path -LiteralPath $answer).Path
    }
  }

  $manual = Read-Host "Paste full workbook path"
  if (-not $manual -or -not (Test-Path -LiteralPath $manual)) {
    throw "No valid workbook selected."
  }
  return (Resolve-Path -LiteralPath $manual).Path
}

function Invoke-WorkbookInspect {
  param([string]$ResolvedWorkbookPath)
  $node = Resolve-DefaultNodePath
  Ensure-NodeModules -ModulesPath (Resolve-DefaultNodeModulesPath)
  $extractor = Join-Path $PSScriptRoot "extract_sheet_image_tasks.mjs"
  $inspectJson = Join-Path ([System.IO.Path]::GetTempPath()) ("saima_inspect_{0}.json" -f ([guid]::NewGuid().ToString("N")))
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

function Select-Sheet {
  param($Inspection, [string]$ExplicitSheetName)
  $sheets = @($Inspection.sheets)
  if ($sheets.Count -eq 0) { throw "No worksheets found." }

  if ($ExplicitSheetName) {
    $match = @($sheets | Where-Object { $_.name -eq $ExplicitSheetName } | Select-Object -First 1)
    if (-not $match) { throw "Worksheet not found: $ExplicitSheetName" }
    return [string]$match.name
  }

  Write-Output "Worksheets:"
  for ($i = 0; $i -lt $sheets.Count; $i++) {
    Write-Output ("[{0}] {1}  rows: {2}" -f ($i + 1), $sheets[$i].name, $sheets[$i].rowCount)
  }
  $default = @($sheets | Where-Object { [string]$_.name -match "^\u4e3b\u56fe\u63d0\u793a\u8bcd$" } | Select-Object -First 1)
  if (-not $default) { $default = @($sheets | Where-Object { [string]$_.name -match "\u63d0\u793a\u8bcd" } | Select-Object -First 1) }
  if (-not $default) { $default = $sheets[0] }

  $answer = Read-WithDefault -Prompt "Enter worksheet number or name" -Default ([string]$default.name)
  if ($answer -match "^\d+$") {
    $index = [int]$answer - 1
    if ($index -ge 0 -and $index -lt $sheets.Count) { return [string]$sheets[$index].name }
    throw "Worksheet number is out of range."
  }
  $match = @($sheets | Where-Object { $_.name -eq $answer } | Select-Object -First 1)
  if (-not $match) { throw "Worksheet not found: $answer" }
  return [string]$match.name
}

function Show-Headers {
  param($Sheet)
  Write-Output "Headers:"
  $headers = @($Sheet.headers)
  for ($i = 0; $i -lt $headers.Count; $i++) {
    Write-Output ("[{0}] {1} / {2}" -f ($i + 1), (Convert-ToColumnLetter -Index $i), $headers[$i])
  }
}

function Find-HeaderDefault {
  param([object[]]$Headers, [string]$Pattern)
  $match = @($Headers | Where-Object { [string]$_ -match $Pattern } | Select-Object -First 1)
  if ($match) { return [string]$match }
  return ""
}

function Resolve-HeaderChoice {
  param([object[]]$Headers, [string]$Choice, [string]$Label, [switch]$Required)
  $raw = [string]$Choice
  if (-not $raw) {
    if ($Required) { throw "Missing $Label." }
    return ""
  }
  if ($raw -match "^\d+$") {
    $index = [int]$raw - 1
    if ($index -ge 0 -and $index -lt $Headers.Count) { return [string]$Headers[$index] }
  }
  $upper = $raw.ToUpperInvariant()
  if ($upper -match "^[A-Z]+$") {
    $index = 0
    foreach ($ch in $upper.ToCharArray()) {
      $index = $index * 26 + ([int][char]$ch - 64)
    }
    $index--
    if ($index -ge 0 -and $index -lt $Headers.Count) { return [string]$Headers[$index] }
  }
  $match = @($Headers | Where-Object { $_ -eq $raw } | Select-Object -First 1)
  if ($match) { return [string]$match }
  $match = @($Headers | Where-Object { [string]$_ -like "*$raw*" } | Select-Object -First 1)
  if ($match) { return [string]$match }
  if ($Required) { throw "Cannot find $Label`: $raw" }
  return ""
}

function Select-Columns {
  param($Sheet)
  $headers = @($Sheet.headers)
  Show-Headers -Sheet $Sheet

  if (-not $PromptColumn) {
    $defaultPrompt = Find-HeaderDefault -Headers $headers -Pattern "\u751f\u56fe\u63d0\u793a\u8bcd|\u63d0\u793a\u8bcd"
    $PromptColumn = Read-WithDefault -Prompt "Prompt column: enter number, letter, or header" -Default $defaultPrompt
  }
  $resolvedPromptColumn = Resolve-HeaderChoice -Headers $headers -Choice $PromptColumn -Label "prompt column" -Required

  if ($null -eq $ReferenceImageColumns) {
    $defaultRefs = @($headers | Where-Object {
      $text = [string]$_
      $text -match "\u53c2\u8003\u56fe|\u56fe\u7247\u8def\u5f84|\u56fe.*\u8def\u5f84" -and
        $text -notmatch "\u7528\u9014|\u7c7b\u578b|\u7f16\u53f7"
    })
    $defaultRefText = $defaultRefs -join ","
    $refAnswer = Read-WithDefault -Prompt "Reference image column(s): comma-separated number/letter/header; type none for no refs" -Default $defaultRefText
    if ($refAnswer -match "^(none|no|0)$") {
      $ReferenceImageColumns = @()
    } else {
      $ReferenceImageColumns = Split-Selectors -Value $refAnswer
    }
  }

  $resolvedRefs = @()
  foreach ($selector in @($ReferenceImageColumns)) {
    $resolved = Resolve-HeaderChoice -Headers $headers -Choice $selector -Label "reference column"
    if ($resolved) { $resolvedRefs += $resolved }
  }

  if (-not $IdColumn) {
    $defaultId = Find-HeaderDefault -Headers $headers -Pattern "\u7f16\u53f7|ID|\u5e8f\u53f7"
    $idAnswer = Read-WithDefault -Prompt "ID column: number/letter/header; leave blank to use row number" -Default $defaultId
    $IdColumn = $idAnswer
  }
  $resolvedId = Resolve-HeaderChoice -Headers $headers -Choice $IdColumn -Label "ID column"

  return [PSCustomObject]@{
    PromptColumn = $resolvedPromptColumn
    ReferenceImageColumns = $resolvedRefs
    IdColumn = $resolvedId
  }
}

function Select-RowRange {
  param($Sheet)
  $firstRow = 2
  $lastRow = [int]$Sheet.rowCount + 1
  if ($lastRow -lt $firstRow) { throw "Selected sheet has no data rows." }

  if ($StartRow -gt 0 -and $EndRow -gt 0) {
    return [PSCustomObject]@{ StartRow = $StartRow; EndRow = $EndRow }
  }

  $answer = Read-WithDefault -Prompt "Excel row range, e.g. 2-6; type all for all rows" -Default "$firstRow-$firstRow"
  if ($answer -match "^(all|a)$") {
    return [PSCustomObject]@{ StartRow = $firstRow; EndRow = $lastRow }
  }
  if ($answer -match "^\d+$") {
    $row = [int]$answer
    return [PSCustomObject]@{ StartRow = $row; EndRow = $row }
  }
  if ($answer -match "^(\d+)\s*[-~]\s*(\d+)$") {
    $start = [int]$Matches[1]
    $end = [int]$Matches[2]
    if ($start -gt $end) { throw "Start row cannot be greater than end row." }
    return [PSCustomObject]@{ StartRow = $start; EndRow = $end }
  }
  throw "Invalid row range: $answer"
}

$resolvedWorkbook = Select-Workbook -ExplicitPath $WorkbookPath -Root $SearchRoot
Write-Output "Selected workbook: $resolvedWorkbook"

$inspection = Invoke-WorkbookInspect -ResolvedWorkbookPath $resolvedWorkbook
$selectedSheetName = Select-Sheet -Inspection $inspection -ExplicitSheetName $SheetName
$sheet = @($inspection.sheets | Where-Object { $_.name -eq $selectedSheetName } | Select-Object -First 1)
if (-not $sheet) { throw "Worksheet not found: $selectedSheetName" }

$columns = Select-Columns -Sheet $sheet
$range = Select-RowRange -Sheet $sheet

if (-not $OutputDir) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $OutputDir = Join-Path (Split-Path -Parent $resolvedWorkbook) "generated_images_$stamp"
}

Write-Output "Preview settings:"
Write-Output "  Sheet: $selectedSheetName"
Write-Output "  ID column: $($columns.IdColumn)"
Write-Output "  Reference column(s): $(@($columns.ReferenceImageColumns) -join ', ')"
Write-Output "  Prompt column: $($columns.PromptColumn)"
Write-Output "  Excel rows: $($range.StartRow)-$($range.EndRow)"
Write-Output "  Output dir: $OutputDir"

$runner = Join-Path $PSScriptRoot "generate_images_from_sheet.ps1"
$commonParams = @{
  WorkbookPath = $resolvedWorkbook
  SheetName = $selectedSheetName
  PromptColumn = $columns.PromptColumn
  StartRow = $range.StartRow
  EndRow = $range.EndRow
  OutputDir = $OutputDir
  TargetSize = $TargetSize
  ReferenceRetryCount = $ReferenceRetryCount
}
if ($columns.IdColumn) { $commonParams.IdColumn = $columns.IdColumn }
if (@($columns.ReferenceImageColumns).Count -gt 0) { $commonParams.ReferenceImageColumns = @($columns.ReferenceImageColumns) }
if ($ApiKey) { $commonParams.ApiKey = $ApiKey }
if ($BaseUrl) { $commonParams.BaseUrl = $BaseUrl }
if ($Model) { $commonParams.Model = $Model }
if ($NoReferences) { $commonParams.NoReferences = $true }
if ($AllowPromptOnlyFallback) { $commonParams.AllowPromptOnlyFallback = $true }
if ($AdditionalPrompt) { $commonParams.AdditionalPrompt = $AdditionalPrompt }

& $runner @commonParams

if ($PreviewOnly) {
  Write-Output "Preview complete. API was not called."
  return
}

if (-not $Execute) {
  $confirm = Read-Host "If preview is correct, type YES to call the API; anything else exits"
  if ($confirm -ne "YES") {
    Write-Output "Stopped. API was not called."
    return
  }
}

$executeParams = $commonParams.Clone()
$executeParams.Execute = $true
& $runner @executeParams
