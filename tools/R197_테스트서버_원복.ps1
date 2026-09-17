#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$TestRoot = 'C:\Users\Administrator\Desktop\스타서버ON,OF\스타ServerTest실행',
    [string]$ProductionRoot = 'C:\Users\Administrator\Desktop\스타서버on'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)

function FullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}
function Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
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
        throw '테스트 서버 java.exe가 실행 중입니다. 정상 종료 후 원복하십시오.'
    }
}

$TestRoot = FullPath $TestRoot
$ProductionRoot = FullPath $ProductionRoot
if ($TestRoot.StartsWith($ProductionRoot,
    [System.StringComparison]::OrdinalIgnoreCase)) {
    throw '운영 서버 폴더에는 원복 작업을 실행할 수 없습니다.'
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

$backups = @(
    Get-ChildItem -LiteralPath (Join-Path $TestRoot 'deployment_backups') `
        -Recurse -File -Filter 'l1jserver_pre_R197.jar' `
        -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending
)
if ($backups.Count -eq 0) {
    throw 'R197 적용 전 테스트 JAR 백업을 찾지 못했습니다.'
}

$backupJar = $backups[0].FullName
$backupHash = Sha256 $backupJar
$currentHash = Sha256 $testJar
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$safetyDir = Join-Path $TestRoot `
    ('deployment_backups\R197_ROLLBACK_' + $stamp)
New-Item -ItemType Directory -Force -Path $safetyDir | Out-Null
$currentBackup = Join-Path $safetyDir 'l1jserver_before_R197_rollback.jar'
Copy-Item -LiteralPath $testJar -Destination $currentBackup -Force

$tempJar = Join-Path $TestRoot ('l1jserver.R197.rollback.' + $stamp + '.tmp')
$atomicBackup = Join-Path $safetyDir 'l1jserver_before_R197_rollback.atomic.jar'
Copy-Item -LiteralPath $backupJar -Destination $tempJar -Force
if ((Sha256 $tempJar) -ne $backupHash) {
    Remove-Item -LiteralPath $tempJar -Force -ErrorAction SilentlyContinue
    throw '원복 임시 JAR 해시 검증 실패'
}

try {
    [System.IO.File]::Replace($tempJar, $testJar, $atomicBackup, $true)
} catch {
    Remove-Item -LiteralPath $tempJar -Force -ErrorAction SilentlyContinue
    throw
}

$restoredHash = Sha256 $testJar
if ($restoredHash -ne $backupHash) {
    Copy-Item -LiteralPath $currentBackup -Destination $testJar -Force
    throw '원복 후 해시 불일치로 원복 직전 JAR을 다시 복구했습니다.'
}

$productionAfter = if (Test-Path -LiteralPath $productionJar -PathType Leaf) {
    Sha256 $productionJar
} else { 'NOT_FOUND' }
if ($productionAfter -ne $productionBefore) {
    throw '원복 작업 중 운영 JAR이 외부에서 변경됐습니다. 운영 JAR은 건드리지 않았습니다.'
}

$record = Join-Path $safetyDir 'R197_원복기록.txt'
[System.IO.File]::WriteAllLines($record, @(
    "rolledBack=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "testJar=$testJar",
    "testJarSha256Before=$currentHash",
    "testJarSha256After=$restoredHash",
    "restoredFrom=$backupJar",
    "rollbackSafetyBackup=$currentBackup",
    "productionJar=$productionJar",
    "productionJarSha256Before=$productionBefore",
    "productionJarSha256After=$productionAfter",
    'productionJarModified=NO',
    'result=PASS'
), $Utf8Bom)

Write-Host ''
Write-Host '=================================================================='
Write-Host '[R197 테스트 서버 원복 완료]'
Write-Host "복구 JAR : $testJar"
Write-Host "복구 SHA : $restoredHash"
Write-Host "원복 기록: $record"
Write-Host '운영 JAR  : 변경하지 않음'
Write-Host '=================================================================='
