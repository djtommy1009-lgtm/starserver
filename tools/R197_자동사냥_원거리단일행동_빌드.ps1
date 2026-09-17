#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceRoot = 'C:\Users\Administrator\Desktop\스타 Server 원본',
    [string]$TestRoot = 'C:\Users\Administrator\Desktop\스타서버ON,OF\스타ServerTest실행',
    [string]$ProductionRoot = 'C:\Users\Administrator\Desktop\스타서버on'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PatchId = 'R197_AUTO_RANGED_SINGLE_ACTION_20260917'
$ControllerClass = 'l1j.server.AutoHuntSystem.AutoHuntController'
$ControllerEntryRegex = '^l1j/server/AutoHuntSystem/AutoHuntController(?:\$.*)?\.class$'
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)

function Step([string]$Text) {
    Write-Host ('[R197] ' + $Text)
}

function FullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function CountOrdinal([string]$Text, [string]$Needle) {
    if ([string]::IsNullOrEmpty($Needle)) { return 0 }
    $count = 0
    $offset = 0
    while ($true) {
        $offset = $Text.IndexOf($Needle, $offset,
            [System.StringComparison]::Ordinal)
        if ($offset -lt 0) { break }
        $count++
        $offset += $Needle.Length
    }
    return $count
}

function ReplaceOnce(
    [string]$Text,
    [string]$Old,
    [string]$New,
    [string]$Label
) {
    $count = CountOrdinal $Text $Old
    if ($count -ne 1) {
        throw "$Label 일치 수=$count, 기대값=1. 예측 치환을 중단합니다."
    }
    return $Text.Replace($Old, $New)
}

