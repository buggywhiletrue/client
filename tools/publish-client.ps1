param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^\d+\.\d+\.\d+$")]
    [string]$Version,
    [switch]$Publish
)

$ErrorActionPreference = "Stop"

function Invoke-CheckedScript {
    param([string]$Path, [string[]]$Arguments = @())
    & $Path @Arguments
    if ($LASTEXITCODE -ne 0) { throw "스크립트 실행 실패: $Path" }
}

function Invoke-Git {
    param([string[]]$Arguments)
    & git -C $script:repositoryRoot @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Git 명령 실패: git $($Arguments -join ' ')"
    }
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$configPath = Join-Path $repositoryRoot "distribution.config.json"
if (-not (Test-Path $configPath)) { throw "설정 파일 없음: $configPath" }

$config = Get-Content $configPath -Raw | ConvertFrom-Json
$repository = [string]$config.repository
$tag = "$($config.releaseTagPrefix)$Version"
$releaseRoot = Join-Path $config.buildDirectory $tag
$manifestDirectory = Join-Path $releaseRoot "manifests"
$manifestPath = Join-Path $manifestDirectory "client-$Version.json"
$repositoryManifestDirectory = Join-Path $repositoryRoot "manifests"
$repositoryManifestPath = Join-Path $repositoryManifestDirectory "client-$Version.json"

$analyzeScript = Join-Path $PSScriptRoot "analyze-client.ps1"
$prepareScript = Join-Path $PSScriptRoot "prepare-client.ps1"
$generateScript = Join-Path $PSScriptRoot "generate-manifest.ps1"
$uploadScript = Join-Path $PSScriptRoot "upload-release-assets.ps1"

foreach ($path in @($analyzeScript, $prepareScript, $generateScript, $uploadScript)) {
    if (-not (Test-Path $path)) { throw "필수 스크립트 없음: $path" }
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Git 없음" }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI 없음" }
$null = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) { throw "gh auth login이 필요합니다." }

$changes = @(git -C $repositoryRoot status --porcelain)
if ($changes.Count -ne 0) {
    $changes | ForEach-Object { Write-Host $_ }
    throw "자동 배포 전에 Git 작업 폴더를 정리하세요."
}

Write-Host ""
Write-Host "배포 자동화 시작: $Version ($tag)"

if (-not (Test-Path $manifestPath)) {
    if (Test-Path $releaseRoot) {
        $existing = @(Get-ChildItem $releaseRoot -Recurse -File -ErrorAction SilentlyContinue)
        if ($existing.Count -ne 0) {
            throw "완성되지 않은 빌드 폴더를 자동 삭제하지 않습니다: $releaseRoot"
        }
    }

    Write-Host "[1/7] 파일 분석"
    Invoke-CheckedScript $analyzeScript
    New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    Copy-Item (Join-Path $config.buildDirectory "classification-report.csv") `
        (Join-Path $manifestDirectory "classification-report.csv") -Force
    Copy-Item (Join-Path $config.buildDirectory "excluded-files.csv") `
        (Join-Path $manifestDirectory "excluded-files.csv") -Force

    Write-Host "[2/7] 자산 생성"
    Invoke-CheckedScript $prepareScript @("-Version", $Version)
    Write-Host "[3/7] 매니페스트 생성"
    Invoke-CheckedScript $generateScript @("-Version", $Version)
}
else {
    Write-Host "[1-3/7] 기존 빌드 재사용: $manifestPath"
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$expectedAssets = @()
foreach ($file in $manifest.files) {
    foreach ($asset in $file.assets) {
        $expectedAssets += [PSCustomObject]@{
            name=[string]$asset.name; size=[long]$asset.size
            sha256=[string]$asset.sha256; url=[string]$asset.url
        }
    }
}
foreach ($bundle in $manifest.bundles) {
    $expectedAssets += [PSCustomObject]@{
        name=[string]$bundle.asset; size=[long]$bundle.size
        sha256=[string]$bundle.sha256; url=[string]$bundle.url
    }
}

$localAssets = @(Get-ChildItem (Join-Path $releaseRoot "assets") -Recurse -File)
if ($localAssets.Count -ne $expectedAssets.Count) {
    throw "로컬/매니페스트 자산 수 불일치: $($localAssets.Count) / $($expectedAssets.Count)"
}

New-Item -ItemType Directory -Path $repositoryManifestDirectory -Force | Out-Null
Copy-Item $manifestPath $repositoryManifestPath -Force
Invoke-Git @("add", "--", "manifests/client-$Version.json")
& git -C $repositoryRoot diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    Invoke-Git @("commit", "-m", "Add client $Version distribution manifest")
    Invoke-Git @("push", "origin", "main")
}

Write-Host "[4/7] 초안 Release 확인"
$null = gh release view $tag --repo $repository 2>$null
if ($LASTEXITCODE -ne 0) {
    gh release create $tag --repo $repository --target main `
        --title "Buggy Client $Version" `
        --notes "Buggy Client $Version distribution release." --draft
    if ($LASTEXITCODE -ne 0) { throw "초안 Release 생성 실패" }
}

$releaseInfo = gh release view $tag --repo $repository `
    --json databaseId,tagName,isDraft,isPrerelease,url | ConvertFrom-Json
if ($releaseInfo.isDraft) {
    Write-Host "[5/7] 누락 자산 업로드"
    Invoke-CheckedScript $uploadScript @("-Version", $Version)
}
elseif (-not $Publish) {
    throw "이미 공개된 Release입니다: $tag"
}

Write-Host "[6/7] 원격 자산 검증"
$releaseInfo = gh release view $tag --repo $repository `
    --json databaseId,tagName,isDraft,isPrerelease,url | ConvertFrom-Json
