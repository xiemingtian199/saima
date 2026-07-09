param(
  [Parameter(Mandatory = $true)][string]$WorkbookPath,
  [string]$OutputDir,
  [string]$ApiKey,
  [string]$BaseUrl,
  [string]$Model,
  [int]$TargetSize = 1440,
  [string]$PromptSheetName,
  [string]$PromptsJsonPath,
  [int]$StartRow,
  [int]$EndRow,
  [switch]$PreviewOnly,
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
  [string[]]$RejectReferencePatterns = @("竞品", "科巢", "tmall.com", "阿里健康", "scoornest", "London", "UK"),
  [string[]]$SkipExecutionModes = @("fixed_asset_composite"),
[switch]$SkipMainLongImages,
[ValidateRange(1, 20)][int]$MainLongGroupSize = 5,
[ValidateRange(512, 4096)][int]$MainLongWidth = 1440,
[ValidateRange(512, 4096)][int]$MainLongHeight = 1920,
[switch]$CreateContactSheets
)

$ErrorActionPreference = "Stop"
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  [Net.ServicePointManager]::Expect100Continue = $false
} catch {
  # Keep running on hosts where ServicePointManager is unavailable.
}

function Get-ConfigValue {
  param([string]$Explicit, [string]$EnvName, [string]$Default)
  if ($Explicit) { return $Explicit }
  $processValue = [Environment]::GetEnvironmentVariable($EnvName, "Process")
  if ($processValue) { return $processValue }
  $userValue = [Environment]::GetEnvironmentVariable($EnvName, "User")
  if ($userValue) { return $userValue }
  return $Default
}

function Normalize-BaseUrl {
  param([string]$Url)
  $clean = ($Url.Trim()).TrimEnd("/")
  if ($clean -match "/chat/completions$") { $clean = $clean -replace "/chat/completions$", "" }
  if ($clean -match "/images/generations$") { $clean = $clean -replace "/images/generations$", "" }
  if ($clean -notmatch "/v1$") { $clean = "$clean/v1" }
  return $clean
}

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

function Convert-ImageToDataUrl {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$MaxSide = 960,
    [switch]$PreserveOriginal
  )

  if ($PreserveOriginal) {
    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $mime = if ($extension -eq ".png") { "image/png" } elseif ($extension -in @(".jpg", ".jpeg")) { "image/jpeg" } else { $null }
    if ($mime) {
      return "data:$mime;base64," + [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
    }
  }

  $img = [System.Drawing.Image]::FromFile($Path)
  try {
    $scale = [Math]::Min($MaxSide / [double]$img.Width, $MaxSide / [double]$img.Height)
    if ($scale -gt 1) { $scale = 1 }
    $w = [Math]::Max(1, [int][Math]::Round($img.Width * $scale))
    $h = [Math]::Max(1, [int][Math]::Round($img.Height * $scale))
    $thumb = New-Object System.Drawing.Bitmap $w, $h
    try {
      $g = [System.Drawing.Graphics]::FromImage($thumb)
      try {
        $g.Clear([System.Drawing.Color]::White)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.DrawImage($img, 0, 0, $w, $h)
      } finally {
        $g.Dispose()
      }

      $ms = New-Object System.IO.MemoryStream
      try {
        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
          Where-Object { $_.MimeType -eq "image/jpeg" } |
          Select-Object -First 1
        $encoder = [System.Drawing.Imaging.Encoder]::Quality
        $params = New-Object System.Drawing.Imaging.EncoderParameters 1
        $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter $encoder, 88L
        $thumb.Save($ms, $codec, $params)
        return "data:image/jpeg;base64," + [Convert]::ToBase64String($ms.ToArray())
      } finally {
        $ms.Dispose()
      }
    } finally {
      $thumb.Dispose()
    }
  } finally {
    $img.Dispose()
  }
}

function Save-TargetImage {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][int]$Width,
    [Parameter(Mandatory = $true)][int]$Height
  )

  $src = [System.Drawing.Image]::FromFile($InputPath)
  try {
    $canvas = New-Object System.Drawing.Bitmap $Width, $Height
    try {
      $g = [System.Drawing.Graphics]::FromImage($canvas)
      try {
        $g.Clear([System.Drawing.Color]::White)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $coverScale = [Math]::Max($Width / [double]$src.Width, $Height / [double]$src.Height)
        $coverW = [int][Math]::Round($src.Width * $coverScale)
        $coverH = [int][Math]::Round($src.Height * $coverScale)
        $coverX = [int][Math]::Floor(($Width - $coverW) / 2)
        $coverY = [int][Math]::Floor(($Height - $coverH) / 2)
        $g.DrawImage($src, $coverX, $coverY, $coverW, $coverH)
        $overlay = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(120, 255, 255, 255))
        try {
          $g.FillRectangle($overlay, 0, 0, $Width, $Height)
        } finally {
          $overlay.Dispose()
        }

        $fitScale = [Math]::Min($Width / [double]$src.Width, $Height / [double]$src.Height)
        $w = [int][Math]::Round($src.Width * $fitScale)
        $h = [int][Math]::Round($src.Height * $fitScale)
        $x = [int][Math]::Floor(($Width - $w) / 2)
        $y = [int][Math]::Floor(($Height - $h) / 2)
        $g.DrawImage($src, $x, $y, $w, $h)
      } finally {
        $g.Dispose()
      }
      $canvas.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
      $canvas.Dispose()
    }
  } finally {
    $src.Dispose()
  }
}