function FindMatchingBrace([string]$Text, [int]$OpenIndex) {
    if ($OpenIndex -lt 0 -or $OpenIndex -ge $Text.Length -or
        $Text[$OpenIndex] -ne '{') {
        throw "잘못된 여는 중괄호 위치: $OpenIndex"
    }

    $depth = 0
    $state = 'normal'
    $escaped = $false

    for ($i = $OpenIndex; $i -lt $Text.Length; $i++) {
        $c = [string]$Text[$i]
        $next = if ($i + 1 -lt $Text.Length) {
            [string]$Text[$i + 1]
        } else { '' }

        switch ($state) {
            'normal' {
                if ($c -eq '/' -and $next -eq '/') {
                    $state = 'line'; $i++; continue
                }
                if ($c -eq '/' -and $next -eq '*') {
                    $state = 'block'; $i++; continue
                }
                if ($c -eq '"') {
                    $state = 'string'; $escaped = $false; continue
                }
                if ($c -eq "'") {
                    $state = 'char'; $escaped = $false; continue
                }
                if ($c -eq '{') { $depth++; continue }
                if ($c -eq '}') {
                    $depth--
                    if ($depth -eq 0) { return $i }
                    if ($depth -lt 0) { throw '중괄호 깊이가 음수가 됐습니다.' }
                }
            }
            'line' {
                if ($c -eq "`n") { $state = 'normal' }
            }
            'block' {
                if ($c -eq '*' -and $next -eq '/') {
                    $state = 'normal'; $i++
                }
            }
            'string' {
                if ($escaped) { $escaped = $false; continue }
                if ($c -eq '\') { $escaped = $true; continue }
                if ($c -eq '"') { $state = 'normal' }
            }
            'char' {
                if ($escaped) { $escaped = $false; continue }
                if ($c -eq '\') { $escaped = $true; continue }
                if ($c -eq "'") { $state = 'normal' }
            }
        }
    }
    throw "닫는 중괄호를 찾지 못했습니다: $OpenIndex"
}

function MethodRange([string]$Text, [string[]]$Signatures) {
    $found = @()
    foreach ($signature in $Signatures) {
        $index = $Text.IndexOf($signature,
            [System.StringComparison]::Ordinal)
        if ($index -ge 0) {
            $found += [pscustomobject]@{
                Signature = $signature
                Start = $index
            }
        }
    }
    if ($found.Count -ne 1) {
        throw ('메서드 후보 수=' + $found.Count + ': ' +
            ($Signatures -join ' | '))
    }
    $open = $Text.IndexOf('{', [int]$found[0].Start)
    if ($open -lt 0) { throw "메서드 여는 괄호 없음: $($found[0].Signature)" }
    $end = FindMatchingBrace $Text $open
    return [pscustomobject]@{
        Signature = $found[0].Signature
        Start = [int]$found[0].Start
        Open = $open
        End = $end
        Length = $end - [int]$found[0].Start + 1
    }
}

function BlockRange([string]$Text, [string]$Needle) {
    $count = CountOrdinal $Text $Needle
    if ($count -ne 1) {
        throw "블록 표식 '$Needle' 수=$count, 기대값=1"
    }
    $start = $Text.IndexOf($Needle,
        [System.StringComparison]::Ordinal)
    $open = $Text.IndexOf('{', $start)
    if ($open -lt 0) { throw "블록 여는 괄호 없음: $Needle" }
    $end = FindMatchingBrace $Text $open
    return [pscustomobject]@{
        Start = $start
        End = $end
        Length = $end - $start + 1
    }
}

function ReplaceRange(
    [string]$Text,
    [int]$Start,
    [int]$End,
    [string]$Replacement
) {
    if ($Start -lt 0 -or $End -lt $Start -or $End -ge $Text.Length) {
        throw "잘못된 치환 범위: $Start..$End / $($Text.Length)"
    }
    return $Text.Substring(0, $Start) + $Replacement +
        $Text.Substring($End + 1)
}

function ReadSource([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)

    if ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF) {
        $text = $utf8.GetString($bytes, 3, $bytes.Length - 3)
        $encoding = $utf8Bom
        $encodingName = 'UTF-8-BOM'
    } else {
        try {
            $text = $strictUtf8.GetString($bytes)
            $encoding = $utf8
            $encodingName = 'UTF-8'
        } catch {
            $encoding = [System.Text.Encoding]::GetEncoding(949)
            $text = $encoding.GetString($bytes)
            $encodingName = 'MS949'
        }
    }

    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    return [pscustomobject]@{
        Text = $text.Replace("`r`n", "`n")
        Encoding = $encoding
        EncodingName = $encodingName
        NewLine = $newline
    }
}

function WriteSource(
    [string]$Path,
    [string]$Text,
    [System.Text.Encoding]$Encoding,
    [string]$NewLine
) {
    $output = if ($NewLine -eq "`r`n") {
        $Text.Replace("`n", "`r`n")
    } else { $Text }
    [System.IO.File]::WriteAllText($Path, $output, $Encoding)
}

function FindJdkTool([string]$Name) {
    $roots = @(
        $env:JAVA_HOME,
        'C:\Program Files\Java\jdk1.8.0_202',
        'C:\Program Files\Java\jdk1.8.0_361'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique

    foreach ($root in $roots) {
        $candidate = Join-Path $root ('bin\' + $Name + '.exe')
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $env:JAVA_HOME = $root
            $env:Path = (Join-Path $root 'bin') + ';' + $env:Path
            return $candidate
        }
    }
    $command = Get-Command ($Name + '.exe') -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw "JDK 8 $Name.exe를 찾지 못했습니다."
}

function FindAnt() {
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ANT_HOME)) {
        $candidates += Join-Path $env:ANT_HOME 'bin\ant.bat'
    }
    $command = Get-Command ant.bat -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    $command = Get-Command ant -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    $candidates += 'C:\apache-ant\bin\ant.bat'
    $candidates += 'C:\Program Files\Apache Ant\bin\ant.bat'

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ($candidate -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }
    throw 'Apache Ant를 찾지 못했습니다. ANT_HOME 또는 PATH를 확인하십시오.'
}

function CompileSource(
    [string]$Ant,
    [string]$BuildFile,
    [string]$LogPath
) {
    Step "전체 컴파일: $BuildFile"
    $global:LASTEXITCODE = 0
    & $Ant -f $BuildFile clean compile 2>&1 |
        Tee-Object -FilePath $LogPath
    if ($LASTEXITCODE -ne 0) {
        throw "Ant clean compile 실패: 종료 코드 $LASTEXITCODE"
    }
}

function FindCompiledController([string]$Root) {
    $excluded = '\\(deployment_backups|verification|lib|libs|\.git)\\'
    $matches = @(
        Get-ChildItem -LiteralPath $Root -Recurse -File `
            -Filter 'AutoHuntController.class' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $excluded } |
        Sort-Object LastWriteTimeUtc -Descending
    )
    if ($matches.Count -eq 0) {
        throw '컴파일된 AutoHuntController.class를 찾지 못했습니다.'
    }
    return $matches[0]
}

function ClassRoot([string]$ClassPath) {
    $suffix = '\l1j\server\AutoHuntSystem\AutoHuntController.class'
    if (-not $ClassPath.EndsWith($suffix,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "예상하지 못한 CLASS 경로: $ClassPath"
    }
    return $ClassPath.Substring(0, $ClassPath.Length - $suffix.Length)
}

function JavapText(
    [string]$Javap,
    [string]$Classpath,
    [string]$OutputPath
) {
    $lines = @(& $Javap -classpath $Classpath -c -p -s -constants `
        $ControllerClass 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) {
        throw "javap 실패: $Classpath"
    }
    $text = ($lines -join "`n").Trim()
    [System.IO.File]::WriteAllText($OutputPath, $text + "`n", $Utf8Bom)
    return $text
}

