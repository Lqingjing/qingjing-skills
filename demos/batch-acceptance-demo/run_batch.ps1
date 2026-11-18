param(
    [Parameter(Mandatory = $true)][string]$ChapterDir,
    [int]$MaxRestarts = 2
)

$ErrorActionPreference = 'Stop'
$py = (Get-Command python).Source
$ChapterDir = (Resolve-Path $ChapterDir).Path
$tools = Get-ChildItem $ChapterDir -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'bulk.py') } |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $tools) { $tools = $ChapterDir }
$config = Join-Path $tools 'batch-config.json'
$bulk = Join-Path $tools 'bulk.py'
$finalize = Join-Path $tools 'finalize.py'
$progressPath = Join-Path $ChapterDir 'progress.json'
$coveragePath = Join-Path $ChapterDir 'coverage.json'
$resultPath = Join-Path $ChapterDir 'batch_result.json'
$attemptPath = Join-Path $ChapterDir 'batch_attempt.json'
$logPath = Join-Path $ChapterDir 'supervisor.log'

function Write-Log([string]$message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message
    Add-Content -Path $logPath -Value $line -Encoding UTF8
    Write-Output $line
}

function Save-Report($report, [string]$path) {
    $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
    if ([IO.File]::Exists($path)) {
        $backup = "$temp.previous"
        [IO.File]::Replace($temp, $path, $backup)
        [IO.File]::Delete($backup)
    }
    else { [IO.File]::Move($temp, $path) }
}

function Save-CoverageSnapshot([string]$source) {
    $path = Join-Path $ChapterDir "coverage-$([guid]::NewGuid().ToString('N')).json"
    [IO.File]::Copy($source, $path, $false)
    return $path
}

function Protect-LegacyAcceptance {
    if (-not (Test-Path -LiteralPath $resultPath)) { return }
    $previous = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($previous.status -notin 'complete','complete_with_pending') { return }
    $previousCoverage = [IO.Path]::GetFullPath((Join-Path $ChapterDir 'coverage.json'))
    if ($previous.coverage) {
        $reference = if ([IO.Path]::IsPathRooted($previous.coverage)) { $previous.coverage } else { Join-Path $ChapterDir $previous.coverage }
        $previousCoverage = [IO.Path]::GetFullPath($reference)
    }
    if ($previousCoverage -ne $coveragePath) { return }
    if (-not (Test-Path -LiteralPath $previousCoverage -PathType Leaf)) { Fail 'legacy_coverage_missing' }
    $archive = Join-Path $ChapterDir "batch-result-legacy-$([guid]::NewGuid().ToString('N')).json"
    [IO.File]::Copy($resultPath, $archive, $false)
    $previous | Add-Member -NotePropertyName coverage -NotePropertyValue (Save-CoverageSnapshot $previousCoverage) -Force
    Save-Report $previous $resultPath
}

function Fail([string]$reason, [int]$code = 2) {
    $payload = [ordered]@{
        status      = if ($reason -eq 'paused_by_user') { 'paused' } else { 'failed' }
        chapter     = $cfg.chapter
        saved       = $snapshot.saved
        stop        = $snapshot.stop
        progress    = $progressPath
        next_action = 'review_reason_and_progress'
        remaining_numbers = $script:remaining
        identity_issues = $identityIssues
        reason      = $reason
        chapter_dir = $ChapterDir
        finished_at = (Get-Date -Format 's')
    }
    Save-Report $payload $attemptPath
    Write-Log "FAILED $reason"
    exit $code
}

trap {
    $script:remaining = $null
    Fail ("execution_error:" + $_.Exception.Message)
}
Write-Log "validate start dir=$ChapterDir"
foreach ($p in @($config, $bulk, $finalize)) {
    if (-not (Test-Path $p)) { Fail "missing_file:$p" }
}
$cfg = Get-Content -Path $config -Raw -Encoding UTF8 | ConvertFrom-Json
$total = [int]$cfg.total

$numbers = if ($cfg.numbers) { @($cfg.numbers) } else { 1..$total }
if ($total -lt 1 -or @($numbers).Count -ne $total -or @($numbers | Sort-Object -Unique).Count -ne $total) {
    Fail 'invalid_expected_numbers'
}
function Read-Remaining {
    foreach ($n in $numbers) {
        $record = Join-Path $ChapterDir ('records/{0:D3}.json' -f [int]$n)
        if (-not (Test-Path -LiteralPath $record)) { $n; continue }
        $row = Get-Content -LiteralPath $record -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($row.number -ne $n -or $row.chapter -ne $cfg.chapter) { Fail "record_identity_mismatch:$n" 3 }
    }
}
function Check-Stop {
    if ($snapshot.stop.reason -eq 'paused_by_user' -or $snapshot.status -match 'paus') { Fail 'paused_by_user' }
    if ($script:remaining.Count -and $snapshot.stop.reason -match '^TimeoutExpired:' ) { return }
    if ($snapshot.stop -or $snapshot.status -eq 'stopped') {
        Fail "collector_stopped:$($snapshot.stop.reason)" 3
    }
}
$script:remaining = $null
$script:remaining = @(Read-Remaining)
$snapshot = $null
if (Test-Path $progressPath) {
    $snapshot = Get-Content $progressPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($snapshot.stop.reason -ne 'paused_by_user' -and ($snapshot.status -notmatch 'paus' -or $snapshot.stop.reason)) { Check-Stop }
}
$restarts = 0
$env:BATCH_CONFIG = $config
$finishedStates = @('captured_pending_source_audit', 'complete', 'closed', 'closed_with_visual_review_pending')
while ($script:remaining.Count -or $snapshot.status -notin $finishedStates) {
    Write-Log "collector start restarts=$restarts remaining=$($script:remaining.Count)"
    $script:remaining = $null
    & $py $bulk
    $exitCode = $LASTEXITCODE
    $snapshot = Get-Content $progressPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:remaining = @(Read-Remaining)
    Check-Stop
    if ($snapshot.status -match 'paus') { Fail 'paused_by_user' }
    if ($exitCode -ne 0 -and -not ($script:remaining.Count -and $snapshot.stop.reason -match '^TimeoutExpired:')) { Fail "collector_exit:$exitCode" }
    if (-not $script:remaining.Count) {
        if ($snapshot.status -notin $finishedStates) { Fail "unverified_end:$($snapshot.status)" }
        break
    }
    if ($restarts -ge $MaxRestarts) { Fail 'restarts_exhausted' }
    $restarts++
    Start-Sleep -Seconds 15
}
function Read-SourceText($xml, [string]$id) {
    $xml.SelectNodes("//node[@resource-id='demo:id/$id']") |
        ForEach-Object { $_.GetAttribute('text').Trim() } | Where-Object { $_ } | Select-Object -Unique
}