function Get-TargetDimensions {
  param($Row)
  $sizeText = [string]$Row.outputSize
  $numbers = @([regex]::Matches($sizeText, "\d{3,5}") | ForEach-Object { [int]$_.Value })
  if ($numbers.Count -lt 2) {
    throw "Missing explicit outputSize for Excel row $($Row.rowNumber) / $($Row.imageNo). Fix the handoff task JSON before generation; do not default to square size."
  }
  $width = $numbers[0]
  $height = $numbers[1]
  return [PSCustomObject]@{ width = $width; height = $height }
}

function Get-ApiImageSize {
  param(
    [Parameter(Mandatory = $true)][int]$TargetWidth,
    [Parameter(Mandatory = $true)][int]$TargetHeight
  )
  $ratio = $TargetWidth / [double]$TargetHeight
  if ([Math]::Abs($ratio - 1.0) -lt 0.12) { return "1024x1024" }
  if ($ratio -gt 1.0) { return "1536x1024" }
  return "1024x1536"
}

function Get-ImageSize {
  param([Parameter(Mandatory = $true)][string]$Path)
  $img = [System.Drawing.Image]::FromFile($Path)
  try {
    return @{ width = $img.Width; height = $img.Height }
  } finally {
    $img.Dispose()
  }
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

function Resolve-StyleCode {
  param([string]$Explicit, [string[]]$Candidates)
  $code = Get-StyleCodeFromText -Text $Explicit
  if ($code) { return (Sanitize-Name -Name $code) }
  foreach ($candidate in @($Candidates)) {
    $code = Get-StyleCodeFromText -Text $candidate
    if ($code) { return (Sanitize-Name -Name $code) }
  }
  return ""
}

function Get-FilteredReferences {
  param($Row)
  if ($NoReferences) { return @() }
  $refs = @($Row.references | Where-Object { Test-Path -LiteralPath $_ })
  if ($ReferenceAllowPatterns -and $ReferenceAllowPatterns.Count -gt 0) {
    $refs = @($refs | Where-Object {
      $ref = $_
      (@($ReferenceAllowPatterns | Where-Object { $ref -like "*$_*" }).Count)
    })
  }
  if ($RejectReferencePatterns -and $RejectReferencePatterns.Count -gt 0) {
    $refs = @($refs | Where-Object {
      $ref = $_
      -not (@($RejectReferencePatterns | Where-Object { $ref -like "*$_*" }).Count)
    })
  }
  return @($refs | Select-Object -First 4)
}

function Get-ShortErrorMessage {
  param($ErrorRecord)
  $parts = New-Object System.Collections.ArrayList
  if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Message) {
    [void]$parts.Add([string]$ErrorRecord.Exception.Message)
  }
  if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
    [void]$parts.Add([string]$ErrorRecord.ErrorDetails.Message)
  }
  $message = (@($parts) -join " ")
  $message = $message -replace "Bearer\s+[A-Za-z0-9._-]+", "Bearer ***"
  $message = $message -replace "sk-[A-Za-z0-9._-]+", "sk-***"
  $message = $message -replace "\s+", " "
  if ($message.Length -gt 500) { $message = $message.Substring(0, 500) + "..." }
  return $message
}

function Invoke-ImageEditWithReferences {
  param(
    [Parameter(Mandatory = $true)][string]$Prompt,
    [Parameter(Mandatory = $true)][string[]]$ReferencePaths,
    [Parameter(Mandatory = $true)][string]$RawPath,
    [Parameter(Mandatory = $true)][string]$ResolvedApiKey,
    [Parameter(Mandatory = $true)][string]$ResolvedBaseUrl,
    [Parameter(Mandatory = $true)][string]$ResolvedModel,
    [Parameter(Mandatory = $true)][int]$TargetWidth,
    [Parameter(Mandatory = $true)][int]$TargetHeight,
    [Parameter(Mandatory = $true)][string]$Mode
  )

  $validRefs = @($ReferencePaths | Where-Object { Test-Path -LiteralPath $_ })
  if ($validRefs.Count -eq 0) {
    throw "No valid reference image found for images/edits request."
  }

  $apiSize = Get-ApiImageSize -TargetWidth $TargetWidth -TargetHeight $TargetHeight
  $requestDir = Join-Path ([System.IO.Path]::GetDirectoryName($RawPath)) ("_image_edit_request_{0}" -f ([guid]::NewGuid().ToString("N")))
  New-Item -ItemType Directory -Force -Path $requestDir | Out-Null
  $responsePath = Join-Path $requestDir "response.json"
  $errorPath = Join-Path $requestDir "curl.err.txt"

  try {
    $curlArgs = @(
      "-sS",
      "--max-time", "$ImageTimeoutSec",
      "--connect-timeout", "30",
      "-X", "POST",
      "$ResolvedBaseUrl/images/edits",
      "-H", "Authorization: Bearer $ResolvedApiKey",
      "-F", "model=$ResolvedModel",
      "-F", "prompt=$Prompt",
      "-F", "size=$apiSize",
      "-F", "output_format=png",
      "-o", $responsePath
    )

    $refIndex = 0
    foreach ($ref in $validRefs) {
      $refIndex++
      $extension = [System.IO.Path]::GetExtension($ref).ToLowerInvariant()
      if ($extension -notin @(".png", ".jpg", ".jpeg", ".webp")) { $extension = ".png" }
      $copyPath = Join-Path $requestDir ("ref_{0:D2}{1}" -f $refIndex, $extension)
      Copy-Item -LiteralPath $ref -Destination $copyPath -Force
      $curlArgs += @("-F", "image[]=@$copyPath")
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = "Continue"
      & curl.exe @curlArgs 2> $errorPath
    } finally {
      $ErrorActionPreference = $previousErrorActionPreference
    }
    $curlExitCode = $LASTEXITCODE
    $curlError = if (Test-Path -LiteralPath $errorPath) { [System.IO.File]::ReadAllText($errorPath, [System.Text.Encoding]::UTF8) } else { "" }
    if ($curlExitCode -ne 0) {
      throw "images/edits curl failed with exit code $curlExitCode. $curlError"
    }
    if (-not (Test-Path -LiteralPath $responsePath)) {
      throw "images/edits returned no response body. $curlError"
    }

    $responseText = [System.IO.File]::ReadAllText($responsePath, [System.Text.Encoding]::UTF8)
    try {
      $resp = $responseText | ConvertFrom-Json
    } catch {
      $preview = if ($responseText.Length -gt 500) { $responseText.Substring(0, 500) + "..." } else { $responseText }
      throw "images/edits returned invalid JSON: $preview"
    }

    if ($resp.error) {
      $errorJson = $resp.error | ConvertTo-Json -Depth 8 -Compress
      throw "images/edits error: $errorJson"
    }

    if ($resp.data -and $resp.data[0].b64_json) {
      [IO.File]::WriteAllBytes($RawPath, [Convert]::FromBase64String([string]$resp.data[0].b64_json))
    } elseif ($resp.data -and $resp.data[0].url) {
      Invoke-WebRequest -Uri $resp.data[0].url -OutFile $RawPath -TimeoutSec $DownloadTimeoutSec
    } else {
      $preview = if ($responseText.Length -gt 500) { $responseText.Substring(0, 500) + "..." } else { $responseText }
      throw "images/edits returned no image data: $preview"
    }

    return @{
      mode = $Mode
      endpoint = "images/edits"
      referenceCount = $validRefs.Count
      identityReference = $validRefs[0]
      requestedApiSize = $apiSize
      responseCreated = $resp.created
      responseId = $resp.id
    }
  } finally {
    if (Test-Path -LiteralPath $requestDir) {
      Remove-Item -LiteralPath $requestDir -Recurse -Force
    }
  }
}

