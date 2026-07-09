param(
  [Parameter(Mandatory = $true)][string]$CompiledJson,
  [Parameter(Mandatory = $true)][string]$OutputDir,
  [string[]]$TaskIds,
  [string]$StyleCode
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

function Get-Dimensions {
  param([string]$Text)
  $matches = @([regex]::Matches($Text, "\d{3,5}") | ForEach-Object { [int]$_.Value })
  if ($matches.Count -lt 2) { return @{ Width = 1440; Height = 1440 } }
  return @{ Width = $matches[0]; Height = $matches[1] }
}

function New-Font {
  param([float]$Size, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
  return [System.Drawing.Font]::new("Microsoft YaHei", $Size, $Style, [System.Drawing.GraphicsUnit]::Pixel)
}

function Sanitize-Name {
  param([string]$Name)
  $clean = $Name -replace '[\\/:*?"<>|]', "_"
  $clean = $clean -replace "\s+", ""
  if ($clean.Length -gt 48) { $clean = $clean.Substring(0, 48) }
  return $clean
}

function Get-StyleCodeFromText {
  param([string]$Text)
  if (-not $Text) { return "" }
  $match = [regex]::Match($Text, "(?i)(?<![A-Z0-9])([A-Z]{1,6}\d{3,6}[A-Z0-9]*)(?![A-Z0-9])")
  if ($match.Success) { return $match.Groups[1].Value.ToUpperInvariant() }
  return ""
}

function Draw-CenteredText {
  param(
    [System.Drawing.Graphics]$Graphics,
    [string]$Text,
    [System.Drawing.Font]$Font,
    [System.Drawing.Brush]$Brush,
    [System.Drawing.RectangleF]$Rectangle
  )
  $format = [System.Drawing.StringFormat]::new()
  try {
    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    $format.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
    $Graphics.DrawString($Text, $Font, $Brush, $Rectangle, $format)
  } finally {
    $format.Dispose()
  }
}

if (-not (Test-Path -LiteralPath $CompiledJson)) { throw "Compiled JSON not found: $CompiledJson" }
$data = Get-Content -Raw -Encoding UTF8 $CompiledJson | ConvertFrom-Json
$resolvedStyleCode = Get-StyleCodeFromText -Text $StyleCode
if (-not $resolvedStyleCode -and $data.product.product_id) { $resolvedStyleCode = Get-StyleCodeFromText -Text ([string]$data.product.product_id) }
if (-not $resolvedStyleCode) { $resolvedStyleCode = Get-StyleCodeFromText -Text $CompiledJson }
if (-not $resolvedStyleCode) {
  throw "Unable to resolve product style code for fixed asset output filenames. Pass -StyleCode, for example JR0384, or use a compiled JSON path containing the code."
}
$resolvedStyleCode = Sanitize-Name -Name $resolvedStyleCode
$tasks = @($data.tasks | Where-Object { $_.execution_mode -eq "fixed_asset_composite" })
if ($TaskIds -and $TaskIds.Count -gt 0) {
  $tasks = @($tasks | Where-Object { $_.task_id -in $TaskIds })
}
if ($tasks.Count -eq 0) {
  Write-Output (@{ count = 0; outputDir = $OutputDir } | ConvertTo-Json)
  return
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$results = @()
foreach ($task in $tasks) {
  $fixedPath = [string]$task.fixed_asset_paths[0]
  if (-not $fixedPath -or -not (Test-Path -LiteralPath $fixedPath)) {
    throw "Fixed asset missing for task $($task.task_id): $fixedPath"
  }
  $dim = Get-Dimensions -Text ([string]$task.dimensions)
  $width = [int]$dim.Width
  $height = [int]$dim.Height
  $canvas = [System.Drawing.Bitmap]::new($width, $height)
  $graphics = [System.Drawing.Graphics]::FromImage($canvas)
  try {
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $background = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
      ([System.Drawing.Rectangle]::new(0, 0, $width, $height)),
      [System.Drawing.Color]::FromArgb(242, 250, 255),
      [System.Drawing.Color]::FromArgb(210, 235, 248),
      90.0
    )
    try { $graphics.FillRectangle($background, 0, 0, $width, $height) } finally { $background.Dispose() }

    $headlineFont = New-Font -Size ([Math]::Max(38, [Math]::Round($width * 0.045))) -Style ([System.Drawing.FontStyle]::Bold)
    $subtitleFont = New-Font -Size ([Math]::Max(24, [Math]::Round($width * 0.024)))
    $cardFont = New-Font -Size ([Math]::Max(19, [Math]::Round($width * 0.018)))
    $darkBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(15, 76, 110))
    $textBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(32, 53, 70))
    try {
      Draw-CenteredText -Graphics $graphics -Text ([string]$task.visible_copy.headline) -Font $headlineFont -Brush $darkBrush -Rectangle ([System.Drawing.RectangleF]::new(70, 35, $width - 140, 90))
      Draw-CenteredText -Graphics $graphics -Text ([string]$task.visible_copy.subtitle) -Font $subtitleFont -Brush $textBrush -Rectangle ([System.Drawing.RectangleF]::new(70, 120, $width - 140, 60))

      $top = 205
      $bottomArea = [Math]::Max(150, [Math]::Round($height * 0.12))
      $availableHeight = $height - $top - $bottomArea - 55
      $availableWidth = $width - 150
      $source = [System.Drawing.Image]::FromFile($fixedPath)
      try {
        $scale = [Math]::Min($availableWidth / [double]$source.Width, $availableHeight / [double]$source.Height)
        $drawWidth = [int][Math]::Round($source.Width * $scale)
        $drawHeight = [int][Math]::Round($source.Height * $scale)
        $drawX = [int][Math]::Round(($width - $drawWidth) / 2)
        $drawY = $top + [int][Math]::Round(($availableHeight - $drawHeight) / 2)
        $shadowBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(30, 20, 50, 70))
        $whiteBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
        try {
          $graphics.FillRectangle($shadowBrush, $drawX + 12, $drawY + 12, $drawWidth, $drawHeight)
          $graphics.FillRectangle($whiteBrush, $drawX - 12, $drawY - 12, $drawWidth + 24, $drawHeight + 24)
          $graphics.DrawImage($source, $drawX, $drawY, $drawWidth, $drawHeight)
        } finally {
          $shadowBrush.Dispose()
          $whiteBrush.Dispose()
        }
      } finally {
        $source.Dispose()
      }

      $cards = @($task.visible_copy.cards)
      $cardText = $cards -join "   ｜   "
      Draw-CenteredText -Graphics $graphics -Text $cardText -Font $cardFont -Brush $textBrush -Rectangle ([System.Drawing.RectangleF]::new(55, $height - $bottomArea, $width - 110, 65))
      Draw-CenteredText -Graphics $graphics -Text ([string]$task.visible_copy.footer) -Font $subtitleFont -Brush $darkBrush -Rectangle ([System.Drawing.RectangleF]::new(55, $height - 75, $width - 110, 55))
    } finally {
      $headlineFont.Dispose()
      $subtitleFont.Dispose()
      $cardFont.Dispose()
      $darkBrush.Dispose()
      $textBrush.Dispose()
    }

    $fileName = if ($task.output_filename) { [string]$task.output_filename } else { "$($task.task_id).png" }
    if ($fileName -notlike "$resolvedStyleCode`_*") { $fileName = "$resolvedStyleCode`_$fileName" }
    $outputPath = Join-Path $OutputDir $fileName
    $canvas.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $results += [PSCustomObject]@{
      taskId = $task.task_id
      styleCode = $resolvedStyleCode
      outputPath = $outputPath
      fixedAssetPath = $fixedPath
      width = $width
      height = $height
    }
  } finally {
    $graphics.Dispose()
    $canvas.Dispose()
  }
}

$summary = [PSCustomObject]@{
  compiledJson = (Resolve-Path -LiteralPath $CompiledJson).Path
  outputDir = (Resolve-Path -LiteralPath $OutputDir).Path
  styleCode = $resolvedStyleCode
  count = $results.Count
  results = $results
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $OutputDir "fixed_asset_summary.json")
Write-Output ($summary | ConvertTo-Json -Depth 6)
