param(
    [string]$ConfigPath = "$PSScriptRoot\..\distribution.config.json"
)

$ErrorActionPreference = "Stop"

function Convert-ToRelativePath {
    param(
        [string]$Root,
        [string]$FullName
    )

    return $FullName.Substring($Root.Length).TrimStart("\")
}

function Convert-ToNormalizedPath {
    param([string]$Path)

    return $Path.Replace("\", "/")
}

function Test-PathPattern {
    param(
        [string]$Path,
        [string]$Pattern
    )

    $normalizedPath = Convert-ToNormalizedPath $Path
    $normalizedPattern = $Pattern.Replace("\", "/").Replace("**", "*")

    return $normalizedPath -like $normalizedPattern
}

function Test-ExcludedPath {
    param(
        [string]$Path,
        [object[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        if (Test-PathPattern $Path ([string]$pattern)) {
            return $true
        }
    }

    return $false
}

function Test-ForceIncludedPath {
    param(
        [string]$Path,
        [object[]]$Paths
    )

    $normalizedPath = Convert-ToNormalizedPath $Path

    foreach ($forceIncludedPath in $Paths) {
        $normalizedForceIncludedPath = Convert-ToNormalizedPath (
            [string]$forceIncludedPath
        )

        if ($normalizedPath -ieq $normalizedForceIncludedPath) {
            return $true
        }
    }

    return $false
}

if (-not (Test-Path $ConfigPath)) {
    throw "설정 파일을 찾을 수 없습니다: $ConfigPath"
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$sourceRoot = (Resolve-Path $config.sourceDirectory).Path.TrimEnd("\")
$buildRoot = [string]$config.buildDirectory

New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null

$allFiles = @(
    Get-ChildItem $sourceRoot -Recurse -File -ErrorAction Stop
)

$records = @()
$excludedRecords = @()

foreach ($file in $allFiles) {
    $relativePath = Convert-ToRelativePath $sourceRoot $file.FullName
    $normalizedPath = Convert-ToNormalizedPath $relativePath
    $extension = $file.Extension.ToLowerInvariant()

    $forceIncluded = Test-ForceIncludedPath `
        -Path $normalizedPath `
        -Paths @($config.forceInclude)

    if (
        -not $forceIncluded -and
        (Test-ExcludedPath $normalizedPath $config.exclude)
    ) {
        $excludedRecords += [PSCustomObject]@{
            Path = $normalizedPath
            Size = $file.Length
            Group = "excluded"
        }

        continue
    }

    $group = $null

    foreach ($standaloneFile in $config.standaloneFiles) {
        $normalizedStandalone = Convert-ToNormalizedPath ([string]$standaloneFile)

        if ($normalizedPath -ieq $normalizedStandalone) {
            $group = "standalone"
            break
        }
    }

    if (-not $group) {
        foreach ($standaloneExtension in $config.standaloneExtensions) {
            if ($extension -ieq [string]$standaloneExtension) {
                $group = "standalone"
                break
            }
        }
    }

    if (-not $group) {
        foreach ($bundle in $config.bundles) {
            $bundleSource = (
                Convert-ToNormalizedPath ([string]$bundle.source)
            ).TrimEnd("/")

            if (
                $normalizedPath -ieq $bundleSource -or
                $normalizedPath.StartsWith(
                    "$bundleSource/",
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                $bundleExcluded = $false
                $relativeInsideBundle = $normalizedPath.Substring(
                    $bundleSource.Length
                ).TrimStart("/")

                if ($bundle.PSObject.Properties.Name -contains "exclude") {
                    foreach ($bundlePattern in $bundle.exclude) {
                        if (
                            Test-PathPattern `
                                $relativeInsideBundle `
                                ([string]$bundlePattern)
                        ) {
                            $bundleExcluded = $true
                            break
                        }
                    }
                }

                if (-not $bundleExcluded) {
                    $group = "bundle:$($bundle.id)"
                    break
                }
            }
        }
    }

    if (-not $group -and $normalizedPath.StartsWith(
        "Data/",
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        $group = "bundle:data-support"
    }

    if (-not $group) {
        $group = "bundle:root-runtime"
    }

    $records += [PSCustomObject]@{
        Path = $normalizedPath
        Size = $file.Length
        Extension = $extension
        Group = $group
    }
}

$reportPath = Join-Path $buildRoot "classification-report.csv"
$excludedPath = Join-Path $buildRoot "excluded-files.csv"

$records |
    Sort-Object Group, Path |
    Export-Csv $reportPath -NoTypeInformation -Encoding UTF8

$excludedRecords |
    Sort-Object Path |
    Export-Csv $excludedPath -NoTypeInformation -Encoding UTF8

$classifiedBytes = ($records | Measure-Object Size -Sum).Sum
$excludedBytes = ($excludedRecords | Measure-Object Size -Sum).Sum

Write-Host ""
Write-Host "클라이언트 분류 완료"
Write-Host "원본 파일 수: $($allFiles.Count)"
Write-Host "배포 파일 수: $($records.Count)"
Write-Host "제외 파일 수: $($excludedRecords.Count)"
Write-Host "배포 용량: $([math]::Round($classifiedBytes / 1GB, 3)) GiB"
Write-Host "제외 용량: $([math]::Round($excludedBytes / 1MB, 3)) MiB"
Write-Host ""

$records |
    Group-Object Group |
    ForEach-Object {
        $size = ($_.Group | Measure-Object Size -Sum).Sum

        [PSCustomObject]@{
            Group = $_.Name
            Files = $_.Count
            SizeMiB = [math]::Round($size / 1MB, 3)
        }
    } |
    Sort-Object SizeMiB -Descending |
    Format-Table -AutoSize

Write-Host ""
Write-Host "분류 보고서: $reportPath"
Write-Host "제외 보고서: $excludedPath"