function Invoke-ChatImage {
  param(
    [Parameter(Mandatory = $true)]$Row,
    [Parameter(Mandatory = $true)][string]$RawPath,
    [Parameter(Mandatory = $true)][string]$ResolvedApiKey,
    [Parameter(Mandatory = $true)][string]$ResolvedBaseUrl,
    [Parameter(Mandatory = $true)][string]$ResolvedModel,
    [Parameter(Mandatory = $true)][int]$TargetWidth,
    [Parameter(Mandatory = $true)][int]$TargetHeight
  )

  $prompt = @"
$($Row.prompt)

$AdditionalPrompt

Final output requirements: e-commerce $($Row.imageType) image, target aspect ratio and size $TargetWidth x $TargetHeight, no border or frame, natural background fills the full canvas edge to edge. The first uploaded image is the authoritative product identity reference. Treat its packaging artwork as an immutable printed texture: preserve package geometry, logo, every visible printed word, number, icon, color block, and their relative positions. Only adapt the whole product's perspective, scale, occlusion, and scene lighting. Do not redesign, rewrite, translate, simplify, omit, duplicate, or invent package content. If secondary references conflict, the first image always wins. Keep at least one product face large and clear enough to verify the main printed content, and avoid extreme perspective that makes the identity unreadable. Do not include external platform names, shop names, competitor names, QR codes, phone numbers, URLs, or any text beyond the specified visible copy.
"@

  $refs = Get-FilteredReferences -Row $Row
  return Invoke-ImageEditWithReferences `
    -Prompt $prompt `
    -ReferencePaths $refs `
    -RawPath $RawPath `
    -ResolvedApiKey $ResolvedApiKey `
    -ResolvedBaseUrl $ResolvedBaseUrl `
    -ResolvedModel $ResolvedModel `
    -TargetWidth $TargetWidth `
    -TargetHeight $TargetHeight `
    -Mode "images_edits_with_references"
}

function Invoke-ChatImageWithExplicitReferences {
  param(
    [Parameter(Mandatory = $true)][string]$Prompt,
    [Parameter(Mandatory = $true)][string[]]$ReferencePaths,
    [Parameter(Mandatory = $true)][string]$RawPath,
    [Parameter(Mandatory = $true)][string]$ResolvedApiKey,
    [Parameter(Mandatory = $true)][string]$ResolvedBaseUrl,
    [Parameter(Mandatory = $true)][string]$ResolvedModel,
    [Parameter(Mandatory = $true)][int]$TargetWidth,
    [Parameter(Mandatory = $true)][int]$TargetHeight
  )

  $fullPrompt = @"
$Prompt

$AdditionalPrompt

Final output requirements: e-commerce main image, target aspect ratio and size $TargetWidth x $TargetHeight, no border or frame, natural background fills the full canvas edge to edge. Use the uploaded square image as the authoritative source. Preserve all visible text, icons, product shape, packaging, logo, color blocks, and relative content relationships. Do not rewrite, add, remove, translate, simplify, duplicate, or replace any text or icon. Only extend the canvas and make minimal layout spacing adjustments required by the taller ratio.
"@

  $apiResult = Invoke-ImageEditWithReferences `
    -Prompt $fullPrompt `
    -ReferencePaths $ReferencePaths `
    -RawPath $RawPath `
    -ResolvedApiKey $ResolvedApiKey `
    -ResolvedBaseUrl $ResolvedBaseUrl `
    -ResolvedModel $ResolvedModel `
    -TargetWidth $TargetWidth `
    -TargetHeight $TargetHeight `
    -Mode "main_square_to_long"
  $apiResult.squareReference = $ReferencePaths[0]
  return $apiResult
}