function NormalizeJavap([string]$Text) {
    $value = $Text.Replace("`r`n", "`n")
    $value = [regex]::Replace($value,
        '(?m)^Compiled from ".*?"\s*$', '')
    $value = [regex]::Replace($value, '[ \t]+', ' ')
    $value = [regex]::Replace($value, '(?m)^\s+$', '')
    return $value.Trim()
}

function PatchController([string]$InputText) {
    $text = $InputText
    if ($text.Contains($PatchId)) {
        throw "$PatchId가 이미 적용된 소스입니다."
    }

    foreach ($token in @(
        'package l1j.server.AutoHuntSystem;',
        'private void toAttackMonster()',
        'private void toAttack(L1Character expectedTarget)',
        'private boolean issueAutoHumanAttack(L1Character target)',
        'AttackActionHandler.executeAutoHuntAttack(owner',
        'skilluse.toWizardAttackSkill(target);'
    )) {
        if (-not $text.Contains($token)) {
            throw "필수 소스 토큰 없음: $token"
        }
    }

    if (-not $text.Contains(
        'private static final String AUTO_RANGED_SINGLE_ACTION_VERSION')) {
        $anchor = 'private static final long AUTO_WIZARD_ATTACK_SKILL_INTERVAL = 4000L;'
        $insert = $anchor + "`n`tprivate static final String " +
            'AUTO_RANGED_SINGLE_ACTION_VERSION = "R197";'
        $text = ReplaceOnce $text $anchor $insert 'R197 버전 필드 삽입'
    }

    if (-not [regex]::IsMatch($text,
        'private\s+int\s+_lastAutoTripleArrowTargetId\s*=')) {
        $anchor = 'private long _lastAutoTripleArrowTime = 0L;'
        $insert = $anchor + "`n`tprivate int _lastAutoTripleArrowTargetId = 0;"
        $text = ReplaceOnce $text $anchor $insert '트리플 대상 필드 삽입'
    }

    $clearRange = MethodRange $text @(
        'private void clearAutoTarget(L1Character target)'
    )
    $clearMethod = $text.Substring($clearRange.Start, $clearRange.Length)
    $wizardReset = New-Object System.Text.RegularExpressions.Regex(
        '(?m)^[ \t]*_lastAutoWizardAttackSkillTime\s*=\s*0L;[ \t]*\n')
    $resetCount = $wizardReset.Matches($clearMethod).Count
    if ($resetCount -gt 1) {
        throw "clearAutoTarget 법사 시계 초기화 수=$resetCount"
    }
    if ($resetCount -eq 1) {
        $clearMethod = $wizardReset.Replace($clearMethod,
            "`t`t/* R197: 대상 변경으로 4초 법사 마법 주기를 초기화하지 않는다. */`n", 1)
        $text = ReplaceRange $text $clearRange.Start $clearRange.End $clearMethod
    }

    $invalidRange = MethodRange $text @(
        'private boolean clearInvalidAutoTarget(L1Character target)'
    )
    $invalidMethod = $text.Substring($invalidRange.Start,
        $invalidRange.Length)
    if (-not $invalidMethod.Contains('_lastAutoTripleArrowTargetId = 0;')) {
        $invalidMethod = ReplaceOnce $invalidMethod `
            '_lastAutoTripleArrowTime = 0L;' `
            "_lastAutoTripleArrowTime = 0L;`n`t`t_lastAutoTripleArrowTargetId = 0;" `
            '무효 타깃 트리플 대상 초기화'
        $text = ReplaceRange $text $invalidRange.Start $invalidRange.End `
            $invalidMethod
    }

    $tripleRange = MethodRange $text @(
        'private void toUseElfTripleArrow(L1Character target)',
        'private boolean toUseElfTripleArrow(L1Character target)'
    )
    $tripleMethod = @'
private boolean toUseElfTripleArrow(L1Character target) {
        if (owner == null || target == null || !owner.isElf()) {
            _lastAutoTripleArrowTime = 0L;
            _lastAutoTripleArrowTargetId = 0;
            return false;
        }
        if (!SkillCheck.getInstance().CheckSkill(owner,
                L1SkillId.TRIPLE_ARROW)) {
            _lastAutoTripleArrowTime = 0L;
            _lastAutoTripleArrowTargetId = 0;
            return false;
        }
        if (handoffDeadAutoTarget(target)
                || !isAutoSingleActionTargetReady(target)) {
            _lastAutoTripleArrowTargetId = 0;
            return false;
        }

        long now = System.currentTimeMillis();
        if (_lastAutoTripleArrowTargetId != target.getId()) {
            _lastAutoTripleArrowTargetId = target.getId();
            _lastAutoTripleArrowTime = now;
            return false;
        }
        if (_lastAutoTripleArrowTime == 0L) {
            _lastAutoTripleArrowTime = now;
            return false;
        }
        if (now - _lastAutoTripleArrowTime
                < AUTO_ELF_TRIPLE_ARROW_INTERVAL) {
            return false;
        }
        if (!isAutoSingleActionTargetReady(target)) {
            return false;
        }

        AutoHuntSkillUse skilluse = getAutoHuntSkillUse();
        if (skilluse.toTripleArrow(target)) {
            _lastAutoTripleArrowTime = now;
            return true;
        }
        return false;
    }
'@.Replace("`r`n", "`n").TrimEnd()
    $text = ReplaceRange $text $tripleRange.Start $tripleRange.End `
        $tripleMethod

    $monsterRange = MethodRange $text @('private void toAttackMonster()')
    $monsterMethod = $text.Substring($monsterRange.Start,
        $monsterRange.Length)
    if (-not $monsterMethod.Contains('if (handoffDeadAutoTarget(target))')) {
        $monsterMethod = ReplaceOnce $monsterMethod `
            'L1Character target = owner.getAutoTarget();' `
            "L1Character target = owner.getAutoTarget();`n`t`t`tif (handoffDeadAutoTarget(target)) {`n`t`t`t`treturn;`n`t`t`t}" `
            '공격 시작 전 사망 타깃 인계'
        $text = ReplaceRange $text $monsterRange.Start $monsterRange.End `
            $monsterMethod
    }

    $attackRange = MethodRange $text @(
        'private void toAttack(L1Character expectedTarget)'
    )
    $attackMethod = $text.Substring($attackRange.Start,
        $attackRange.Length)
    $elfRange = BlockRange $attackMethod `
        'if (owner.isElf() && owner.getWeapon() != null'
    $wizardRange = BlockRange $attackMethod 'if (owner.isWizard())'
    if ($wizardRange.Start -le $elfRange.End) {
        throw '법사 블록 위치가 요정 블록 뒤가 아닙니다.'
    }

    $newElf = @'
