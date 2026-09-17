#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceRoot = 'C:\Users\Administrator\Desktop\스타 Server 원본',
    [string]$TestRoot = 'C:\Users\Administrator\Desktop\스타서버ON,OF\스타ServerTest실행',
    [string]$ExpectedProductionJarSha256 = 'F8D41935752FD96C0C3C75CE6765E8852F3FEACE808B4DAE364E3555CA2F4BF9',
    [switch]$SkipSourceAuthorityCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PatchId = 'R197_AUTO_RANGED_SINGLE_ACTION_20260917'
$ControllerClass = 'l1j.server.AutoHuntSystem.AutoHuntController'
$ControllerEntryRegex = '^l1j/server/AutoHuntSystem/AutoHuntController(?:\$.*)?\.class$'
$ProductionRoot = 'C:\Users\Administrator\Desktop\스타서버on'

function Write-Step {
    param([string]$Text)
    Write-Host ('[R197] ' + $Text)
}

function Get-FullPathSafe {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Count-Ordinal {
    param([string]$Text, [string]$Needle)
    if ([string]::IsNullOrEmpty($Needle)) { return 0 }
    $count = 0
    $index = 0
    while ($true) {
        $index = $Text.IndexOf($Needle, $index, [System.StringComparison]::Ordinal)
        if ($index -lt 0) { break }
        $count++
        $index += $Needle.Length
    }
    return $count
}

function Replace-ExactOnce {
    param(
        [string]$Text,
        [string]$Old,
        [string]$New,
        [string]$Label
    )
    $count = Count-Ordinal -Text $Text -Needle $Old
    if ($count -ne 1) {
        throw "$Label exact match count is $count; expected 1. No unsafe replacement was made."
    }
    return $Text.Replace($Old, $New)
}

function Find-MatchingJavaBrace {
    param([string]$Text, [int]$OpenIndex)

    if ($OpenIndex -lt 0 -or $OpenIndex -ge $Text.Length -or $Text[$OpenIndex] -ne '{') {
        throw "Invalid Java opening-brace index: $OpenIndex"
    }

    $depth = 0
    $state = 'normal'
    $escaped = $false

    for ($i = $OpenIndex; $i -lt $Text.Length; $i++) {
        $c = [string]$Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { [string]$Text[$i + 1] } else { '' }

        if ($state -eq 'normal') {
            if ($c -eq '/' -and $next -eq '/') {
                $state = 'line_comment'
                $i++
                continue
            }
            if ($c -eq '/' -and $next -eq '*') {
                $state = 'block_comment'
                $i++
                continue
            }
            if ($c -eq '"') {
                $state = 'string'
                $escaped = $false
                continue
            }
            if ($c -eq "'") {
                $state = 'char'
                $escaped = $false
                continue
            }
            if ($c -eq '{') {
                $depth++
                continue
            }
            if ($c -eq '}') {
                $depth--
                if ($depth -eq 0) { return $i }
                if ($depth -lt 0) { throw 'Java brace depth became negative.' }
                continue
            }
            continue
        }

        if ($state -eq 'line_comment') {
            if ($c -eq "`n") { $state = 'normal' }
            continue
        }

        if ($state -eq 'block_comment') {
            if ($c -eq '*' -and $next -eq '/') {
                $state = 'normal'
                $i++
            }
            continue
        }

        if ($state -eq 'string' -or $state -eq 'char') {
            if ($escaped) {
                $escaped = $false
                continue
            }
            if ($c -eq '\') {
                $escaped = $true
                continue
            }
            if (($state -eq 'string' -and $c -eq '"') -or
                ($state -eq 'char' -and $c -eq "'")) {
                $state = 'normal'
            }
            continue
        }
    }

    throw "No matching Java closing brace was found for index $OpenIndex."
}

function Get-JavaMethodRange {
    param([string]$Text, [string[]]$Signatures)

    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($signature in $Signatures) {
        $index = $Text.IndexOf($signature, [System.StringComparison]::Ordinal)
        if ($index -ge 0) {
            $matches.Add([pscustomobject]@{ Signature = $signature; Start = $index })
        }
    }

    if ($matches.Count -eq 0) {
        throw ('Java method was not found. Expected one of: ' + ($Signatures -join ' | '))
    }
    if ($matches.Count -gt 1) {
        throw ('Multiple alternative Java method signatures were found: ' + (($matches | ForEach-Object Signature) -join ' | '))
    }

    $start = [int]$matches[0].Start
    $open = $Text.IndexOf('{', $start)
    if ($open -lt 0) { throw "Opening brace not found after $($matches[0].Signature)" }
    $close = Find-MatchingJavaBrace -Text $Text -OpenIndex $open

    return [pscustomobject]@{
        Signature = $matches[0].Signature
        Start = $start
        Open = $open
        End = $close
        Length = $close - $start + 1
    }
}

function Get-JavaBlockRange {
    param([string]$Text, [string]$Needle)

    $start = $Text.IndexOf($Needle, [System.StringComparison]::Ordinal)
    if ($start -lt 0) { throw "Java block needle was not found: $Needle" }
    if ((Count-Ordinal -Text $Text -Needle $Needle) -ne 1) {
        throw "Java block needle is not unique: $Needle"
    }
    $open = $Text.IndexOf('{', $start)
    if ($open -lt 0) { throw "Opening brace not found for Java block: $Needle" }
    $close = Find-MatchingJavaBrace -Text $Text -OpenIndex $open

    return [pscustomobject]@{
        Start = $start
        Open = $open
        End = $close
        Length = $close - $start + 1
    }
}

function Replace-TextRange {
    param([string]$Text, [int]$Start, [int]$End, [string]$Replacement)
    if ($Start -lt 0 -or $End -lt $Start -or $End -ge $Text.Length) {
        throw "Invalid replacement range: $Start..$End / length=$($Text.Length)"
    }
    return $Text.Substring(0, $Start) + $Replacement + $Text.Substring($End + 1)
}

function Read-SourcePreservingEncoding {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $utf8NoBomStrict = New-Object System.Text.UTF8Encoding($false, $true)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $text = $utf8NoBom.GetString($bytes, 3, $bytes.Length - 3)
        $encoding = $utf8Bom
        $encodingName = 'UTF-8 BOM'
    } else {
        try {
            $text = $utf8NoBomStrict.GetString($bytes)
            $encoding = $utf8NoBom
            $encodingName = 'UTF-8'
        } catch {
            $encoding = [System.Text.Encoding]::GetEncoding(949)
            $text = $encoding.GetString($bytes)
            $encodingName = 'MS949'
        }
    }

    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $normalized = $text.Replace("`r`n", "`n")

    return [pscustomobject]@{
        Text = $normalized
        Encoding = $encoding
        EncodingName = $encodingName
        NewLine = $newline
    }
}