function Invoke-ImageGeneration {
  param(
    [Parameter(Mandatory = $true)]$Row,
    [Parameter(Mandatory = $true)][string]$RawPath,
    [Parameter(Mandatory = $true)][string]$ResolvedApiKey,
    [Parameter(Mandatory = $true)][string]$ResolvedBaseUrl,
    [Parameter(Mandatory = $true)][string]$ResolvedModel,
    [Parameter(Mandatory = $true)][int]$TargetWidth,
    [Parameter(Mandatory = $true)][int]$TargetHeight
  )

  $headers = @{
    Authorization = "Bearer $ResolvedApiKey"
    "Content-Type" = "application/json; charset=utf-8"
  }
  $prompt = @"
$($Row.prompt)

$AdditionalPrompt

Final output requirements: e-commerce $($Row.imageType) image, target aspect ratio and size $TargetWidth x $TargetHeight, no border or frame, natural background fills the full canvas edge to edge. Do not include external platform names, shop names, competitor names, QR codes, phone numbers, URLs, or any text beyond the specified visible copy.
"@
  $body = @{
    model = $ResolvedModel
    prompt = $prompt
    size = Get-ApiImageSize -TargetWidth $TargetWidth -TargetHeight $TargetHeight
    n = 1
  } | ConvertTo-Json -Depth 20 -Compress
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

  $resp = Invoke-RestMethod -Uri "$ResolvedBaseUrl/images/generations" -Headers $headers -Method Post -Body $bodyBytes -TimeoutSec $ImageTimeoutSec
  if ($resp.data -and $resp.data[0].b64_json) {
    [IO.File]::WriteAllBytes($RawPath, [Convert]::FromBase64String($resp.data[0].b64_json))
  } elseif ($resp.data -and $resp.data[0].url) {
    Invoke-WebRequest -Uri $resp.data[0].url -OutFile $RawPath -TimeoutSec $DownloadTimeoutSec
  } else {
    throw "images/generations returned no image data."
  }
  return @{
    mode = "images_generations"
    referenceCount = 0
    requestedApiSize = Get-ApiImageSize -TargetWidth $TargetWidth -TargetHeight $TargetHeight
    responseCreated = $resp.created
  }
}

function Save-ContactSheet {
  param(
    [Parameter(Mandatory = $true)][string]$FinalDir,
    [Parameter(Mandatory = $true)][string]$OutputPath
  )

  $files = @(Get-ChildItem -LiteralPath $FinalDir -Filter *.png | Sort-Object Name)
  if ($files.Count -eq 0) { return }
  $thumb = 420
  $cols = 3
  $rows = [int][Math]::Ceiling($files.Count / [double]$cols)
  $labelH = 48
  $canvas = New-Object System.Drawing.Bitmap ($cols * $thumb), ($rows * ($thumb + $labelH))
  $g = [System.Drawing.Graphics]::FromImage($canvas)
  try {
    $g.Clear([System.Drawing.Color]::White)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $font = New-Object System.Drawing.Font "Microsoft YaHei", 11
    $brush = [System.Drawing.Brushes]::Black
    for ($i = 0; $i -lt $files.Count; $i++) {
      $img = [System.Drawing.Image]::FromFile($files[$i].FullName)
      try {
        $x = ($i % $cols) * $thumb
        $y = [int][Math]::Floor($i / $cols) * ($thumb + $labelH)
        $scale = [Math]::Min($thumb / [double]$img.Width, $thumb / [double]$img.Height)
        $drawW = [int][Math]::Round($img.Width * $scale)
        $drawH = [int][Math]::Round($img.Height * $scale)
        $drawX = $x + [int][Math]::Floor(($thumb - $drawW) / 2)
        $drawY = $y + [int][Math]::Floor(($thumb - $drawH) / 2)
        $g.DrawImage($img, $drawX, $drawY, $drawW, $drawH)
        $label = [System.IO.Path]::GetFileNameWithoutExtension($files[$i].Name)
        if ($label.Length -gt 34) { $label = $label.Substring(0, 34) }
        $g.DrawString($label, $font, $brush, $x + 12, $y + $thumb + 10)
      } finally {
        $img.Dispose()
      }
    }
  } finally {
    $g.Dispose()
  }
  $canvas.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $canvas.Dispose()
}

function Copy-FinalImagesToDeliveryFolder {
  param(
    [Parameter(Mandatory = $true)][string[]]$SourceDirs,
    [Parameter(Mandatory = $true)][string]$DeliveryDir
  )
  New-Item -ItemType Directory -Force -Path $DeliveryDir | Out-Null
  $copied = New-Object System.Collections.ArrayList
  foreach ($sourceDir in $SourceDirs) {
    if (-not (Test-Path -LiteralPath $sourceDir)) { continue }
    $files = @(Get-ChildItem -LiteralPath $sourceDir -File -Filter "*.png" | Sort-Object Name)
    foreach ($file in $files) {
      $targetPath = Join-Path $DeliveryDir $file.Name
      Copy-Item -LiteralPath $file.FullName -Destination $targetPath -Force
      [void]$copied.Add([PSCustomObject]@{
        fileName = $file.Name
        sourcePath = $file.FullName
        deliveryPath = $targetPath
      })
    }
  }
  return [PSCustomObject]@{
    dir = (Resolve-Path -LiteralPath $DeliveryDir).Path
    count = $copied.Count
    files = @($copied)
  }
}

