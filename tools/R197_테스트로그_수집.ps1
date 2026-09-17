#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$TestRoot = 'C:\Users\Administrator\Desktop\스타서버ON,OF\스타ServerTest실행'
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
function CopyIfPresent([string]$Source, [string]$Destination) {
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        return $true
    }
    return $false
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
    return $null
}

$TestRoot = FullPath $TestRoot
$testJar = Join-Path $TestRoot 'l1jserver.jar'
if (-not (Test-Path -LiteralPath $testJar -PathType Leaf)) {
    throw "테스트 JAR 없음: $testJar"
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$desktop = [Environment]::GetFolderPath('Desktop')
$outDir = Join-Path $desktop ('R197_자동사냥전투_테스트로그_' + $stamp)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('==================================================================')
$summary.Add('[R197 자동사냥 원거리/법사 전투 테스트 수집]')
$summary.Add('==================================================================')
$summary.Add("수집시각=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$summary.Add("테스트경로=$TestRoot")
$summary.Add("테스트JAR=$testJar")
$summary.Add("테스트JAR_SHA256=$(Sha256 $testJar)")
$summary.Add('')

$javap = FindJavap
if ($javap) {
    $classText = @(& $javap -classpath $testJar -p -constants `
        'l1j.server.AutoHuntSystem.AutoHuntController' 2>&1 |
        ForEach-Object { $_.ToString() }) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $outDir 'AutoHuntController_javap.txt'),
        $classText + "`n", $Utf8Bom)
    $r197 = $classText.Contains('AUTO_RANGED_SINGLE_ACTION_VERSION') -and
        $classText.Contains('R197')
    $summary.Add("R197_CLASS_MARKER=$r197")
} else {
    $summary.Add('R197_CLASS_MARKER=UNKNOWN_JAVAP_NOT_FOUND')
}

$processes = @()
try {
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='java.exe'" |
        Select-Object ProcessId, CreationDate, CommandLine)
} catch {}
$summary.Add("java_process_count=$($processes.Count)")
if ($processes.Count -gt 0) {
    $processes | Format-List * | Out-String |
        Set-Content -LiteralPath (Join-Path $outDir 'java_processes.txt') `
            -Encoding UTF8
}

$copied = New-Object System.Collections.Generic.List[string]
$targets = @(
    @{ Path = 'logs\star_auto_visual_trace.csv'; Name = 'star_auto_visual_trace.csv' },
    @{ Path = 'logs\star_cmd_detail.log'; Name = 'star_cmd_detail.log' },
    @{ Path = 'logs\star_diagnostic_detail.log'; Name = 'star_diagnostic_detail.log' },
    @{ Path = 'logs\star_room_minute.log'; Name = 'star_room_minute.log' },
    @{ Path = 'log\startup-fatal.log'; Name = 'startup-fatal.log' }
)
foreach ($target in $targets) {
    $source = Join-Path $TestRoot $target.Path
    $dest = Join-Path $outDir $target.Name
    if (CopyIfPresent $source $dest) {
        $copied.Add($target.Name)
    }
}

$latestCmd = @(
    Get-ChildItem -LiteralPath (Join-Path $TestRoot 'LogDB') -Recurse -File `
        -Filter 'CMD.txt' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending
) | Select-Object -First 1
if ($latestCmd) {
    Copy-Item -LiteralPath $latestCmd.FullName `
        -Destination (Join-Path $outDir 'latest_CMD.txt') -Force
    $copied.Add('latest_CMD.txt')
    $summary.Add("latest_CMD_source=$($latestCmd.FullName)")
}

$sourceLogs = @(
    Join-Path $TestRoot 'logs\star_auto_visual_trace.csv',
    Join-Path $TestRoot 'logs\star_cmd_detail.log',
    Join-Path $TestRoot 'logs\star_diagnostic_detail.log'
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }

$patterns = @(
    'ATTACK_PRECHECK',
    'ATTACK_ISSUED',
    'ATTACK_RESULT',
    'MONSTER_DAMAGE',
    'TRIPLE_ARROW',
    'WIZARD',
    'dead_target',
    'stale_target',
    'unknown_object',
    'STAR_AUTO',
    'Exception',
    'IllegalStateException',
    'NullPointerException',
    'ERROR'
)
$filteredPath = Join-Path $outDir 'R197_전투핵심_최근로그.txt'
foreach ($log in $sourceLogs) {
    Add-Content -LiteralPath $filteredPath -Encoding UTF8 `
        -Value ("`r`n===== " + $log + " =====")
    Get-Content -LiteralPath $log -Tail 200000 -ErrorAction SilentlyContinue |
        Select-String -SimpleMatch -Pattern $patterns |
        ForEach-Object { $_.Line } |
        Add-Content -LiteralPath $filteredPath -Encoding UTF8
}

$checklist = @'
[R197 테스트 기록표]

1. 요정 활 + 트리플
- 기본 활질과 트리플이 같은 한 슬롯에서 겹침: 예 / 아니오
- 죽은 몬스터에 트리플 또는 활질 지속: 예 / 아니오
- 왼쪽을 보며 오른쪽 대상에 피해처럼 보임: 예 / 아니오
- 화면에 몬스터가 없는데 활질: 예 / 아니오

2. 법사
- 기본 지팡이 공격과 공격마법이 같은 슬롯에서 겹침: 예 / 아니오
- 죽은 몬스터에 마법 지속: 예 / 아니오
- 이전 타깃 마법이 다음 타깃 전환 뒤 밀려 나옴: 예 / 아니오
- 화면에 몬스터가 없는데 마법: 예 / 아니오

3. 공통
- 공격속도가 수동 캐릭터보다 빨라 보임: 예 / 아니오
- 이동 중 공격 애니메이션 겹침: 예 / 아니오
- 몬스터 사망 후 다음 타깃 첫 공격이 이전 모션과 겹침: 예 / 아니오
- 접속 종료/서버 오류/새 예외: 예 / 아니오

테스트 캐릭터명:
테스트 맵:
테스트 시작시각:
테스트 종료시각:
영상 파일명:
특이사항:
'@
[System.IO.File]::WriteAllText(
    (Join-Path $outDir 'R197_테스트기록표.txt'),
    $checklist, $Utf8Bom)

$summary.Add("copied_files=$($copied -join ',')")
$summary.Add("filtered_log=$filteredPath")
$summary.Add('')
$summary.Add('[합격 기준]')
$summary.Add('요정 한 슬롯: 트리플 또는 기본 활질 중 1개')
$summary.Add('법사 한 슬롯: 공격마법 또는 기본공격 중 1개')
$summary.Add('사망/다른 맵/월드 정본 불일치/미인식 대상 공격 0건')
$summary.Add('운영 JAR 변경 0건')
[System.IO.File]::WriteAllLines(
    (Join-Path $outDir 'R197_수집요약.txt'),
    $summary, $Utf8Bom)

$zipPath = $outDir + '.zip'
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
$archiveInputs = @(Get-ChildItem -LiteralPath $outDir -Force |
    Select-Object -ExpandProperty FullName)
if ($archiveInputs.Count -eq 0) {
    throw "압축할 테스트 로그가 없습니다: $outDir"
}
Compress-Archive -LiteralPath $archiveInputs `
    -DestinationPath $zipPath -CompressionLevel Optimal

Write-Host ''
Write-Host '=================================================================='
Write-Host '[R197 테스트 로그 수집 완료]'
Write-Host "폴더: $outDir"
Write-Host "ZIP : $zipPath"
Write-Host '=================================================================='