function Write-SourcePreservingEncoding {
    param([string]$Path, [string]$NormalizedText, [System.Text.Encoding]$Encoding, [string]$NewLine)
    $output = if ($NewLine -eq "`r`n") { $NormalizedText.Replace("`n", "`r`n") } else { $NormalizedText }
    [System.IO.File]::WriteAllText($Path, $output, $Encoding)
}

function Find-AntCommand {
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:ANT_HOME)) {
        $candidates.Add((Join-Path $env:ANT_HOME 'bin\ant.bat'))
    }
    $command = Get-Command ant.bat -ErrorAction SilentlyContinue
    if ($command) { $candidates.Add($command.Source) }
    $command = Get-Command ant -ErrorAction SilentlyContinue
    if ($command) { $candidates.Add($command.Source) }
    $candidates.Add('C:\apache-ant\bin\ant.bat')
    $candidates.Add('C:\Program Files\Apache Ant\bin\ant.bat')

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }
    throw 'Apache Ant was not found. Set ANT_HOME or add ant.bat to PATH.'
}

function Find-JdkTool {
    param([string]$ToolName)

    $roots = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:JAVA_HOME)) { $roots.Add($env:JAVA_HOME) }
    $roots.Add('C:\Program Files\Java\jdk1.8.0_202')
    $roots.Add('C:\Program Files\Java\jdk1.8.0_361')

    foreach ($root in ($roots | Select-Object -Unique)) {
        $candidate = Join-Path $root ('bin\' + $ToolName + '.exe')
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $env:JAVA_HOME = $root
            if (-not (($env:Path -split ';') -contains (Join-Path $root 'bin'))) {
                $env:Path = (Join-Path $root 'bin') + ';' + $env:Path
            }
            return $candidate
        }
    }

    $command = Get-Command ($ToolName + '.exe') -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw "$ToolName.exe from a JDK was not found."
}

function Invoke-AntCompile {
    param([string]$Ant, [string]$BuildFile, [string]$LogPath)

    Write-Step "Ant clean compile: $BuildFile"
    $global:LASTEXITCODE = 0
    & $Ant -f $BuildFile clean compile 2>&1 | Tee-Object -FilePath $LogPath
    if ($LASTEXITCODE -ne 0) {
        throw "Ant clean compile failed with exit code $LASTEXITCODE."
    }
}

function Find-CompiledControllerClass {
    param([string]$Root)

    $excluded = '\\(deployment_backups|verification|lib|libs|\.git)\\'
    $classes = @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'AutoHuntController.class' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $excluded } |
        Sort-Object LastWriteTimeUtc -Descending
    )
    if ($classes.Count -eq 0) {
        throw 'Compiled AutoHuntController.class was not found after Ant compile.'
    }
    return $classes[0]
}