function Get-ItemValue {
  param($Item, [string]$Name)
  if ($Item -is [hashtable]) { return $Item[$Name] }
  return $Item.$Name
}

function Get-MainLongImagePlan {
  param([object[]]$Items)

  $groups = @{}
  foreach ($item in @($Items)) {
    $imageType = [string](Get-ItemValue -Item $item -Name "imageType")
    $linkOrder = [string](Get-ItemValue -Item $item -Name "linkOrder")
    $targetSize = Get-ItemValue -Item $item -Name "targetSize"
    $width = [int](Get-ItemValue -Item $targetSize -Name "width")
    $height = [int](Get-ItemValue -Item $targetSize -Name "height")
    if ($imageType -notmatch "主图" -or $width -ne $height) { continue }
    if (-not $linkOrder) { $linkOrder = "link" }
    if (-not $groups.ContainsKey($linkOrder)) { $groups[$linkOrder] = New-Object System.Collections.ArrayList }
    [void]$groups[$linkOrder].Add($item)
  }

  $plan = New-Object System.Collections.ArrayList
  foreach ($key in @($groups.Keys | Sort-Object)) {
    $items = @($groups[$key] | Sort-Object { [int](Get-ItemValue -Item $_ -Name "sourceRowNumber") })
    [void]$plan.Add([PSCustomObject]@{
      linkOrder = $key
      count = $items.Count
      ready = ($items.Count -eq $MainLongGroupSize)
      reason = if ($items.Count -eq $MainLongGroupSize) { "" } else { "主图方图数量不是 $MainLongGroupSize 张" }
      rows = @($items | ForEach-Object { Get-ItemValue -Item $_ -Name "sourceRowNumber" })
      items = $items
    })
  }
  return @($plan)
}

function Invoke-MainLongImages {
  param(
    [Parameter(Mandatory = $true)][object[]]$SquareResults,
    [Parameter(Mandatory = $true)][string]$LongRawDir,
    [Parameter(Mandatory = $true)][string]$LongFinalDir,
    [Parameter(Mandatory = $true)][string]$MetaDir,
    [Parameter(Mandatory = $true)][string]$ResolvedApiKey,
    [Parameter(Mandatory = $true)][string]$ResolvedBaseUrl,
    [Parameter(Mandatory = $true)][string]$ResolvedModel
  )

  New-Item -ItemType Directory -Force -Path $LongRawDir, $LongFinalDir | Out-Null
  $longResults = New-Object System.Collections.ArrayList
  $skippedGroups = New-Object System.Collections.ArrayList
  $plan = Get-MainLongImagePlan -Items $SquareResults

  foreach ($group in $plan) {
    if (-not $group.ready) {
      [void]$skippedGroups.Add([PSCustomObject]@{
        linkOrder = $group.linkOrder
        count = $group.count
        reason = $group.reason
        rows = $group.rows
      })
      continue
    }

    $items = @($group.items)
    $position = 0
    foreach ($item in $items) {
      $position++
      $sourceFinalPath = [string](Get-ItemValue -Item $item -Name "finalPath")
      if (-not (Test-Path -LiteralPath $sourceFinalPath)) {
        throw "Square main image missing for long conversion: $sourceFinalPath"
      }

      $sourceRow = [int](Get-ItemValue -Item $item -Name "sourceRowNumber")
      $imageNo = [string](Get-ItemValue -Item $item -Name "imageNo")
      $linkOrder = [string](Get-ItemValue -Item $item -Name "linkOrder")
      if (-not $linkOrder) { $linkOrder = "link" }
      $safeName = Sanitize-Name -Name $imageNo
      $prefix = "{0}{1}_main_long_row{2:D3}_{3}" -f $stylePrefix, (Sanitize-Name -Name $linkOrder), $sourceRow, $safeName
      $rawPath = Join-Path $LongRawDir "$prefix.raw.png"
      $finalPath = Join-Path $LongFinalDir "$prefix`_$($MainLongWidth)x$($MainLongHeight).png"
      $metaPath = Join-Path $MetaDir "$prefix.json"

      if ((Test-Path -LiteralPath $finalPath) -and (Test-Path -LiteralPath $metaPath)) {
        Write-Host "Skipping existing long main image link $linkOrder item $position / $($items.Count) from square row $sourceRow."
        $existingMeta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        [void]$longResults.Add($existingMeta)
        continue
      }

      $longPrompt = @"
请以上传的 1440x1440 方图为唯一参考，生成同一版淘宝主图 1440x1920 长图。
必须保持方图中的所有文字、图标、产品、包装、Logo、颜色、卖点结构和相对关系不变，不要重写、增删、翻译、替换任何文字，不要改变产品形态和包装。
只为适配 1440x1920 竖版比例扩展背景，并对图标、卖点卡、留白和层级做细微排布调整，让长图视觉更顺畅。
长图和方图必须看起来像同一版图片的不同尺寸。
"@

      Write-Host "Generating long main image link $linkOrder item $position / $($items.Count) from square row $sourceRow."
      $apiResult = $null
      $longErrors = New-Object System.Collections.ArrayList
      $maxLongAttempts = 1 + $ReferenceRetryCount
      for ($attempt = 1; $attempt -le $maxLongAttempts; $attempt++) {
        try {
          $apiResult = Invoke-ChatImageWithExplicitReferences `
            -Prompt $longPrompt `
            -ReferencePaths @($sourceFinalPath) `
            -RawPath $rawPath `
            -ResolvedApiKey $ResolvedApiKey `
            -ResolvedBaseUrl $ResolvedBaseUrl `
            -ResolvedModel $ResolvedModel `
            -TargetWidth $MainLongWidth `
            -TargetHeight $MainLongHeight
          break
        } catch {
          $shortError = Get-ShortErrorMessage -ErrorRecord $_
          [void]$longErrors.Add($shortError)
          if ($attempt -lt $maxLongAttempts) {
            Write-Host "Long main image attempt $attempt failed for square row ${sourceRow}: $shortError"
            Write-Host "Retrying long main image with the same square reference."
            Start-Sleep -Seconds ([Math]::Min(15, 4 * $attempt))
          }
        }
      }
      if (-not $apiResult) {
        $primaryError = $longErrors -join " | "
        throw "Long main image generation failed after $maxLongAttempts attempts for square row $sourceRow. Cause: $primaryError"
      }

      Save-TargetImage -InputPath $rawPath -OutputPath $finalPath -Width $MainLongWidth -Height $MainLongHeight
      $rawSize = Get-ImageSize -Path $rawPath
      $finalSize = Get-ImageSize -Path $finalPath
      $meta = [PSCustomObject]@{
        imageNo = "$imageNo-long"
        imageType = "主图长图"
        linkOrder = $linkOrder
        sourceSquareRowNumber = $sourceRow
        styleCode = $resolvedStyleCode
        sourceSquarePath = $sourceFinalPath
        rawPath = $rawPath
        finalPath = $finalPath
        rawSize = $rawSize
        finalSize = $finalSize
        api = $apiResult
        targetSize = @{ width = $MainLongWidth; height = $MainLongHeight }
        createdAt = (Get-Date).ToString("s")
      }
      $meta | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $metaPath
      [void]$longResults.Add($meta)
    }
  }

  return [PSCustomObject]@{
    count = $longResults.Count
    results = @($longResults)
    skippedGroups = @($skippedGroups)
  }
}