$remoteAssets = @(
    gh api --paginate `
        "repos/$repository/releases/$($releaseInfo.databaseId)/assets?per_page=100" `
        --jq ".[]" | ConvertFrom-Json
)

$expectedByName = @{}
foreach ($asset in $expectedAssets) { $expectedByName[$asset.name] = $asset }
$remoteByName = @{}
foreach ($asset in $remoteAssets) {
    if ([string]::IsNullOrWhiteSpace([string]$asset.name)) {
        throw "이름 없는 원격 자산 발견"
    }
    $remoteByName[[string]$asset.name] = $asset
}

$validationErrors = @()
foreach ($expected in $expectedAssets) {
    if (-not $remoteByName.ContainsKey($expected.name)) {
        $validationErrors += "누락: $($expected.name)"; continue
    }
    $remote = $remoteByName[$expected.name]
    if ([long]$remote.size -ne $expected.size) {
        $validationErrors += "크기 불일치: $($expected.name)"
    }
    if ([string]$remote.state -ne "uploaded") {
        $validationErrors += "상태 오류: $($expected.name)"
    }
    if ([string]::IsNullOrWhiteSpace([string]$remote.digest)) {
        $validationErrors += "SHA-256 없음: $($expected.name)"
    }
    else {
        $remoteHash = ([string]$remote.digest) -replace "^sha256:", ""
        if ($remoteHash -ne $expected.sha256) {
            $validationErrors += "SHA-256 불일치: $($expected.name)"
        }
    }
}
foreach ($remote in $remoteAssets) {
    if (-not $expectedByName.ContainsKey([string]$remote.name)) {
        $validationErrors += "예상하지 않은 자산: $($remote.name)"
    }
}
if ($validationErrors.Count -ne 0) {
    $validationErrors | ForEach-Object { Write-Host "- $_" }
    throw "원격 자산 검증 실패"
}
Write-Host "원격 자산 검증 통과: $($remoteAssets.Count)개"

if (-not $Publish) {
    Write-Host ""
    Write-Host "초안 업로드와 검증 완료"
    $publishCommand = '.\tools\publish-client.ps1 -Version "{0}" -Publish' -f $Version
    Write-Host $publishCommand
    exit 0
}

if ($releaseInfo.isDraft) {
    $confirmation = Read-Host "공개하려면 버전 $Version 을 입력하세요"
    if ($confirmation -ne $Version) { throw "공개 취소" }
    gh release edit $tag --repo $repository --target main --draft=false --latest
    if ($LASTEXITCODE -ne 0) { throw "Release 공개 실패" }
}

Write-Host "[7/7] 공개 시험 및 latest.json 갱신"
$smallestAsset = $expectedAssets | Sort-Object size | Select-Object -First 1
$temporaryDownload = Join-Path ([IO.Path]::GetTempPath()) $smallestAsset.name
try {
    Invoke-WebRequest $smallestAsset.url -OutFile $temporaryDownload -UseBasicParsing
    $downloadHash = (Get-FileHash $temporaryDownload -Algorithm SHA256).Hash
    if ($downloadHash -ne $smallestAsset.sha256) {
        throw "공개 다운로드 SHA-256 불일치"
    }
}
finally {
    if (Test-Path $temporaryDownload) { Remove-Item $temporaryDownload -Force }
}

$published = gh release view $tag --repo $repository `
    --json url,publishedAt | ConvertFrom-Json
$manifestFile = Get-Item $repositoryManifestPath
$manifestHash = (Get-FileHash $repositoryManifestPath -Algorithm SHA256).Hash
$manifestUrl = "https://raw.githubusercontent.com/" +
    $repository +
    "/main/manifests/client-" +
    $Version +
    ".json"
$latest = [ordered]@{
    schemaVersion = 1
    clientVersion = $Version
    releaseTag = $tag
    manifest = [ordered]@{
        url = $manifestUrl
        size = [long]$manifestFile.Length
        sha256 = $manifestHash
    }
    releaseUrl = [string]$published.url
    generatedAt = [string]$published.publishedAt
}
[IO.File]::WriteAllText(
    (Join-Path $repositoryRoot "latest.json"),
    ($latest | ConvertTo-Json -Depth 10),
    (New-Object Text.UTF8Encoding($false))
)

$readmePath = Join-Path $repositoryRoot "README.md"
if (Test-Path $readmePath) {
    $backtickCharacter = [char]96
    $readmeLines = @(Get-Content $readmePath)

    for ($lineIndex = 0; $lineIndex -lt $readmeLines.Count; $lineIndex++) {
        if ($readmeLines[$lineIndex].StartsWith("- 클라이언트 버전:")) {
            $readmeLines[$lineIndex] = "- 클라이언트 버전: " +
                $backtickCharacter + $Version + $backtickCharacter
        }

        if ($readmeLines[$lineIndex].StartsWith("- Client version:")) {
            $readmeLines[$lineIndex] = "- Client version: " +
                $backtickCharacter + $Version + $backtickCharacter
        }
    }

    $readme = $readmeLines -join [Environment]::NewLine
    $readme += [Environment]::NewLine
    [IO.File]::WriteAllText(
        $readmePath, $readme, (New-Object Text.UTF8Encoding($false))
    )
}

Invoke-Git @("add", "--", "latest.json", "README.md")
& git -C $repositoryRoot diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    Invoke-Git @("commit", "-m", "Publish client $Version update metadata")
    Invoke-Git @("push", "origin", "main")
}

Write-Host ""
Write-Host "클라이언트 $Version 공개 배포 완료"
Write-Host "Release: $($published.url)"
