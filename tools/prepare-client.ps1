param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = "Stop"

function Get-SHA256 {
    param([string]$Path)

    return (Get-FileHash $Path -Algorithm SHA256).Hash
}

function Get-AssetName {
    param([string]$RelativePath)

    return $RelativePath.Replace("\", "__").Replace("/", "__")
}

function Copy-WithStructure {
    param(
        [string]$SourceRoot,
        [string]$RelativePath,
        [string]$DestinationRoot
    )

    $windowsPath = $RelativePath.Replace("/", "\")
    $source = Join-Path $SourceRoot $windowsPath
    $destination = Join-Path $DestinationRoot $windowsPath
    $destinationDirectory = Split-Path $destination -Parent

    New-Item -ItemType Directory `
        -Path $destinationDirectory `
        -Force | Out-Null

    Copy-Item $source $destination
}

function Split-LargeFile {
    param(
        [string]$Source,
        [string]$DestinationDirectory,
        [string]$AssetBaseName,
        [long]$PartSize
    )

    $parts = @()
    $inputStream = [System.IO.File]::OpenRead($Source)

    try {
        $partNumber = 1
        $buffer = New-Object byte[] (4MB)

        while ($inputStream.Position -lt $inputStream.Length) {
            $partName = "{0}.part{1:D3}" -f $AssetBaseName, $partNumber
            $partPath = Join-Path $DestinationDirectory $partName
            $outputStream = [System.IO.File]::Create($partPath)

            try {
                [long]$written = 0

                while (
                    $written -lt $PartSize -and
                    $inputStream.Position -lt $inputStream.Length
                ) {
                    [long]$remaining = $PartSize - $written
                    $requested = [int][Math]::Min(
                        $buffer.Length,
                        $remaining
                    )

                    $read = $inputStream.Read(
                        $buffer,
                        0,
                        $requested
                    )

                    if ($read -le 0) {
                        break
                    }

                    $outputStream.Write($buffer, 0, $read)
                    $written += $read
                }
            }
            finally {
                $outputStream.Dispose()
            }

            $partFile = Get-Item $partPath

            $parts += [PSCustomObject]@{
                Asset = $partName
                Size = $partFile.Length
                SHA256 = Get-SHA256 $partPath
            }

            $partNumber++
        }
    }
    finally {
        $inputStream.Dispose()
    }

    return $parts
}

$configPath = Join-Path $PSScriptRoot "..\distribution.config.json"
$configPath = [System.IO.Path]::GetFullPath($configPath)

if (-not (Test-Path $configPath)) {
    throw "설정 파일을 찾을 수 없습니다: $configPath"
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json
$sourceRoot = (Resolve-Path $config.sourceDirectory).Path.TrimEnd("\")

$releaseTag = "$($config.releaseTagPrefix)$Version"
$releaseRoot = Join-Path $config.buildDirectory $releaseTag

$packsDirectory = Join-Path $releaseRoot "assets\packs"
$bundlesDirectory = Join-Path $releaseRoot "assets\bundles"
$manifestsDirectory = Join-Path $releaseRoot "manifests"
$stagingDirectory = Join-Path $releaseRoot "staging"

$classificationPath = Join-Path `
    $manifestsDirectory `
    "classification-report.csv"

if (-not (Test-Path $classificationPath)) {
    throw "분류 보고서를 찾을 수 없습니다: $classificationPath"
}

New-Item -ItemType Directory -Path $packsDirectory -Force |
    Out-Null

New-Item -ItemType Directory -Path $bundlesDirectory -Force |
    Out-Null

New-Item -ItemType Directory -Path $stagingDirectory -Force |
    Out-Null

$existingAssets = @(
    Get-ChildItem $packsDirectory, $bundlesDirectory `
        -File `
        -ErrorAction SilentlyContinue
)

if ($existingAssets.Count -gt 0) {
    throw "assets 폴더가 비어 있지 않습니다. 기존 결과물을 덮어쓰지 않습니다."
}

$records = @(
    Import-Csv $classificationPath
)

if ($records.Count -ne 918) {
    throw "배포 파일 수가 918개가 아닙니다: $($records.Count)"
}

$assetReport = @()
$usedAssetNames = @{}

Write-Host ""
Write-Host "독립 파일 처리 시작"

$standaloneRecords = @(
    $records | Where-Object Group -eq "standalone"
)

for ($i = 0; $i -lt $standaloneRecords.Count; $i++) {
    $record = $standaloneRecords[$i]
    $relativePath = [string]$record.Path
    $sourcePath = Join-Path `
        $sourceRoot `
        $relativePath.Replace("/", "\")

    if (-not (Test-Path $sourcePath)) {
        throw "원본 파일을 찾을 수 없습니다: $sourcePath"
    }

    $sourceFile = Get-Item $sourcePath
    $assetBaseName = Get-AssetName $relativePath

    Write-Progress `
        -Activity "독립 파일 처리" `
        -Status "$($i + 1) / $($standaloneRecords.Count): $relativePath" `
        -PercentComplete ((($i + 1) / $standaloneRecords.Count) * 100)

    if ($sourceFile.Length -ge [long]$config.splitThresholdBytes) {
        $parts = Split-LargeFile `
            -Source $sourcePath `
            -DestinationDirectory $packsDirectory `
            -AssetBaseName $assetBaseName `
            -PartSize ([long]$config.partSizeBytes)

        foreach ($part in $parts) {
            if ($usedAssetNames.ContainsKey($part.Asset)) {
                throw "자산 이름 충돌: $($part.Asset)"
            }

            $usedAssetNames[$part.Asset] = $true

            $assetReport += [PSCustomObject]@{
                Type = "part"
                SourcePath = $relativePath
                Asset = $part.Asset
                Size = $part.Size
                SHA256 = $part.SHA256
                SourceSHA256 = Get-SHA256 $sourcePath
            }
        }
    }
    else {
        if ($usedAssetNames.ContainsKey($assetBaseName)) {
            throw "자산 이름 충돌: $assetBaseName"
        }

        $usedAssetNames[$assetBaseName] = $true
        $destinationPath = Join-Path $packsDirectory $assetBaseName

        Copy-Item $sourcePath $destinationPath

        $assetReport += [PSCustomObject]@{
            Type = "file"
            SourcePath = $relativePath
            Asset = $assetBaseName
            Size = $sourceFile.Length
            SHA256 = Get-SHA256 $destinationPath
            SourceSHA256 = Get-SHA256 $sourcePath
        }
    }
}

Write-Progress -Activity "독립 파일 처리" -Completed

Write-Host ""
Write-Host "ZIP 묶음 생성 시작"

$bundleGroups = @(
    $records |
        Where-Object { $_.Group -like "bundle:*" } |
        Group-Object Group
)

foreach ($bundleGroup in $bundleGroups) {
    $bundleId = $bundleGroup.Name.Substring("bundle:".Length)
    $bundleStage = Join-Path $stagingDirectory $bundleId
    $bundlePath = Join-Path $bundlesDirectory "$bundleId.zip"

    if (Test-Path $bundleStage) {
        throw "staging 폴더가 이미 존재합니다: $bundleStage"
    }

    if (Test-Path $bundlePath) {
        throw "ZIP 파일이 이미 존재합니다: $bundlePath"
    }

    New-Item -ItemType Directory -Path $bundleStage -Force |
        Out-Null

    Write-Host "묶음 준비: $bundleId ($($bundleGroup.Count)개 파일)"

    foreach ($record in $bundleGroup.Group) {
        Copy-WithStructure `
            -SourceRoot $sourceRoot `
            -RelativePath ([string]$record.Path) `
            -DestinationRoot $bundleStage
    }

    Compress-Archive `
        -Path "$bundleStage\*" `
        -DestinationPath $bundlePath `
        -CompressionLevel Optimal

    $bundleFile = Get-Item $bundlePath

    $assetReport += [PSCustomObject]@{
        Type = "bundle"
        SourcePath = $bundleGroup.Name
        Asset = $bundleFile.Name
        Size = $bundleFile.Length
        SHA256 = Get-SHA256 $bundlePath
        SourceSHA256 = ""
    }
}

$reportPath = Join-Path $manifestsDirectory "assets-report.csv"

$assetReport |
    Sort-Object Type, Asset |
    Export-Csv $reportPath -NoTypeInformation -Encoding UTF8

$totalAssetBytes = (
    $assetReport |
        Measure-Object Size -Sum
).Sum

Write-Host ""
Write-Host "배포 자산 생성 완료"
Write-Host "자산 수: $($assetReport.Count)"
Write-Host "자산 용량: $([math]::Round($totalAssetBytes / 1GB, 3)) GiB"
Write-Host "보고서: $reportPath"
Write-Host ""
Write-Host "원본 클라이언트는 수정되지 않았습니다."