Add-Type -AssemblyName System.Drawing

$node = Resolve-DefaultNodePath
$modules = Resolve-DefaultNodeModulesPath
Ensure-NodeModules -ModulesPath $modules

if (-not $OutputDir) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $OutputDir = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $WorkbookPath)) "generated_images_$stamp"
}

$rawDir = Join-Path $OutputDir "raw"
$finalDir = Join-Path $OutputDir "final_images"
$longRawDir = Join-Path $OutputDir "raw_main_long_1440x1920"
$longFinalDir = Join-Path $OutputDir "main_long_1440x1920"
$metaDir = Join-Path $OutputDir "metadata"
$workDir = Join-Path $OutputDir "_working"
New-Item -ItemType Directory -Force -Path $rawDir, $finalDir, $metaDir, $workDir | Out-Null

$promptsJson = Join-Path $workDir "image_prompts.json"
if ($PromptsJsonPath) {
  $promptsJson = (Resolve-Path -LiteralPath $PromptsJsonPath).Path
  Write-Output "Using pre-extracted image task JSON: $promptsJson"
} else {
  $extractor = Join-Path $PSScriptRoot "extract_main_image_prompts.mjs"
  $extractArgs = @($WorkbookPath, $promptsJson)
  if ($PromptSheetName) { $extractArgs += $PromptSheetName }
  & $node $extractor @extractArgs | Out-Host
}

$data = Get-Content -Raw -Encoding UTF8 $promptsJson | ConvertFrom-Json
$rows = @($data.rows)
if ($rows.Count -eq 0) {
  throw "No prompt rows extracted from workbook."
}

if ($StartRow -le 0 -or $EndRow -le 0) {
  throw "Explicit Excel row selection is required. Provide both -StartRow and -EndRow after user confirmation."
}
if ($StartRow -gt $EndRow) {
  throw "StartRow cannot be greater than EndRow."
}
$selectedRows = @($rows | Where-Object {
  [int]$_.rowNumber -ge $StartRow -and [int]$_.rowNumber -le $EndRow
})
if ($selectedRows.Count -eq 0) {
  throw "No valid prompt rows found in Excel row range $StartRow-$EndRow."
}
$skippedRows = @($selectedRows | Where-Object { [string]$_.executionMode -in $SkipExecutionModes })
$rows = @($selectedRows | Where-Object { [string]$_.executionMode -notin $SkipExecutionModes })

$styleCandidates = New-Object System.Collections.ArrayList
[void]$styleCandidates.Add($WorkbookPath)
[void]$styleCandidates.Add($OutputDir)
if ($PromptsJsonPath) { [void]$styleCandidates.Add($PromptsJsonPath) }
foreach ($row in @($selectedRows)) {
  [void]$styleCandidates.Add([string]$row.imageNo)
  [void]$styleCandidates.Add([string]$row.outputFileName)
  foreach ($reference in @($row.references)) {
    [void]$styleCandidates.Add([string]$reference)
  }
}
$resolvedStyleCode = Resolve-StyleCode -Explicit $StyleCode -Candidates @($styleCandidates)
if (-not $resolvedStyleCode) {
  throw "Unable to resolve product style code for output filenames. Pass -StyleCode, for example JR0384, or use a workbook/path containing the code."
}
$stylePrefix = "$resolvedStyleCode`_"

