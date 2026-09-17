param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = "Stop"

$repository = "buggywhiletrue/client"
$tag = "client-v$Version"

$assetsRoot = Join-Path `
    "D:\Buggy_Distribution\build\$tag" `
    "assets"

if (-not (Test-Path -LiteralPath $assetsRoot)) {
    throw "자산 폴더를 찾을 수 없습니다: $assetsRoot"
}

$localAssets = @(
    Get-ChildItem `
        -LiteralPath $assetsRoot `
        -Recurse `
        -File |
        Sort-Object Name
)

$manifestPath = Join-Path `
    "D:\\Buggy_Distribution\\build\\$tag" `
    "manifests\\client-$Version.json"

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "매니페스트를 찾을 수 없습니다: $manifestPath"
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$expectedAssetNames = @()

foreach ($file in $manifest.files) {
    foreach ($asset in $file.assets) {
        $expectedAssetNames += [string]$asset.name
    }
}

foreach ($bundle in $manifest.bundles) {
    $expectedAssetNames += [string]$bundle.asset
}

if ($localAssets.Count -ne $expectedAssetNames.Count) {
    throw "로컬 자산 수와 매니페스트 자산 수가 다릅니다: $($localAssets.Count) / $($expectedAssetNames.Count)"
}

$duplicateNames = @(
    $localAssets |
        Group-Object Name |
        Where-Object Count -gt 1
)

if ($duplicateNames.Count -ne 0) {
    Write-Host "중복 자산 이름:"
    $duplicateNames | Select-Object Name, Count
    throw "GitHub Release에 같은 이름의 자산을 올릴 수 없습니다."
}

$release = gh release view $tag `
    --repo $repository `
    --json tagName,isDraft,assets |
    ConvertFrom-Json

if ($LASTEXITCODE -ne 0) {
    throw "GitHub Release 정보를 불러오지 못했습니다."
}

if (-not $release.isDraft) {
    throw "대상 Release가 초안 상태가 아닙니다."
}

$remoteNames = @(
    $release.assets |
        ForEach-Object {
            $_.name
        }
)

$totalBytes = (
    $localAssets |
        Measure-Object Length -Sum
).Sum

Write-Host ""
Write-Host "배포 자산 업로드 시작"
Write-Host "Release: $tag"
Write-Host "로컬 자산: $($localAssets.Count)개"
Write-Host "원격 자산: $($remoteNames.Count)개"
Write-Host "전체 용량: $([math]::Round($totalBytes / 1GB, 3)) GiB"
Write-Host ""

$uploaded = 0
$skipped = 0

for ($index = 0; $index -lt $localAssets.Count; $index++) {
    $file = $localAssets[$index]
    $number = $index + 1

    if ($remoteNames -contains $file.Name) {
        Write-Host `
            "[$number/$($localAssets.Count)] 건너뜀: $($file.Name)"

        $skipped++
        continue
    }

    $sizeMiB = [math]::Round(
        $file.Length / 1MB,
        2
    )

    Write-Host ""
    Write-Host `
        "[$number/$($localAssets.Count)] 업로드: $($file.Name) ($sizeMiB MiB)"

    gh release upload $tag `
        $file.FullName `
        --repo $repository

    if ($LASTEXITCODE -ne 0) {
        throw @"
업로드 실패: $($file.Name)
같은 명령을 다시 실행하면 완료된 자산을 건너뛰고 재개합니다.
"@
    }

    $uploaded++
}

Write-Host ""
Write-Host "업로드 작업 완료"
Write-Host "새로 업로드: $uploaded개"
Write-Host "기존 자산 건너뜀: $skipped개"
Write-Host ""