function Test-QuestionEvidence($row, [int]$number) {
    $stem = @($row.stem | ForEach-Object { ([string]$_).Trim() }) -join "`n"
    if (-not $stem.Trim()) { return 'record_stem_missing' }
    $matched = $false
    foreach ($reference in $row.evidence) {
        if (-not $reference) { continue }
        $path = if ([IO.Path]::IsPathRooted($reference)) { $reference } else { Join-Path $ChapterDir $reference }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try { [xml]$xml = Get-Content -LiteralPath $path -Raw -Encoding UTF8 } catch { continue }
        $sourceNumber = @(Read-SourceText $xml 'pagenumtv')
        $sourceStem = @(Read-SourceText $xml 'titletv') -join "`n"
        if ($sourceNumber.Count -ne 1 -or $sourceNumber[0] -notmatch "^\s*$number\s*/\s*$total\s*$" -or $sourceStem -cne $stem) { continue }
        $titles = @(Read-SourceText $xml 'questiondetails_tv_title')
        if (-not $titles.Count) { continue }
        if ($titles.Count -ne 1 -or $titles[0] -cne ([string]$cfg.chapter).Trim()) {
            return 'source_chapter_mismatch'
        }
        $matched = $true
    }
    if (-not $matched) { return 'source_evidence_missing_or_unlinked' }
}

$identityIssues = @(foreach ($n in $numbers) {
    $path = Join-Path $ChapterDir ('records/{0:D3}.json' -f [int]$n)
    $row = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $issue = Test-QuestionEvidence $row $n
    if ($issue) { [ordered]@{ number = $n; reason = $issue } }
})
if ($identityIssues.Count) { Fail 'chapter_source_review_required' 6 }

Protect-LegacyAcceptance
Write-Log 'finalize start'
& $py $finalize
if ($LASTEXITCODE -ne 0) { Fail "finalize_failed:$LASTEXITCODE" 4 }

$coverage = Get-Content $coveragePath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($key in 'questions','missing_numbers','source_mismatches','pending','target_comments_saved') {
    if ($null -eq $coverage.$key) { Fail "incomplete_coverage:$key" 5 }
}
$missing = @($coverage.missing_numbers).Count
$sourceMismatch = @($coverage.source_mismatches).Count
$pending = @($coverage.pending).Count
$visual = $coverage.media_visual_pending
$visualState = if ($visual -isnot [array]) { 'unknown' } elseif ($visual.Count) { 'pending' } else { 'clear' }
$status = 'complete'
$code = 0
if ($pending) { $status = 'complete_with_pending' }
if ($coverage.questions -ne $total -or $missing -gt 0 -or $sourceMismatch -gt 0) { $status = 'quality_gate_failed'; $code = 5 }

$payload = [ordered]@{
    status            = $status
    chapter           = $cfg.chapter
    total             = $total
    saved             = [int]$coverage.questions
    comments          = [int]$coverage.target_comments_saved
    missing_numbers   = $missing
    source_mismatches = $sourceMismatch
    pending           = $pending
    pending_details   = $coverage.pending
    pending_issue_count = @($coverage.pending | ForEach-Object { $_.issues } | Where-Object { $_ }).Count
    media_visual_pending = $visual
    media_visual_status = $visualState
    remaining_numbers = $coverage.missing_numbers
    next_action       = if ($code) { 'review_coverage' } elseif ($pending) { 'supplement_pending_details' } elseif ($visualState -eq 'unknown') { 'check_media_visual_status' } elseif ($visualState -eq 'pending') { 'review_media' } else { 'archive' }
    restarts          = $restarts
    finalized         = $true
    coverage          = $coveragePath
    finished_at       = (Get-Date -Format 's')
}
if (-not $code) {
    $payload.coverage = Save-CoverageSnapshot $coveragePath
    Save-Report $payload $resultPath
}
Save-Report $payload $attemptPath
Write-Log "RESULT status=$status saved=$($coverage.questions) comments=$($coverage.target_comments_saved) missing=$missing source_mismatch=$sourceMismatch pending=$pending"
exit $code