foreach ($row in @($rows)) {
  [void](Get-TargetDimensions -Row $row)
}

if ($PreviewOnly) {
  $mainLongPlan = @()
  if (-not $SkipMainLongImages) {
    $mainLongPlan = @(
      $rows |
        Where-Object { [string]$_.imageType -match "主图" } |
        Group-Object -Property linkOrder |
        ForEach-Object {
          $groupRows = @($_.Group | Sort-Object rowNumber)
          [PSCustomObject]@{
            linkOrder = if ($_.Name) { $_.Name } else { "link" }
            squareMainCount = $groupRows.Count
            willGenerateLongImages = ($groupRows.Count -eq $MainLongGroupSize)
            targetLongSize = "$MainLongWidth`x$MainLongHeight"
            rows = @($groupRows | Select-Object rowNumber, imageNo)
          }
        }
    )
  }
  $preview = [PSCustomObject]@{
    workbookPath = (Resolve-Path -LiteralPath $WorkbookPath).Path
    sheetName = $data.sheetName
    startRow = $StartRow
    endRow = $EndRow
    selectedCount = $selectedRows.Count
    validImageCount = $rows.Count
    skippedCount = $skippedRows.Count
    mainLongImagesEnabled = -not $SkipMainLongImages
    mainLongImagePlan = $mainLongPlan
    styleCode = $resolvedStyleCode
    rows = @($rows | Select-Object rowNumber, imageNo, imageType, linkOrder, role, outputSize, outputFileName, executionMode)
    skippedRows = @($skippedRows | Select-Object rowNumber, imageNo, imageType, role, executionMode)
  }
  Write-Output ($preview | ConvertTo-Json -Depth 6)
  return
}

if ($rows.Count -eq 0) {
  throw "Selected Excel rows contain no image_generation tasks after execution-mode filtering."
}

$resolvedApiKey = Get-ConfigValue -Explicit $ApiKey -EnvName "YUNWU_API_KEY" -Default $null
if (-not $resolvedApiKey) {
  throw "Missing API key. Set user/process env var YUNWU_API_KEY or pass -ApiKey."
}
$resolvedBaseUrl = Normalize-BaseUrl -Url (Get-ConfigValue -Explicit $BaseUrl -EnvName "YUNWU_API_BASE_URL" -Default "https://yunwu.ai/v1")
$resolvedModel = Get-ConfigValue -Explicit $Model -EnvName "YUNWU_IMAGE_MODEL" -Default "gpt-image-2"

$results = New-Object System.Collections.ArrayList
$index = 0
foreach ($row in $rows) {
  $index++
  $dimensions = Get-TargetDimensions -Row $row
  Write-Output "Resolved Excel row $($row.rowNumber) output size '$($row.outputSize)' to $($dimensions.width)x$($dimensions.height)."
  $safeName = Sanitize-Name -Name ([string]$row.imageNo)
  if ($row.outputFileName) { $safeName = Sanitize-Name -Name ([string]$row.outputFileName) }
  $kind = if ([string]$row.imageType -match "详情") { "detail" } elseif ([string]$row.imageType -match "SKU") { "sku" } elseif ([string]$row.imageType -match "主图") { "main" } else { "image" }
  $linkTag = Sanitize-Name -Name ([string]$row.linkOrder)
  if (-not $linkTag) { $linkTag = "link" }
  $prefix = "{0}{1}_{2}_row{3:D3}_{4}" -f $stylePrefix, $linkTag, $kind, [int]$row.rowNumber, $safeName
  $rawPath = Join-Path $rawDir "$prefix.raw.png"
  $finalPath = Join-Path $finalDir "$prefix`_$($dimensions.width)x$($dimensions.height).png"
  $metaPath = Join-Path $metaDir "$prefix.json"

  if ((Test-Path -LiteralPath $finalPath) -and (Test-Path -LiteralPath $metaPath)) {
    Write-Output "Skipping existing output for Excel row $($row.rowNumber): $($row.imageNo)"
    $existingMeta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
    [void]$results.Add($existingMeta)
    continue
  }

  Write-Output "Generating $index / $($rows.Count): $($row.imageNo)"
  $apiResult = $null
  $filteredRefs = Get-FilteredReferences -Row $row
  if ($filteredRefs.Count -eq 0) {
    if (-not $NoReferences -and -not $AllowPromptOnlyFallback) {
      throw "No allowed own-brand reference images remain for Excel row $($row.rowNumber). Refusing prompt-only generation."
    }
    $apiResult = Invoke-ImageGeneration -Row $row -RawPath $rawPath -ResolvedApiKey $resolvedApiKey -ResolvedBaseUrl $resolvedBaseUrl -ResolvedModel $resolvedModel -TargetWidth $dimensions.width -TargetHeight $dimensions.height
  } else {
    $referenceErrors = New-Object System.Collections.ArrayList
    $maxReferenceAttempts = 1 + $ReferenceRetryCount
    for ($attempt = 1; $attempt -le $maxReferenceAttempts; $attempt++) {
      try {
        $apiResult = Invoke-ChatImage -Row $row -RawPath $rawPath -ResolvedApiKey $resolvedApiKey -ResolvedBaseUrl $resolvedBaseUrl -ResolvedModel $resolvedModel -TargetWidth $dimensions.width -TargetHeight $dimensions.height
        break
      } catch {
        $shortError = Get-ShortErrorMessage -ErrorRecord $_
        [void]$referenceErrors.Add($shortError)
        if ($attempt -lt $maxReferenceAttempts) {
          Write-Output "Reference request attempt $attempt failed for Excel row $($row.rowNumber): $shortError"
          Write-Output "Retrying with the same references."
          Start-Sleep -Seconds ([Math]::Min(15, 4 * $attempt))
        }
      }
    }
    if (-not $apiResult) {
      $primaryError = $referenceErrors -join " | "
      if (-not $AllowPromptOnlyFallback) {
        throw "Reference-image generation failed after $maxReferenceAttempts attempts for Excel row $($row.rowNumber); prompt-only fallback is disabled. Cause: $primaryError"
      }
      $apiResult = Invoke-ImageGeneration -Row $row -RawPath $rawPath -ResolvedApiKey $resolvedApiKey -ResolvedBaseUrl $resolvedBaseUrl -ResolvedModel $resolvedModel -TargetWidth $dimensions.width -TargetHeight $dimensions.height
      $apiResult.primaryError = $primaryError
    }
  }

  Save-TargetImage -InputPath $rawPath -OutputPath $finalPath -Width $dimensions.width -Height $dimensions.height
  $rawSize = Get-ImageSize -Path $rawPath
  $finalSize = Get-ImageSize -Path $finalPath

  $meta = @{
    index = $index
    imageNo = $row.imageNo
    imageType = $row.imageType
    linkOrder = $row.linkOrder
    role = $row.role
    sourceRowNumber = $row.rowNumber
    styleCode = $resolvedStyleCode
    rawPath = $rawPath
    finalPath = $finalPath
    rawSize = $rawSize
    finalSize = $finalSize
    api = $apiResult
    promptLength = ([string]$row.prompt).Length
    referencesUsed = $filteredRefs
    targetSize = $dimensions
    createdAt = (Get-Date).ToString("s")
  }
  $meta | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $metaPath
  [void]$results.Add($meta)
}