function Get-CompiledRootFromControllerClass {
    param([string]$ClassPath)
    $suffix = '\l1j\server\AutoHuntSystem\AutoHuntController.class'
    if (-not $ClassPath.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unexpected compiled class path: $ClassPath"
    }
    return $ClassPath.Substring(0, $ClassPath.Length - $suffix.Length)
}

function Invoke-JavapText {
    param([string]$Javap, [string]$Classpath, [string]$ClassName, [string]$OutputPath)

    $lines = @(& $Javap -classpath $Classpath -c -p -s $ClassName 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) {
        throw "javap failed for classpath: $Classpath"
    }
    $text = ($lines -join "`n").Trim()
    [System.IO.File]::WriteAllText($OutputPath, $text + "`n", (New-Object System.Text.UTF8Encoding($true)))
    return $text
}

function Normalize-Javap {
    param([string]$Text)
    $normalized = $Text.Replace("`r`n", "`n")
    $normalized = [regex]::Replace($normalized, '(?m)^Compiled from ".*?"\s*$', '')
    $normalized = [regex]::Replace($normalized, '[ \t]+', ' ')
    $normalized = [regex]::Replace($normalized, '(?m)^\s+$', '')
    return $normalized.Trim()
}

function Patch-ControllerSource {
    param([string]$InputText)

    $text = $InputText
    if ($text.Contains($PatchId)) {
        throw "Source already contains $PatchId. Use the existing candidate or restore the recorded backup before rebuilding."
    }

    $requiredTokens = @(
        'package l1j.server.AutoHuntSystem;',
        'private void toAttackMonster()',
        'private void toAttack(L1Character expectedTarget)',
        'private boolean issueAutoHumanAttack(L1Character target)',
        'AttackActionHandler.executeAutoHuntAttack(owner',
        'skilluse.toWizardAttackSkill(target);'
    )
    foreach ($token in $requiredTokens) {
        if (-not $text.Contains($token)) { throw "Required source token is missing: $token" }
    }

    if (-not [regex]::IsMatch($text, 'private\s+int\s+_lastAutoTripleArrowTargetId\s*=')) {
        $fieldOld = 'private long _lastAutoTripleArrowTime = 0L;'
        $fieldNew = "private long _lastAutoTripleArrowTime = 0L;`n`tprivate int _lastAutoTripleArrowTargetId = 0;"
        $text = Replace-ExactOnce -Text $text -Old $fieldOld -New $fieldNew -Label 'Triple target field insertion'
    }

    $clearRange = Get-JavaMethodRange -Text $text -Signatures @('private void clearAutoTarget(L1Character target)')
    $clearMethod = $text.Substring($clearRange.Start, $clearRange.Length)
    $resetRegex = New-Object System.Text.RegularExpressions.Regex('(?m)^[ \t]*_lastAutoWizardAttackSkillTime\s*=\s*0L;[ \t]*\n')
    $resetCount = $resetRegex.Matches($clearMethod).Count
    if ($resetCount -gt 1) { throw "clearAutoTarget wizard reset count is $resetCount; expected at most 1." }
    if ($resetCount -eq 1) {
        $clearMethod = $resetRegex.Replace(
            $clearMethod,
            "`t`t/* $PatchId: keep the 4-second wizard spell cadence across target changes. */`n",
            1)
        $text = Replace-TextRange -Text $text -Start $clearRange.Start -End $clearRange.End -Replacement $clearMethod
    }

    $invalidRange = Get-JavaMethodRange -Text $text -Signatures @('private boolean clearInvalidAutoTarget(L1Character target)')
    $invalidMethod = $text.Substring($invalidRange.Start, $invalidRange.Length)
    if (-not $invalidMethod.Contains('_lastAutoTripleArrowTargetId = 0;')) {
        $invalidMethod = Replace-ExactOnce -Text $invalidMethod `
            -Old '_lastAutoTripleArrowTime = 0L;' `
            -New "_lastAutoTripleArrowTime = 0L;`n`t`t_lastAutoTripleArrowTargetId = 0;" `
            -Label 'clearInvalidAutoTarget triple target reset'
        $text = Replace-TextRange -Text $text -Start $invalidRange.Start -End $invalidRange.End -Replacement $invalidMethod
    }

    $tripleVoidSignature = 'private void toUseElfTripleArrow(L1Character target)'
    $tripleBooleanSignature = 'private boolean toUseElfTripleArrow(L1Character target)'
    if ($text.Contains($tripleVoidSignature)) {
        $tripleRange = Get-JavaMethodRange -Text $text -Signatures @($tripleVoidSignature)
        $newTripleMethod = @'
private boolean toUseElfTripleArrow(L1Character target) {
        if (owner == null || target == null || !owner.isElf()) {
            _lastAutoTripleArrowTime = 0L;
            _lastAutoTripleArrowTargetId = 0;
            return false;
        }
        if (!SkillCheck.getInstance().CheckSkill(owner, L1SkillId.TRIPLE_ARROW)) {
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
        if (now - _lastAutoTripleArrowTime < AUTO_ELF_TRIPLE_ARROW_INTERVAL) {
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
        $text = Replace-TextRange -Text $text -Start $tripleRange.Start -End $tripleRange.End -Replacement $newTripleMethod
    } elseif (-not $text.Contains($tripleBooleanSignature)) {
        throw 'Neither the void nor boolean Triple Arrow method signature was found.'
    }

    $monsterRange = Get-JavaMethodRange -Text $text -Signatures @('private void toAttackMonster()')
    $monsterMethod = $text.Substring($monsterRange.Start, $monsterRange.Length)
    if (-not $monsterMethod.Contains('if (handoffDeadAutoTarget(target))')) {
        $monsterMethod = Replace-ExactOnce -Text $monsterMethod `
            -Old 'L1Character target = owner.getAutoTarget();' `
            -New "L1Character target = owner.getAutoTarget();`n`t`t`tif (handoffDeadAutoTarget(target)) {`n`t`t`t`treturn;`n`t`t`t}" `
            -Label 'toAttackMonster dead-target handoff'
        $text = Replace-TextRange -Text $text -Start $monsterRange.Start -End $monsterRange.End -Replacement $monsterMethod
    }

    $toAttackRange = Get-JavaMethodRange -Text $text -Signatures @('private void toAttack(L1Character expectedTarget)')
    $toAttackMethod = $text.Substring($toAttackRange.Start, $toAttackRange.Length)
    $elfRange = Get-JavaBlockRange -Text $toAttackMethod -Needle 'if (owner.isElf() && owner.getWeapon() != null'
    $wizardRange = Get-JavaBlockRange -Text $toAttackMethod -Needle 'if (owner.isWizard())'
    if ($wizardRange.Start -le $elfRange.End) { throw 'Wizard block was not located after the elf block.' }

    $newElfBlock = @'