if (owner.isElf() && owner.getWeapon() != null
                    && owner.getWeapon().getItem().getType1() == 20) {

                if (owner.getInventory().getArrow() == null
                        && !owner.getInventory()
                                .isStarInfiniteSilverArrowActive()) {
                    return;
                }
                if (!canAutoContinue()
                        || handoffDeadAutoTarget(target)
                        || !isAutoSingleActionTargetReady(target)) {
                    return;
                }
                /* R197: 한 슬롯은 트리플 또는 기본 활질 중 하나만 실행한다. */
                if (toUseElfTripleArrow(target)) {
                    markAutoAttackTarget(target);
                    settleDeadAutoTargetAfterAttack(target);
                    clearInvalidAutoTarget(target);
                    return;
                }
                if (!canAutoContinue()
                        || clearInvalidAutoTarget(target)
                        || !isSameAutoAttackTarget(target)
                        || !isAutoSingleActionTargetReady(target)) {
                    return;
                }
                if (!issueAutoHumanAttack(target)) {
                    return;
                }
                clearInvalidAutoTarget(target);

            }
'@.Replace("`r`n", "`n").TrimEnd()

    $newWizard = @'
if (owner.isWizard()) {

                    if (!canAutoContinue()
                            || handoffDeadAutoTarget(target)
                            || !isAutoSingleActionTargetReady(target)) {
                        return;
                    }

                    long now = System.currentTimeMillis();
                    if (now - _lastAutoWizardAttackSkillTime
                            >= AUTO_WIZARD_ATTACK_SKILL_INTERVAL) {
                        /* R197: 마법 슬롯에서는 기본 지팡이 공격을 함께 보내지 않는다. */
                        AutoHuntSkillUse skilluse = getAutoHuntSkillUse();
                        skilluse.toWizardAttackSkill(target);
                        _lastAutoWizardAttackSkillTime = now;
                        markAutoAttackTarget(target);
                        settleDeadAutoTargetAfterAttack(target);
                        clearInvalidAutoTarget(target);
                        return;
                    }

                    if (!issueAutoHumanAttack(target)) {
                        return;
                    }
                    if (clearInvalidAutoTarget(target)
                            || !isSameAutoAttackTarget(target)) {
                        return;
                    }

                }
