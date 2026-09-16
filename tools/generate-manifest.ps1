param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = "Stop"

function Get-SHA256 {
    param([string]$Path)

    return (Get-FileHash $Path -Algorithm SHA256).Hash
}

function Get-AssetUrl {
    param(
        [string]$Repository,
        [string]$ReleaseTag,
        [string]$Asset
    )

    $encodedAsset = [System.Uri]::EscapeDataString($Asset)

    return "https://github.com/$Repository/releases/download/$ReleaseTag/$encodedAsset"
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

$assetsReportPath = Join-Path `
    $releaseRoot `
    "manifests\assets-report.csv"

$classificationPath = Join-Path `
    $releaseRoot `
    "manifests\classification-report.csv"

$outputPath = Join-Path `
    $releaseRoot `
    "manifests\client-$Version.json"

if (-not (Test-Path $assetsReportPath)) {
    throw "자산 보고서를 찾을 수 없습니다: $assetsReportPath"
}

if (-not (Test-Path $classificationPath)) {
    throw "분류 보고서를 찾을 수 없습니다: $classificationPath"
}

if (Test-Path $outputPath) {
    throw "매니페스트가 이미 존재합니다: $outputPath"
}

$assets = @(
    Import-Csv $assetsReportPath
)

$classifications = @(
    Import-Csv $classificationPath
)

if ($assets.Count -ne 124) {
    throw "배포 자산 수가 124개가 아닙니다: $($assets.Count)"
}

if ($classifications.Count -ne 918) {
    throw "분류 파일 수가 918개가 아닙니다: $($classifications.Count)"
}

$baseUrl = "https://github.com/$($config.repository)/releases/download/$releaseTag"

$fileEntries = @()
$bundleEntries = @()

$standaloneClassifications = @(
    $classifications |
        Where-Object Group -eq "standalone"
)

$standaloneAssetGroups = @(
    $assets |
        Where-Object {
            $_.Type -eq "file" -or
            $_.Type -eq "part"
        } |
        Group-Object SourcePath
)

foreach ($assetGroup in $standaloneAssetGroups) {
    $relativePath = [string]$assetGroup.Name
    $windowsPath = $relativePath.Replace("/", "\")
    $sourcePath = Join-Path $sourceRoot $windowsPath

    if (-not (Test-Path $sourcePath)) {
        throw "원본 파일이 없습니다: $sourcePath"
    }

    $sourceFile = Get-Item $sourcePath
    $sourceHash = Get-SHA256 $sourcePath

    $extension = [System.IO.Path]::GetExtension(
        $relativePath
    ).ToLowerInvariant()

    $atomicGroup = $null

    if ($extension -eq ".m2d" -or $extension -eq ".m2h") {
        $atomicGroup = $relativePath.Substring(
            0,
            $relativePath.Length - $extension.Length
        )
    }

    $groupAssets = @(
        $assetGroup.Group |
            Sort-Object Asset |
            ForEach-Object {
                [PSCustomObject][ordered]@{
                    name = [string]$_.Asset
                    size = [long]$_.Size
                    sha256 = [string]$_.SHA256
                    url = Get-AssetUrl `
                        -Repository $config.repository `
                        -ReleaseTag $releaseTag `
                        -Asset ([string]$_.Asset)
                }
            }
    )

    $delivery = if ($assetGroup.Group[0].Type -eq "part") {
        "parts"
    }
    else {
        "file"
    }

    $fileEntries += [PSCustomObject][ordered]@{
        path = $relativePath
        size = [long]$sourceFile.Length
        sha256 = $sourceHash
        delivery = $delivery
        atomicGroup = $atomicGroup
        assets = $groupAssets
    }
}

$bundleAssets = @(
    $assets |
        Where-Object Type -eq "bundle"
)

foreach ($bundleAsset in $bundleAssets) {
    $groupName = [string]$bundleAsset.SourcePath
    $bundleId = $groupName.Substring("bundle:".Length)

    $bundleFiles = @(
        $classifications |
            Where-Object Group -eq $groupName |
            Sort-Object Path
    )

    $manifestFiles = @()

    foreach ($record in $bundleFiles) {
        $relativePath = [string]$record.Path
        $sourcePath = Join-Path `
            $sourceRoot `
            $relativePath.Replace("/", "\")

        if (-not (Test-Path $sourcePath)) {
            throw "묶음 원본 파일이 없습니다: $sourcePath"
        }

        $installMode = "replace"

        foreach ($preservePath in $config.preserve) {
            if ($relativePath -ieq [string]$preservePath) {
                $installMode = "preserve"
                break
            }
        }

        foreach ($installIfMissingPath in $config.installIfMissing) {
            if ($relativePath -ieq [string]$installIfMissingPath) {
                $installMode = "ifMissing"
                break
            }
        }

        $manifestFiles += [PSCustomObject][ordered]@{
            path = $relativePath
            size = [long](Get-Item $sourcePath).Length
            sha256 = Get-SHA256 $sourcePath
            installMode = $installMode
        }
    }

    $bundleEntries += [PSCustomObject][ordered]@{
        id = $bundleId
        asset = [string]$bundleAsset.Asset
        size = [long]$bundleAsset.Size
        sha256 = [string]$bundleAsset.SHA256
        url = Get-AssetUrl `
            -Repository $config.repository `
            -ReleaseTag $releaseTag `
            -Asset ([string]$bundleAsset.Asset)
        files = $manifestFiles
    }
}

$manifestFileCount = (
    $fileEntries.Count +
    ($bundleEntries |
        ForEach-Object { $_.files.Count } |
        Measure-Object -Sum
    ).Sum
)

if ($manifestFileCount -ne 918) {
    throw "매니페스트 파일 수가 918개가 아닙니다: $manifestFileCount"
}

$totalInstalledBytes = (
    $classifications |
        Measure-Object Size -Sum
).Sum

$totalDownloadBytes = (
    $assets |
        Measure-Object Size -Sum
).Sum

$manifest = [PSCustomObject][ordered]@{
    schemaVersion = 1
    clientVersion = $Version
    releaseTag = $releaseTag
    repository = [string]$config.repository
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
    totalFileCount = [int]$manifestFileCount
    totalInstalledBytes = [long]$totalInstalledBytes
    totalDownloadBytes = [long]$totalDownloadBytes
    preserve = @($config.preserve)
    installIfMissing = @($config.installIfMissing)
    delete = @()
    files = @(
        $fileEntries |
            Sort-Object path
    )
    bundles = @(
        $bundleEntries |
            Sort-Object id
    )
}

$json = $manifest | ConvertTo-Json -Depth 12

[System.IO.File]::WriteAllText(
    $outputPath,
    $json,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Host ""
Write-Host "매니페스트 생성 완료"
Write-Host "버전: $Version"
Write-Host "Release 태그: $releaseTag"
Write-Host "설치 파일 수: $manifestFileCount"
Write-Host "독립 파일 항목: $($fileEntries.Count)"
Write-Host "ZIP 묶음: $($bundleEntries.Count)"
Write-Host "설치 용량: $([math]::Round($totalInstalledBytes / 1GB, 3)) GiB"
Write-Host "다운로드 용량: $([math]::Round($totalDownloadBytes / 1GB, 3)) GiB"
Write-Host "출력: $outputPath"