if (owner.isElf() && owner.getWeapon() != null
                    && owner.getWeapon().getItem().getType1() == 20) {

                if (owner.getInventory().getArrow() == null
                        && !owner.getInventory().isStarInfiniteSilverArrowActive()) {
                    return;
                }
                if (!canAutoContinue()
                        || handoffDeadAutoTarget(target)
                        || !isAutoSingleActionTargetReady(target)) {
                    return;
                }
                /*
                 * [STAR_AUTO_RANGED_SINGLE_ACTION_R197_20260917]
                 * One human attack slot emits either Triple Arrow or one basic bow
                 * attack. It never emits both against old/new targets in one tick.
                 */
                if (toUseElfTripleArrow(target)) {
                    markAutoAttackTarget(target);
                    settleDeadAutoTargetAfterAttack(target);
                    clearInvalidAutoTarget(target);
                    return;
                }
                if (!canAutoContinue() || clearInvalidAutoTarget(target)
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

    $newWizardBlock = @'
if (owner.isWizard()) {

                    if (!canAutoContinue()
                            || handoffDeadAutoTarget(target)
                            || !isAutoSingleActionTargetReady(target)) {
                        return;
                    }

                    long now = System.currentTimeMillis();
                    if (now - _lastAutoWizardAttackSkillTime
                            >= AUTO_WIZARD_ATTACK_SKILL_INTERVAL) {
                        /*
                         * [STAR_AUTO_RANGED_SINGLE_ACTION_R197_20260917]
                         * A wizard spell consumes this action slot. Do not issue a
                         * staff/basic attack in the same tick.
                         */
                        AutoHuntSkillUse skilluse = getAutoHuntSkillUse();
                        skilluse.toWizardAttackSkill(target);
                        _lastAutoWizardAttackSkillTime = now;
                        markAutoSkillActionSlot(target);
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

    $replacements = @(
        [pscustomobject]@{ Start = $wizardRange.Start; End = $wizardRange.End; Text = $newWizardBlock },
        [pscustomobject]@{ Start = $elfRange.Start; End = $elfRange.End; Text = $newElfBlock }
    ) | Sort-Object Start -Descending
    foreach ($replacement in $replacements) {
        $toAttackMethod = Replace-TextRange -Text $toAttackMethod `
            -Start $replacement.Start -End $replacement.End -Replacement $replacement.Text
    }
    $text = Replace-TextRange -Text $text -Start $toAttackRange.Start -End $toAttackRange.End -Replacement $toAttackMethod

    $issueRange = Get-JavaMethodRange -Text $text -Signatures @('private boolean issueAutoHumanAttack(L1Character target)')
    $issueMethod = $text.Substring($issueRange.Start, $issueRange.Length)
    if (-not ($issueMethod.Contains('isAutoSingleActionTargetReady(target)') -and
              $issueMethod.Contains('settleDeadAutoTargetAfterAttack(target)'))) {
        $newIssueMethod = @'
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
        $text = Replace-TextRange -Text $text -Start $issueRange.Start -End $issueRange.End -Replacement $newIssueMethod
    }

    $helperParts = New-Object System.Collections.Generic.List[string]

    if (-not $text.Contains('private boolean handoffDeadAutoTarget(L1Character target)')) {
        $helperParts.Add(@'
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

    if (-not $text.Contains('private boolean isAutoSingleActionTargetReady(L1Character target)')) {
        $helperParts.Add(@'
private boolean isAutoSingleActionTargetReady(L1Character target) {
        try {
            if (!canAutoContinue() || target == null
                    || target.isDead() || target.getCurrentHp() <= 0
                    || owner.getAutoTarget() != target
                    || owner.getMapId() != target.getMapId()
                    || L1World.getInstance().findObject(target.getId()) != target
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

    if (-not $text.Contains('private void markAutoSkillActionSlot(L1Character target)')) {
        $helperParts.Add(@'
private void markAutoSkillActionSlot(L1Character target) {
        try {
            long now = System.currentTimeMillis();
            _starLastAutoAttackTargetId = target == null ? 0 : target.getId();
            _starLastAutoAttackTime = now;
            long attackInterval = owner == null ? 0L
                    : owner.getCurrentSpriteInterval(EActionCodes
                            .fromInt(owner.getCurrentWeapon() + 1));
            _autoMoveAfterAttackReadyAt = attackInterval > 0L
                    ? now + attackInterval : now;
            markAutoIdleActivity(now);
        } catch (Exception e) {
            _starLastAutoAttackTargetId = 0;
            _starLastAutoAttackTime = 0L;
            _autoMoveAfterAttackReadyAt = 0L;
        }
    }
'@.Replace("`r`n", "`n").TrimEnd())
    }

    if (-not $text.Contains('private void settleDeadAutoTargetAfterAttack(L1Character defeatedTarget)')) {
        $helperParts.Add(@'
private void settleDeadAutoTargetAfterAttack(L1Character defeatedTarget) {
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

    if ($helperParts.Count -gt 0) {
        $issueRange = Get-JavaMethodRange -Text $text -Signatures @('private boolean issueAutoHumanAttack(L1Character target)')
        $helperText = ($helperParts -join "`n`n`t") + "`n`n`t"
        $text = $text.Substring(0, $issueRange.Start) + $helperText + $text.Substring($issueRange.Start)
    }

    $markerComment = @'
/*
 * [R197_AUTO_RANGED_SINGLE_ACTION_20260917]
 * - Elf: one slot is Triple Arrow OR one basic bow attack.
 * - Wizard: one slot is one attack spell OR one basic attack.
 * - Dead, stale, different-map and not-yet-known targets are rejected again
 *   immediately before the action is emitted.
 * - The wizard 4-second spell clock is not reset by every target change.
 * - Attack range, attack speed, damage, drops, EXP and DB data are unchanged.
 */
'@.Replace("`r`n", "`n").TrimEnd()
    $packageLine = 'package l1j.server.AutoHuntSystem;'
    $text = Replace-ExactOnce -Text $text -Old ($packageLine + "`n") `
        -New ($packageLine + "`n`n" + $markerComment + "`n") `
        -Label 'Patch marker insertion'

    return $text
}

function Assert-PatchedSource {
    param([string]$Text)

    $checks = New-Object System.Collections.Generic.List[string]
    if ((Count-Ordinal -Text $Text -Needle $PatchId) -lt 2) {
        throw "$PatchId markers are incomplete."
    }
    if ($Text.Contains('private void toUseElfTripleArrow(L1Character target)')) {
        throw 'Old void Triple Arrow method still exists.'
    }
    if (-not $Text.Contains('private boolean toUseElfTripleArrow(L1Character target)')) {
        throw 'Boolean Triple Arrow method is missing.'
    }
    foreach ($token in @(
        'private boolean handoffDeadAutoTarget(L1Character target)',
        'private boolean isAutoSingleActionTargetReady(L1Character target)',
        'private void markAutoSkillActionSlot(L1Character target)',
        'private void settleDeadAutoTargetAfterAttack(L1Character defeatedTarget)',
        'owner.knownsObject(target)',
        'settleDeadAutoTargetAfterAttack(target)'
    )) {
        if (-not $Text.Contains($token)) { throw "Patched source token is missing: $token" }
    }

    $clearRange = Get-JavaMethodRange -Text $Text -Signatures @('private void clearAutoTarget(L1Character target)')
    $clearMethod = $Text.Substring($clearRange.Start, $clearRange.Length)
    if ($clearMethod.Contains('_lastAutoWizardAttackSkillTime = 0L;')) {
        throw 'clearAutoTarget still resets the wizard spell clock.'
    }

    $attackRange = Get-JavaMethodRange -Text $Text -Signatures @('private void toAttack(L1Character expectedTarget)')
    $attackMethod = $Text.Substring($attackRange.Start, $attackRange.Length)
    $elf = Get-JavaBlockRange -Text $attackMethod -Needle 'if (owner.isElf() && owner.getWeapon() != null'
    $elfText = $attackMethod.Substring($elf.Start, $elf.Length)
    $tripleIndex = $elfText.IndexOf('toUseElfTripleArrow(target)', [System.StringComparison]::Ordinal)
    $basicIndex = $elfText.IndexOf('issueAutoHumanAttack(target)', [System.StringComparison]::Ordinal)
    if ($tripleIndex -lt 0 -or $basicIndex -lt 0 -or $tripleIndex -ge $basicIndex) {
        throw 'Elf action order audit failed: Triple Arrow must be evaluated before the basic bow attack.'
    }
    if (-not $elfText.Contains('return;')) { throw 'Elf Triple Arrow branch does not terminate its action slot.' }

    $wizard = Get-JavaBlockRange -Text $attackMethod -Needle 'if (owner.isWizard())'
    $wizardText = $attackMethod.Substring($wizard.Start, $wizard.Length)
    $spellIndex = $wizardText.IndexOf('toWizardAttackSkill(target)', [System.StringComparison]::Ordinal)
    $wizardBasicIndex = $wizardText.IndexOf('issueAutoHumanAttack(target)', [System.StringComparison]::Ordinal)
    if ($spellIndex -lt 0 -or $wizardBasicIndex -lt 0 -or $spellIndex -ge $wizardBasicIndex) {
        throw 'Wizard action order audit failed: the spell slot must be resolved before the basic attack fallback.'
    }
    if (-not $wizardText.Contains('markAutoSkillActionSlot(target);')) {
        throw 'Wizard skill action-slot marker is missing.'
    }

    $monsterRange = Get-JavaMethodRange -Text $Text -Signatures @('private void toAttackMonster()')
    $monsterMethod = $Text.Substring($monsterRange.Start, $monsterRange.Length)
    if (-not $monsterMethod.Contains('if (handoffDeadAutoTarget(target))')) {
        throw 'Pre-tick dead-target handoff is missing.'
    }

    $checks.Add('single_action_elf=PASS')
    $checks.Add('single_action_wizard=PASS')
    $checks.Add('dead_target_handoff=PASS')
    $checks.Add('known_object_gate=PASS')
    $checks.Add('wizard_global_4s_clock=PASS')
    return $checks
}

function Update-CandidateJarControllerClasses {
    param(
        [string]$BaseJar,
        [string]$CandidateJar,
        [string]$CompiledClassDirectory
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Copy-Item -LiteralPath $BaseJar -Destination $CandidateJar -Force

    $freshClasses = @(
        Get-ChildItem -LiteralPath $CompiledClassDirectory -File -Filter 'AutoHuntController*.class' |
        Sort-Object Name
    )
    if ($freshClasses.Count -eq 0) { throw 'No freshly compiled AutoHuntController class files were found.' }

    $zip = [System.IO.Compression.ZipFile]::Open($CandidateJar, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $oldEntries = @($zip.Entries | Where-Object { $_.FullName -match $ControllerEntryRegex })
        if ($oldEntries.Count -eq 0) { throw 'Base JAR has no AutoHuntController class entries.' }
        foreach ($entry in $oldEntries) { $entry.Delete() }

        foreach ($classFile in $freshClasses) {
            $entryName = 'l1j/server/AutoHuntSystem/' + $classFile.Name
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip,
                $classFile.FullName,
                $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        $zip.Dispose()
    }

    return $freshClasses
}

$sourceWritten = $false
$backupSource = $null
$reportLines = New-Object System.Collections.Generic.List[string]

try {
    $SourceRoot = Get-FullPathSafe $SourceRoot
    $TestRoot = Get-FullPathSafe $TestRoot
    $ProductionRoot = Get-FullPathSafe $ProductionRoot

    if ($SourceRoot.StartsWith($ProductionRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Production server source/root is not allowed. Select the cumulative development or test source root.'
    }
    if ($TestRoot.StartsWith($ProductionRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Production server root is not allowed as TestRoot.'
    }

    $sourceFile = Join-Path $SourceRoot 'src\l1j\server\AutoHuntSystem\AutoHuntController.java'
    $buildFile = Join-Path $SourceRoot 'build.xml'
    $testJar = Join-Path $TestRoot 'l1jserver.jar'
    $productionJar = Join-Path $ProductionRoot 'l1jserver.jar'

    foreach ($requiredPath in @($sourceFile, $buildFile, $testJar)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Required file was not found: $requiredPath"
        }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $workRoot = Join-Path $TestRoot ("R197_AUTO_RANGED_SINGLE_ACTION_" + $timestamp)
    $evidenceRoot = Join-Path $workRoot 'evidence'
    $candidateRoot = Join-Path $workRoot 'candidate'
    $backupRoot = Join-Path $SourceRoot ("deployment_backups\R197_AUTO_RANGED_SINGLE_ACTION_" + $timestamp)
    New-Item -ItemType Directory -Force -Path $evidenceRoot, $candidateRoot, $backupRoot | Out-Null

    $reportPath = Join-Path $workRoot 'R197_검수보고서.txt'
    $baselineBuildLog = Join-Path $evidenceRoot '01_baseline_compile.log'
    $patchedBuildLog = Join-Path $evidenceRoot '02_patched_compile.log'
    $baselineJarJavap = Join-Path $evidenceRoot '03_test_jar_before.javap.txt'
    $baselineSourceJavap = Join-Path $evidenceRoot '04_source_before.javap.txt'
    $patchedClassJavap = Join-Path $evidenceRoot '05_source_after.javap.txt'
    $candidateJavap = Join-Path $evidenceRoot '06_candidate_jar.javap.txt'
    $candidateJar = Join-Path $candidateRoot 'l1jserver_R197_AUTO_RANGED_SINGLE_ACTION_candidate.jar'

    Write-Step "Source: $sourceFile"
    Write-Step "Test JAR: $testJar"
    Write-Step "Work directory: $workRoot"

    $reportLines.Add("patchId=$PatchId")
    $reportLines.Add("created=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $reportLines.Add("sourceRoot=$SourceRoot")
    $reportLines.Add("testRoot=$TestRoot")
    $reportLines.Add("sourceFile=$sourceFile")
    $reportLines.Add("testJar=$testJar")
    $reportLines.Add("testJarSha256Before=$(Get-Sha256 $testJar)")

    if (Test-Path -LiteralPath $productionJar -PathType Leaf) {
        $productionHash = Get-Sha256 $productionJar
        $reportLines.Add("productionJar=$productionJar")
        $reportLines.Add("productionJarSha256=$productionHash")
        $reportLines.Add("expectedProductionJarSha256=$ExpectedProductionJarSha256")
        if ($productionHash -ne $ExpectedProductionJarSha256) {
            $reportLines.Add('productionReferenceHash=CHANGED_NOT_TOUCHED')
        } else {
            $reportLines.Add('productionReferenceHash=MATCH_NOT_TOUCHED')
        }
    }

    $ant = Find-AntCommand
    $javap = Find-JdkTool -ToolName 'javap'
    [void](Find-JdkTool -ToolName 'javac')
    $reportLines.Add("ant=$ant")
    $reportLines.Add("javap=$javap")
    $reportLines.Add("javaHome=$env:JAVA_HOME")

    $sourceData = Read-SourcePreservingEncoding $sourceFile
    $originalText = $sourceData.Text
    $sourceHashBefore = Get-Sha256 $sourceFile
    $reportLines.Add("sourceEncoding=$($sourceData.EncodingName)")
    $reportLines.Add("sourceSha256Before=$sourceHashBefore")

    $backupSource = Join-Path $backupRoot 'src\l1j\server\AutoHuntSystem\AutoHuntController.java'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupSource) | Out-Null
    Copy-Item -LiteralPath $sourceFile -Destination $backupSource -Force
    $reportLines.Add("sourceBackup=$backupSource")

    Invoke-AntCompile -Ant $ant -BuildFile $buildFile -LogPath $baselineBuildLog
    $baselineClass = Find-CompiledControllerClass -Root $SourceRoot
    $compiledRoot = Get-CompiledRootFromControllerClass -ClassPath $baselineClass.FullName
    $reportLines.Add("compiledRoot=$compiledRoot")

    $jarBeforeText = Invoke-JavapText -Javap $javap -Classpath $testJar -ClassName $ControllerClass -OutputPath $baselineJarJavap
    $sourceBeforeText = Invoke-JavapText -Javap $javap -Classpath $compiledRoot -ClassName $ControllerClass -OutputPath $baselineSourceJavap
    $authorityMatch = (Normalize-Javap $jarBeforeText) -ceq (Normalize-Javap $sourceBeforeText)
    $reportLines.Add("sourceAuthorityBytecodeMatch=$authorityMatch")

    if (-not $authorityMatch -and -not $SkipSourceAuthorityCheck) {
        throw "Current source bytecode does not match the test JAR AutoHuntController. No source was modified. Review $baselineJarJavap and $baselineSourceJavap."
    }
    if (-not $authorityMatch) {
        $reportLines.Add('sourceAuthorityOverride=TRUE')
    }

    Write-Step 'Applying one-file method-level patch...'
    $patchedText = Patch-ControllerSource -InputText $originalText
    $audit = Assert-PatchedSource -Text $patchedText
    foreach ($line in $audit) { $reportLines.Add($line) }

    Write-SourcePreservingEncoding -Path $sourceFile -NormalizedText $patchedText `
        -Encoding $sourceData.Encoding -NewLine $sourceData.NewLine
    $sourceWritten = $true
    $sourceHashAfter = Get-Sha256 $sourceFile
    $reportLines.Add("sourceSha256After=$sourceHashAfter")
    $reportLines.Add('modifiedJavaCount=1')
    $reportLines.Add('modifiedJava=src/l1j/server/AutoHuntSystem/AutoHuntController.java')

    Invoke-AntCompile -Ant $ant -BuildFile $buildFile -LogPath $patchedBuildLog
    $patchedClass = Find-CompiledControllerClass -Root $SourceRoot
    $compiledRootAfter = Get-CompiledRootFromControllerClass -ClassPath $patchedClass.FullName
    $classDirectory = Split-Path -Parent $patchedClass.FullName

    $patchedTextBytecode = Invoke-JavapText -Javap $javap -Classpath $compiledRootAfter -ClassName $ControllerClass -OutputPath $patchedClassJavap
    foreach ($bytecodeToken in @(
        'boolean toUseElfTripleArrow',
        'handoffDeadAutoTarget',
        'isAutoSingleActionTargetReady',
        'markAutoSkillActionSlot',
        'settleDeadAutoTargetAfterAttack'
    )) {
        if (-not $patchedTextBytecode.Contains($bytecodeToken)) {
            throw "Patched bytecode token is missing: $bytecodeToken"
        }
    }

    $freshClasses = Update-CandidateJarControllerClasses -BaseJar $testJar `
        -CandidateJar $candidateJar -CompiledClassDirectory $classDirectory
    $reportLines.Add("candidateJar=$candidateJar")
    $reportLines.Add("candidateJarSha256=$(Get-Sha256 $candidateJar)")
    $reportLines.Add("updatedClassCount=$($freshClasses.Count)")
    foreach ($classFile in $freshClasses) {
        $reportLines.Add("updatedClass=$($classFile.Name):$(Get-Sha256 $classFile.FullName)")
    }

    $candidateText = Invoke-JavapText -Javap $javap -Classpath $candidateJar -ClassName $ControllerClass -OutputPath $candidateJavap
    $candidateMatchesPatched = (Normalize-Javap $candidateText) -ceq (Normalize-Javap $patchedTextBytecode)
    $reportLines.Add("candidateBytecodeMatchesPatchedClass=$candidateMatchesPatched")
    if (-not $candidateMatchesPatched) {
        throw 'Candidate JAR bytecode does not match the freshly compiled patched class.'
    }

    $reportLines.Add('compile=PASS')
    $reportLines.Add('candidateBuild=PASS')
    $reportLines.Add('productionJarModified=NO')
    $reportLines.Add('testJarModified=NO')
    $reportLines.Add('promotionRequired=YES')
    $reportLines.Add('result=PASS')

    [System.IO.File]::WriteAllLines(
        $reportPath,
        $reportLines,
        (New-Object System.Text.UTF8Encoding($true))
    )

    Write-Host ''
    Write-Host '======================================================================'
    Write-Host '[R197 candidate build PASS]'
    Write-Host "Candidate: $candidateJar"
    Write-Host "Report   : $reportPath"
    Write-Host 'Production JAR was not modified.'
    Write-Host 'Test JAR was not modified. Stop the test server, then run the promote script.'
    Write-Host '======================================================================'
} catch {
    $failure = $_.Exception.Message
    try { $reportLines.Add("failure=$failure") } catch {}
    try { $reportLines.Add('result=FAIL') } catch {}

    if ($sourceWritten -and $backupSource -and (Test-Path -LiteralPath $backupSource -PathType Leaf)) {
        try {
            Copy-Item -LiteralPath $backupSource -Destination $sourceFile -Force
            $sourceWritten = $false
            $reportLines.Add('sourceRollback=PASS')
        } catch {
            $reportLines.Add("sourceRollback=FAIL:$($_.Exception.Message)")
        }
    }

    if ($reportPath) {
        try {
            [System.IO.File]::WriteAllLines(
                $reportPath,
                $reportLines,
                (New-Object System.Text.UTF8Encoding($true))
            )
        } catch {}
    }

    Write-Error "R197 patch/build failed: $failure"
    exit 1
}