$longImageSummary = [PSCustomObject]@{
  enabled = -not $SkipMainLongImages
  count = 0
  finalDir = $null
  contactSheet = $null
  results = @()
  skippedGroups = @()
}
if (-not $SkipMainLongImages) {
  $longRun = Invoke-MainLongImages `
    -SquareResults @($results) `
    -LongRawDir $longRawDir `
    -LongFinalDir $longFinalDir `
    -MetaDir $metaDir `
    -ResolvedApiKey $resolvedApiKey `
    -ResolvedBaseUrl $resolvedBaseUrl `
    -ResolvedModel $resolvedModel
  $longContactSheet = $null
  if ($CreateContactSheets) {
    $longContactSheet = Join-Path $OutputDir "main_long_1440x1920_contact_sheet.png"
    Save-ContactSheet -FinalDir $longFinalDir -OutputPath $longContactSheet
  }
  $longImageSummary = [PSCustomObject]@{
    enabled = $true
    count = $longRun.count
    finalDir = if (Test-Path -LiteralPath $longFinalDir) { (Resolve-Path -LiteralPath $longFinalDir).Path } else { $longFinalDir }
    contactSheet = if ($longContactSheet -and (Test-Path -LiteralPath $longContactSheet)) { $longContactSheet } else { $null }
    results = $longRun.results
    skippedGroups = $longRun.skippedGroups
  }
}

$contactSheet = $null
if ($CreateContactSheets) {
  $contactSheet = Join-Path $OutputDir "generated_images_contact_sheet.png"
  Save-ContactSheet -FinalDir $finalDir -OutputPath $contactSheet
}

$deliveryDir = Join-Path $OutputDir "final_delivery"
$delivery = Copy-FinalImagesToDeliveryFolder -SourceDirs @($finalDir, $longFinalDir) -DeliveryDir $deliveryDir

$summary = @{
  workbookPath = (Resolve-Path -LiteralPath $WorkbookPath).Path
  sheetName = $data.sheetName
  requestedStartRow = $StartRow
  requestedEndRow = $EndRow
  outputDir = (Resolve-Path -LiteralPath $OutputDir).Path
  finalDir = (Resolve-Path -LiteralPath $finalDir).Path
  deliveryDir = $delivery.dir
  deliveryCount = $delivery.count
  contactSheet = $contactSheet
  baseUrl = $resolvedBaseUrl
  model = $resolvedModel
  defaultTargetSize = $TargetSize
  styleCode = $resolvedStyleCode
  count = $results.Count
  results = $results
  mainLongImages = $longImageSummary
  delivery = $delivery
}
$summaryPath = Join-Path $OutputDir "run_summary.json"
$summary | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 $summaryPath

$summaryView = [PSCustomObject]@{
  outputDir = $summary.outputDir
  finalDir = $summary.finalDir
  deliveryDir = $summary.deliveryDir
  deliveryCount = $summary.deliveryCount
  contactSheet = $summary.contactSheet
  baseUrl = $summary.baseUrl
  model = $summary.model
  sheetName = $summary.sheetName
  requestedStartRow = $summary.requestedStartRow
  requestedEndRow = $summary.requestedEndRow
  defaultTargetSize = $summary.defaultTargetSize
  count = $summary.count
  mainLongImages = @{
    enabled = $summary.mainLongImages.enabled
    count = $summary.mainLongImages.count
    finalDir = $summary.mainLongImages.finalDir
    contactSheet = $summary.mainLongImages.contactSheet
    skippedGroups = $summary.mainLongImages.skippedGroups
  }
}
Write-Output ($summaryView | ConvertTo-Json -Depth 4)
