#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$TestRoot = 'C:\Users\Administrator\Desktop\스타서버ON,OF\스타ServerTest실행',
    [string]$ProductionRoot = 'C:\Users\Administrator\Desktop\스타서버on'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$PatchId = 'R197_AUTO_RANGED_SINGLE_ACTION_20260917'
$ControllerClass = 'l1j.server.AutoHuntSystem.AutoHuntController'

function FullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}
function Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}
function FindJavap() {
    foreach ($root in @(
        $env:JAVA_HOME,
        'C:\Program Files\Java\jdk1.8.0_202',
        'C:\Program Files\Java\jdk1.8.0_361'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique) {
        $candidate = Join-Path $root 'bin\javap.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    $command = Get-Command javap.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'JDK 8 javap.exe를 찾지 못했습니다.'
}
function ReadManifest([string]$Path) {
    $result = @{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }
        $index = $line.IndexOf('=')
        if ($index -le 0) { continue }
        $result[$line.Substring(0, $index)] = $line.Substring($index + 1)
    }
    return $result
}
function AssertTestServerStopped([string]$Root) {
    $running = @()
    try {
        $running = @(Get-CimInstance Win32_Process -Filter "Name='java.exe'" |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine.IndexOf($Root,
                    [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            })
    } catch {
        $running = @()
    }
    if ($running.Count -gt 0) {
        $details = ($running | ForEach-Object {
            "PID=$($_.ProcessId) $($_.CommandLine)"
        }) -join "`n"
        throw "테스트 서버 java.exe가 실행 중입니다. 정상 종료 후 다시 실행하십시오.`n$details"
    }
}

$TestRoot = FullPath $TestRoot
$ProductionRoot = FullPath $ProductionRoot
if ($TestRoot.StartsWith($ProductionRoot,
    [System.StringComparison]::OrdinalIgnoreCase)) {
    throw '운영 서버 폴더에는 적용할 수 없습니다.'
}

$testJar = Join-Path $TestRoot 'l1jserver.jar'
$productionJar = Join-Path $ProductionRoot 'l1jserver.jar'
if (-not (Test-Path -LiteralPath $testJar -PathType Leaf)) {
    throw "테스트 JAR 없음: $testJar"
}
AssertTestServerStopped $TestRoot

$productionBefore = if (Test-Path -LiteralPath $productionJar -PathType Leaf) {
    Sha256 $productionJar
} else { 'NOT_FOUND' }

$manifests = @(
    Get-ChildItem -LiteralPath $TestRoot -Recurse -File `
        -Filter 'R197_candidate_manifest.txt' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending
)
if ($manifests.Count -eq 0) {
    throw 'R197 후보 manifest를 찾지 못했습니다. 먼저 빌드 CMD를 실행하십시오.'
}

$manifestPath = $manifests[0].FullName
$manifest = ReadManifest $manifestPath
foreach ($key in @('patchId', 'candidateJar', 'candidateJarSha256')) {
    if (-not $manifest.ContainsKey($key)) {
        throw "manifest 필수 값 없음: $key"
    }
}
if ($manifest['patchId'] -ne $PatchId) {
    throw "다른 패치 manifest입니다: $($manifest['patchId'])"
}
$candidateJar = $manifest['candidateJar']
$expectedHash = $manifest['candidateJarSha256'].ToUpperInvariant()
if (-not (Test-Path -LiteralPath $candidateJar -PathType Leaf)) {
    throw "후보 JAR 없음: $candidateJar"
}
$actualHash = Sha256 $candidateJar
if ($actualHash -ne $expectedHash) {
    throw "후보 JAR 해시 불일치: expected=$expectedHash actual=$actualHash"
}

$javap = FindJavap
$javapOutput = @(& $javap -classpath $candidateJar -p -constants `
    $ControllerClass 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
if ($LASTEXITCODE -ne 0 -or
    -not $javapOutput.Contains('AUTO_RANGED_SINGLE_ACTION_VERSION') -or
    -not $javapOutput.Contains('R197')) {
    throw '후보 JAR의 R197 CLASS 표식 검증에 실패했습니다.'
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupDir = Join-Path $TestRoot `
    ('deployment_backups\R197_AUTO_RANGED_SINGLE_ACTION_' + $stamp)
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$backupJar = Join-Path $backupDir 'l1jserver_pre_R197.jar'
Copy-Item -LiteralPath $testJar -Destination $backupJar -Force
$backupHash = Sha256 $backupJar

$tempJar = Join-Path $TestRoot ('l1jserver.R197.' + $stamp + '.tmp')
$atomicBackup = Join-Path $backupDir 'l1jserver_pre_R197.atomic.jar'
Copy-Item -LiteralPath $candidateJar -Destination $tempJar -Force
if ((Sha256 $tempJar) -ne $expectedHash) {
    Remove-Item -LiteralPath $tempJar -Force -ErrorAction SilentlyContinue
    throw '원자 교체 직전 임시 JAR 해시 검증에 실패했습니다.'
}

try {
    [System.IO.File]::Replace($tempJar, $testJar, $atomicBackup, $true)
} catch {
    Remove-Item -LiteralPath $tempJar -Force -ErrorAction SilentlyContinue
    throw
}

$appliedHash = Sha256 $testJar
if ($appliedHash -ne $expectedHash) {
    Copy-Item -LiteralPath $backupJar -Destination $testJar -Force
    throw '적용 후 테스트 JAR 해시가 달라 원본으로 자동 복구했습니다.'
}

$productionAfter = if (Test-Path -LiteralPath $productionJar -PathType Leaf) {
    Sha256 $productionJar
} else { 'NOT_FOUND' }
if ($productionAfter -ne $productionBefore) {
    Copy-Item -LiteralPath $backupJar -Destination $testJar -Force
    throw '작업 중 운영 JAR 해시가 외부에서 변경됐습니다. 테스트 JAR을 원복했습니다.'
}

$applyManifest = Join-Path $backupDir 'R197_적용기록.txt'
[System.IO.File]::WriteAllLines($applyManifest, @(
    "patchId=$PatchId",
    "applied=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "testJar=$testJar",
    "testJarSha256Before=$backupHash",
    "testJarSha256After=$appliedHash",
    "candidateJar=$candidateJar",
    "candidateManifest=$manifestPath",
    "backupJar=$backupJar",
    "atomicBackup=$atomicBackup",
    "productionJar=$productionJar",
    "productionJarSha256Before=$productionBefore",
    "productionJarSha256After=$productionAfter",
    'productionJarModified=NO',
    'result=PASS'
), $Utf8Bom)

Write-Host ''
Write-Host '=================================================================='
Write-Host '[R197 테스트 서버 적용 완료]'
Write-Host "테스트 JAR : $testJar"
Write-Host "적용 SHA256 : $appliedHash"
Write-Host "원본 백업    : $backupJar"
Write-Host "적용 기록    : $applyManifest"
Write-Host '운영 JAR     : 변경하지 않음'
Write-Host '=================================================================='