'@.Replace("`r`n", "`n").TrimEnd()

    $changes = @(
        [pscustomobject]@{
            Start = $wizardRange.Start
            End = $wizardRange.End
            Text = $newWizard
        },
        [pscustomobject]@{
            Start = $elfRange.Start
            End = $elfRange.End
            Text = $newElf
        }
    ) | Sort-Object Start -Descending
    foreach ($change in $changes) {
        $attackMethod = ReplaceRange $attackMethod $change.Start `
            $change.End $change.Text
    }
    $text = ReplaceRange $text $attackRange.Start $attackRange.End `
        $attackMethod

    $issueRange = MethodRange $text @(
        'private boolean issueAutoHumanAttack(L1Character target)'
    )
    $issueMethod = @'
private boolean issueAutoHumanAttack(L1Character target) {
        if (!canAutoContinue() || target == null
                || isAutoPolymorphActionHoldActive(
                        System.currentTimeMillis())) {
            return false;
        }
        if (handoffDeadAutoTarget(target)
                || !isAutoSingleActionTargetReady(target)) {
            return false;
        }
        boolean issued = AttackActionHandler.executeAutoHuntAttack(owner,
                target);
        StarAutoVisualTrace.logAttackResult(owner, target, issued,
                getAutoBasicAttackRange(),
                isAutoMeleeTargetArrivalReady(target),
                isAutoMeleeAttackAnimationReady(),
                hasAutoTargetLineOfSight(target));
        if (issued) {
            markAutoAttackTarget(target);
            settleDeadAutoTargetAfterAttack(target);
        }
        return issued;
    }
'@.Replace("`r`n", "`n").TrimEnd()
    $text = ReplaceRange $text $issueRange.Start $issueRange.End $issueMethod

    $helpers = New-Object System.Collections.Generic.List[string]

    if (-not $text.Contains(
        'private boolean handoffDeadAutoTarget(L1Character target)')) {
        $helpers.Add(@'
private boolean handoffDeadAutoTarget(L1Character target) {
        try {
            if (owner == null || target == null
                    || (!target.isDead() && target.getCurrentHp() > 0)) {
                return false;
            }
            clearAutoAttackTargetMark(target);
            clearAutoTarget(target);
            _lastAutoTripleArrowTime = 0L;
            _lastAutoTripleArrowTargetId = 0;
            _lastTargetKeepCheckTime = 0L;
            _lastTargetSearchTime = 0L;
            owner.setAutoAiTime(0L);
            owner.setAutoTeleportDelayTime(0L);
            searchTarget();
            L1Character nextTarget = owner.getAutoTarget();
            owner.setAutoStatus(isValidAutoCombatTarget(nextTarget)
                    ? AUTO_STATUS_ATTACK : AUTO_STATUS_WALK);
            return true;
        } catch (Exception e) {
            return false;
        }
    }
'@.Replace("`r`n", "`n").TrimEnd())
    }

    if (-not $text.Contains(
        'private boolean isAutoSingleActionTargetReady(')) {
        $helpers.Add(@'
private boolean isAutoSingleActionTargetReady(L1Character target) {
        try {
            if (!canAutoContinue() || target == null
                    || target.isDead() || target.getCurrentHp() <= 0
                    || owner.getAutoTarget() != target
                    || owner.getMapId() != target.getMapId()
                    || L1World.getInstance().findObject(target.getId())
                            != target
                    || !isCurrentAutoTargetReadyToAttack(target)) {
                return false;
            }
            if (!owner.knownsObject(target)) {
                if (target instanceof L1NpcInstance) {
                    ((L1NpcInstance) target).onPerceive(owner);
                }
                return false;
            }
            return true;
        } catch (Exception e) {
            return false;
        }
    }
'@.Replace("`r`n", "`n").TrimEnd())
    }

    if (-not $text.Contains(
        'private void settleDeadAutoTargetAfterAttack(')) {
        $helpers.Add(@'
private void settleDeadAutoTargetAfterAttack(
            L1Character defeatedTarget) {
        try {
            if (owner == null || defeatedTarget == null
                    || (!defeatedTarget.isDead()
                            && defeatedTarget.getCurrentHp() > 0)) {
                return;
            }
            clearAutoAttackTargetMark(defeatedTarget);
            clearAutoTarget(defeatedTarget);
            _lastAutoTripleArrowTime = 0L;
            _lastAutoTripleArrowTargetId = 0;
            _lastTargetKeepCheckTime = 0L;
            _lastTargetSearchTime = 0L;
            searchTarget();
            L1Character nextTarget = owner.getAutoTarget();
            if (!isValidAutoCombatTarget(nextTarget)) {
                owner.setAutoStatus(AUTO_STATUS_WALK);
                return;
            }
            owner.setAutoStatus(AUTO_STATUS_ATTACK);
            owner.setAutoAiTime(0L);
        } catch (Exception e) {
        }
    }
'@.Replace("`r`n", "`n").TrimEnd())
    }

    if ($helpers.Count -gt 0) {
        $issueRange = MethodRange $text @(
            'private boolean issueAutoHumanAttack(L1Character target)'
        )
        $helperText = ($helpers -join "`n`n`t") + "`n`n`t"
        $text = $text.Substring(0, $issueRange.Start) + $helperText +
            $text.Substring($issueRange.Start)
    }

    $package = 'package l1j.server.AutoHuntSystem;'
    $marker = @'
/*
 * [R197_AUTO_RANGED_SINGLE_ACTION_20260917]
 * 요정: 한 공격 슬롯은 트리플 또는 기본 활질 중 하나만 실행한다.
 * 법사: 한 공격 슬롯은 공격마법 또는 기본공격 중 하나만 실행한다.
 * 사망·월드 정본 불일치·다른 맵·미인식 대상은 발행 직전에 거절한다.
 * 공격거리·공격속도·대미지·드랍·경험치·DB는 변경하지 않는다.
 */
'@.Replace("`r`n", "`n").TrimEnd()
    $text = ReplaceOnce $text ($package + "`n") `
        ($package + "`n`n" + $marker + "`n") 'R197 표식 삽입'

    return $text
}

function AuditPatchedSource([string]$Text) {
    foreach ($token in @(
        $PatchId,
        'AUTO_RANGED_SINGLE_ACTION_VERSION = "R197"',
        'private boolean toUseElfTripleArrow(L1Character target)',
        'private boolean handoffDeadAutoTarget(L1Character target)',
        'private boolean isAutoSingleActionTargetReady(',
        'private void settleDeadAutoTargetAfterAttack(',
        'owner.knownsObject(target)'
    )) {
        if (-not $Text.Contains($token)) {
            throw "수정 후 필수 토큰 없음: $token"
        }
    }
    if ($Text.Contains(
        'private void toUseElfTripleArrow(L1Character target)')) {
        throw '구형 void 트리플 메서드가 남았습니다.'
    }

    $clearRange = MethodRange $Text @(
        'private void clearAutoTarget(L1Character target)'
    )
    $clearMethod = $Text.Substring($clearRange.Start, $clearRange.Length)
    if ($clearMethod.Contains('_lastAutoWizardAttackSkillTime = 0L;')) {
        throw '대상 변경 시 법사 마법 시계 초기화가 남았습니다.'
    }

    $attackRange = MethodRange $Text @(
        'private void toAttack(L1Character expectedTarget)'
    )
    $method = $Text.Substring($attackRange.Start, $attackRange.Length)
    $elf = BlockRange $method `
        'if (owner.isElf() && owner.getWeapon() != null'
    $elfText = $method.Substring($elf.Start, $elf.Length)
    $triple = $elfText.IndexOf('toUseElfTripleArrow(target)',
        [System.StringComparison]::Ordinal)
    $bow = $elfText.IndexOf('issueAutoHumanAttack(target)',
        [System.StringComparison]::Ordinal)
    if ($triple -lt 0 -or $bow -lt 0 -or $triple -ge $bow) {
        throw '요정 단일 행동 순서 검수 실패'
    }

    $wizard = BlockRange $method 'if (owner.isWizard())'
    $wizardText = $method.Substring($wizard.Start, $wizard.Length)
    $spell = $wizardText.IndexOf('toWizardAttackSkill(target)',
        [System.StringComparison]::Ordinal)
    $basic = $wizardText.IndexOf('issueAutoHumanAttack(target)',
        [System.StringComparison]::Ordinal)
    if ($spell -lt 0 -or $basic -lt 0 -or $spell -ge $basic) {
        throw '법사 단일 행동 순서 검수 실패'
    }
    if (-not $wizardText.Contains(
        '_lastAutoWizardAttackSkillTime = now;') -or
        -not $wizardText.Contains('return;')) {
        throw '법사 마법 슬롯 종료 검수 실패'
    }

    $monsterRange = MethodRange $Text @('private void toAttackMonster()')
    $monster = $Text.Substring($monsterRange.Start, $monsterRange.Length)
    if (-not $monster.Contains('if (handoffDeadAutoTarget(target))')) {
        throw '공격 시작 전 사망 타깃 인계가 없습니다.'
    }
}

function BuildCandidateJar(
    [string]$BaseJar,
    [string]$CandidateJar,
    [string]$ClassDirectory
) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Copy-Item -LiteralPath $BaseJar -Destination $CandidateJar -Force

    $classes = @(
        Get-ChildItem -LiteralPath $ClassDirectory -File `
            -Filter 'AutoHuntController*.class' | Sort-Object Name
    )
    if ($classes.Count -eq 0) {
        throw '새 AutoHuntController CLASS가 없습니다.'
    }

    $zip = [System.IO.Compression.ZipFile]::Open($CandidateJar,
        [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $old = @($zip.Entries | Where-Object {
            $_.FullName -match $ControllerEntryRegex
        })
        if ($old.Count -eq 0) {
            throw '기준 JAR에 AutoHuntController CLASS가 없습니다.'
        }
        foreach ($entry in $old) { $entry.Delete() }
        foreach ($class in $classes) {
            $entryName = 'l1j/server/AutoHuntSystem/' + $class.Name
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $class.FullName, $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        $zip.Dispose()
    }
    return $classes
}

$SourceRoot = FullPath $SourceRoot
$TestRoot = FullPath $TestRoot
$ProductionRoot = FullPath $ProductionRoot

if ($SourceRoot.StartsWith($ProductionRoot,
    [System.StringComparison]::OrdinalIgnoreCase)) {
    throw '운영 서버 폴더를 SourceRoot로 사용할 수 없습니다.'
}
if ($TestRoot.StartsWith($ProductionRoot,
    [System.StringComparison]::OrdinalIgnoreCase)) {
    throw '운영 서버 폴더를 TestRoot로 사용할 수 없습니다.'
}

$sourceFile = Join-Path $SourceRoot `
    'src\l1j\server\AutoHuntSystem\AutoHuntController.java'
$buildFile = Join-Path $SourceRoot 'build.xml'
$testJar = Join-Path $TestRoot 'l1jserver.jar'

foreach ($path in @($sourceFile, $buildFile, $testJar)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "필수 파일 없음: $path"
    }
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$workRoot = Join-Path $TestRoot `
    ('R197_AUTO_RANGED_SINGLE_ACTION_' + $stamp)
$evidence = Join-Path $workRoot 'evidence'
$candidateDir = Join-Path $workRoot 'candidate'
$backupDir = Join-Path $SourceRoot `
    ('deployment_backups\R197_AUTO_RANGED_SINGLE_ACTION_' + $stamp)
New-Item -ItemType Directory -Force -Path `
    $evidence, $candidateDir, $backupDir | Out-Null

$report = Join-Path $workRoot 'R197_빌드검수.txt'
$reportLines = New-Object System.Collections.Generic.List[string]
$sourceBackup = Join-Path $backupDir `
    'src\l1j\server\AutoHuntSystem\AutoHuntController.java'
New-Item -ItemType Directory -Force `
    -Path (Split-Path -Parent $sourceBackup) | Out-Null
Copy-Item -LiteralPath $sourceFile -Destination $sourceBackup -Force
$sourceWasWritten = $false

try {
    $ant = FindAnt
    $javap = FindJdkTool 'javap'
    [void](FindJdkTool 'javac')

    $reportLines.Add("patchId=$PatchId")
    $reportLines.Add("sourceRoot=$SourceRoot")
    $reportLines.Add("testRoot=$TestRoot")
    $reportLines.Add("sourceFile=$sourceFile")
    $reportLines.Add("sourceSha256Before=$(Sha256 $sourceFile)")
    $reportLines.Add("testJarSha256Before=$(Sha256 $testJar)")
    $reportLines.Add("sourceBackup=$sourceBackup")
    $reportLines.Add('productionJarModified=NO')

    $sourceData = ReadSource $sourceFile
    $reportLines.Add("sourceEncoding=$($sourceData.EncodingName)")

    $beforeCompile = Join-Path $evidence '01_before_compile.log'
    CompileSource $ant $buildFile $beforeCompile
    $beforeClass = FindCompiledController $SourceRoot
    $beforeRoot = ClassRoot $beforeClass.FullName

    $jarBeforeJavap = JavapText $javap $testJar `
        (Join-Path $evidence '02_test_jar_before.javap.txt')
    $sourceBeforeJavap = JavapText $javap $beforeRoot `
        (Join-Path $evidence '03_source_before.javap.txt')
    $authority = (NormalizeJavap $jarBeforeJavap) -ceq
        (NormalizeJavap $sourceBeforeJavap)
    $reportLines.Add("sourceAuthorityMatch=$authority")
    if (-not $authority) {
        throw '현재 소스와 테스트 JAR 바이트코드가 다릅니다. 소스 수정 없이 중단합니다.'
    }

    Step 'AutoHuntController.java 소수 수정 적용'
    $patched = PatchController $sourceData.Text
    AuditPatchedSource $patched
    WriteSource $sourceFile $patched $sourceData.Encoding `
        $sourceData.NewLine
    $sourceWasWritten = $true
    $reportLines.Add("sourceSha256After=$(Sha256 $sourceFile)")
    $reportLines.Add('modifiedJavaCount=1')
    $reportLines.Add(
        'modifiedJava=src/l1j/server/AutoHuntSystem/AutoHuntController.java')

    $afterCompile = Join-Path $evidence '04_after_compile.log'
    CompileSource $ant $buildFile $afterCompile
    $afterClass = FindCompiledController $SourceRoot
    $afterRoot = ClassRoot $afterClass.FullName
    $afterJavap = JavapText $javap $afterRoot `
        (Join-Path $evidence '05_source_after.javap.txt')

    foreach ($token in @(
        'AUTO_RANGED_SINGLE_ACTION_VERSION',
        'ConstantValue: String R197',
        'boolean toUseElfTripleArrow',
        'handoffDeadAutoTarget',
        'isAutoSingleActionTargetReady',
        'settleDeadAutoTargetAfterAttack'
    )) {
        if (-not $afterJavap.Contains($token)) {
            throw "수정 CLASS 토큰 없음: $token"
        }
    }

    $candidateJar = Join-Path $candidateDir `
        'l1jserver_R197_AUTO_RANGED_SINGLE_ACTION_candidate.jar'
    $classes = BuildCandidateJar $testJar $candidateJar `
        (Split-Path -Parent $afterClass.FullName)

    $candidateJavap = JavapText $javap $candidateJar `
        (Join-Path $evidence '06_candidate_jar.javap.txt')
    $candidateMatch = (NormalizeJavap $candidateJavap) -ceq
        (NormalizeJavap $afterJavap)
    $reportLines.Add("candidateBytecodeMatch=$candidateMatch")
    if (-not $candidateMatch) {
        throw '후보 JAR과 새 CLASS 바이트코드가 다릅니다.'
    }

    $candidateHash = Sha256 $candidateJar
    $reportLines.Add("candidateJar=$candidateJar")
    $reportLines.Add("candidateJarSha256=$candidateHash")
    $reportLines.Add("updatedClassCount=$($classes.Count)")
    foreach ($class in $classes) {
        $reportLines.Add(
            "updatedClass=$($class.Name):$(Sha256 $class.FullName)")
    }
    $reportLines.Add('compile=PASS')
    $reportLines.Add('result=PASS')

    [System.IO.File]::WriteAllLines($report, $reportLines, $Utf8Bom)
    [System.IO.File]::WriteAllLines(
        (Join-Path $candidateDir 'R197_candidate_manifest.txt'),
        @(
            "patchId=$PatchId",
            "baseTestJar=$testJar",
            "baseTestJarSha256=$(Sha256 $testJar)",
            "candidateJar=$candidateJar",
            "candidateJarSha256=$candidateHash",
            "sourceFile=$sourceFile",
            "sourceSha256=$(Sha256 $sourceFile)",
            "created=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ),
        $Utf8Bom
    )

    Write-Host ''
    Write-Host '=================================================================='
    Write-Host '[R197 후보 JAR 생성 완료]'
    Write-Host "후보 JAR : $candidateJar"
    Write-Host "검수 보고 : $report"
    Write-Host '운영 JAR  : 변경하지 않음'
    Write-Host '테스트 JAR: 아직 변경하지 않음'
    Write-Host '=================================================================='
} catch {
    $message = $_.Exception.Message
    $reportLines.Add("failure=$message")
    $reportLines.Add('result=FAIL')
    if ($sourceWasWritten -and
        (Test-Path -LiteralPath $sourceBackup -PathType Leaf)) {
        try {
            Copy-Item -LiteralPath $sourceBackup `
                -Destination $sourceFile -Force
            $reportLines.Add('sourceRollback=PASS')
        } catch {
            $reportLines.Add(
                "sourceRollback=FAIL:$($_.Exception.Message)")
        }
    }
    [System.IO.File]::WriteAllLines($report, $reportLines, $Utf8Bom)
    Write-Error "R197 빌드 실패: $message"
    exit 1
}
