[CmdletBinding()]
param(
    [ValidateSet('Status','Preflight','DeepSeek','OpenAI','Backups','Restore')]
    [string]$Action = 'Status',
    [string]$HomePath,
    [ValidateSet('DeepSeek','OpenAI','Restore')]
    [string]$Target = 'DeepSeek',
    [string]$BackupId,
    [string]$Approval
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

function Assert-LocalPath([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':')) {
        throw 'Use an absolute local drive path.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    for ($part = $full; $part; $part = Split-Path -Path $part -Parent) {
        if (Test-Path -LiteralPath $part) {
            if ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Junctions and symbolic links are unsupported.'
            }
        }
    }
}

function Get-StablePackages {
    Get-AppxPackage -Name OpenAI.Codex
}

function Get-WindowsAppsRoot {
    Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WindowsApps'
}

function Get-RegisteredAppxStores {
    Get-AppxVolume | Where-Object { !$_.IsOffline } | Select-Object -ExpandProperty PackageStorePath
}

function Get-DesktopIdentity {
    $packages = @(Get-StablePackages | Where-Object {
        $_.PackageFamilyName -ceq 'OpenAI.Codex_2p2nqsd0c76g0'
    })
    if ($packages.Count -ne 1) { throw 'Expected one registered Codex Desktop Stable package.' }
    $package = $packages[0]
    if ([string]$package.SignatureKind -cne 'Store' -or [string]$package.Status -cne 'Ok') {
        throw 'Expected a healthy Store-signed Stable package.'
    }
    $version = [string]$package.Version
    $fullName = [string]$package.PackageFullName
    if ($version -notmatch '^\d+\.\d+\.\d+\.\d+$' -or
        $fullName -notmatch ('^OpenAI\.Codex_' + [regex]::Escape($version) + '_(x64|arm64)__2p2nqsd0c76g0$')) {
        throw 'Unexpected Stable package identity.'
    }
    $root = Join-Path (Get-WindowsAppsRoot) $fullName
    if (![string]::Equals($root,[string]$package.InstallLocation,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected Stable package installation path.'
    }
    Assert-LocalPath (Split-Path -Parent $root)
    $entry = Get-Item -LiteralPath $root -Force
    $binaryRoot = $root
    if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $targets = @($entry.Target)
        $expectedRoots = @(Get-RegisteredAppxStores | ForEach-Object { Join-Path $_ $fullName })
        if ($entry.LinkType -cne 'Junction' -or $targets.Count -ne 1 -or
            !$targets[0] -or $targets[0] -notin $expectedRoots) {
            throw 'Stable package redirects outside its registered AppX store.'
        }
        $binaryRoot = $targets[0]
    }
    $cli = Join-Path $root 'app\resources\codex.exe'
    Assert-LocalPath (Join-Path $binaryRoot 'app\resources\codex.exe')
    if (!(Test-Path -LiteralPath $cli -PathType Leaf)) { throw 'Stable package CLI is missing.' }
    [pscustomobject]@{
        PackageFullName = $fullName
        PackageVersion = $version
        Cli = $cli
        BinaryRoot = $binaryRoot
        Sha256 = Get-Sha256 $cli
    }
}

function Get-CompatibilityState($Identity) {
    $records = @((Get-Content -LiteralPath "$PSScriptRoot\verified-desktop.json" -Raw | ConvertFrom-Json) |
        Where-Object {
            $_.packageFullName -ceq $Identity.PackageFullName -and
            $_.packageVersion -ceq $Identity.PackageVersion -and
            $_.cliSha256 -ceq $Identity.Sha256 -and
            $_.catalogSha256 -ceq $ExpectedCatalogSha256
        })
    if ($records.Count -eq 0) { return 'IdentityConfirmed' }
    if ($records.Count -ne 1 -or $records[0].state -cnotin @('IdentityConfirmed','OfflineParsed','RoundTripVerified')) {
        throw 'Ambiguous or invalid Desktop compatibility record.'
    }
    if ($records[0].state -ne 'IdentityConfirmed' -and
        [string]::IsNullOrWhiteSpace($records[0].evidence)) {
        throw 'Desktop compatibility record is missing evidence.'
    }
    return $records[0].state
}

function Assert-ConfigShape([string]$Text) {
    # Keep arrays opaque to the editor. Only a single physical line of simple
    # scalar elements can qualify, and managed settings still require scalars.
    $segment = '(?:[A-Za-z0-9_-]+|''[^'']+''|"[^"\\]+")'
    $table = '^\s*\[' + $segment + '(?:\.' + $segment + ')*\]\s*$'
    $scalar = '(?:"(?:[^"\\\x00-\x1F]|\\["\\btnfr])*"|''[^''\x00-\x1F]*''|true|false|[+-]?(?:0|[1-9][0-9]*))'
    $assignment = '^\s*([A-Za-z0-9_-]+)[ \t]*=[ \t]*(' + $scalar + '|\[[ \t]*(?:' +
        $scalar + '(?:[ \t]*,[ \t]*' + $scalar + ')*[ \t]*,?[ \t]*)?\])[ \t]*$'
    $scope = $null
    $seen = @{}
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^\s*(#.*)?$') { continue }
        if ($line -match $table) {
            $section = $line.Trim()
            if ($section -match '(?i)model_providers|profiles' -and $section -cne '[model_providers.deepseek]') {
                throw 'Custom provider and profile tables are unsupported.'
            }
            if ($seen.ContainsKey($section)) { throw 'Duplicate TOML table.' }
            $seen[$section] = $true
            $scope = $section
            continue
        }
        if ($line -notmatch $assignment -or $line -match '"""|''''''') {
            throw 'Unsupported TOML syntax. Use the supported single-line configuration subset.'
        }
        $parsed = [regex]::Match($line,$assignment)
        $key = $parsed.Groups[1].Value
        if ($parsed.Groups[2].Value.StartsWith('[') -and
            ((!$scope -and $key -in $ManagedKeys) -or $scope -ceq '[model_providers.deepseek]')) {
            throw 'Managed settings must use scalars.'
        }
        if ($key -match '^(?:api_key|bearer_token|experimental_bearer_token|access_token|refresh_token|password|secret)$') {
            throw 'Inline credential fields are unsupported.'
        }
        if ($key -match '^(?:openai_base_url|profile|model_providers|profiles)$') {
            throw 'Custom OpenAI routing and profiles are unsupported.'
        }
        $slot = "$scope/$key"
        if ($seen.ContainsKey($slot)) { throw 'Duplicate TOML field.' }
        $seen[$slot] = $true
    }
}

function Get-Mode([string]$Text) {
    Assert-ConfigShape $Text
    try {
        if ((Get-TopValue $Text 'model_provider') -ceq 'deepseek') {
            Assert-DeepSeekMode $Text
            $block = [regex]::Match($Text, '(?m)^\[model_providers\.deepseek\]\r?\n(?:(?!^\s*\[)[\s\S])*').Value
            $canonical = (Build-DeepSeekConfig $Text) -split '(?m)(?=^\[model_providers\.deepseek\])'
            if ((Normalize-Text $block).TrimEnd() -cne (Normalize-Text $canonical[-1]).TrimEnd()) {
                throw 'Unknown DeepSeek provider section.'
            }
            return 'DeepSeek'
        }
        Assert-OpenAiMode $Text
        return 'OpenAI'
    }
    catch { throw 'Unrecognized provider configuration or Desktop CLI path.' }
}

function Read-Backup([string]$Id) {
    if ($Id -notmatch '^\d{21}-[a-f0-9]{32}$') { throw 'Invalid backup ID.' }
    $folder = Join-Path $BackupRoot $Id
    $file = Join-Path $folder 'before.toml'
    $info = Join-Path $folder 'checkpoint.json'
    Assert-LocalPath $file
    Assert-LocalPath $info
    if (!(Test-Path -LiteralPath $file -PathType Leaf) -or !(Test-Path -LiteralPath $info -PathType Leaf)) {
        throw 'Backup is missing or incomplete.'
    }
    try { $meta = (Read-Utf8Strict $info) | ConvertFrom-Json } catch { throw 'Invalid backup metadata.' }
    $hash = Get-Sha256 $file
    if ($meta.schema -ne 1 -or $meta.beforeSha256 -cne $hash) { throw 'Backup checksum mismatch.' }
    $body = Read-Utf8Strict $file
    $mode = Get-Mode $body
    if ($meta.mode -cne $mode) { throw 'Backup provider mismatch.' }
    [pscustomobject]@{ Id = $Id; Hash = $hash; Text = $body; Mode = $mode }
}

function Get-BackupIds {
    if (Test-Path -LiteralPath $BackupRoot -PathType Container) {
        Get-ChildItem -LiteralPath $BackupRoot -Directory |
            Where-Object { $_.Name -match '^\d{21}-[a-f0-9]{32}$' } |
            Sort-Object Name -Descending | Select-Object -ExpandProperty Name
    }
}

function Get-OpenAiBackup {
    foreach ($id in Get-BackupIds) {
        $backup = Read-Backup $id
        if ($backup.Mode -eq 'OpenAI') { return $backup }
    }
    throw 'No verified OpenAI backup. Inspect Backups and use Restore with a valid ID.'
}

function Get-TextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','') }
    finally { $sha.Dispose() }
}

function New-SwitchPlan([string]$Operation, [string]$Id) {
    $before = Get-Sha256 $ConfigPath
    $current = Read-Utf8Strict $ConfigPath
    if ((Get-Sha256 $ConfigPath) -ne $before) { throw 'Config changed during read.' }
    $mode = Get-Mode $current
    $identity = Get-DesktopIdentity
    if ((Get-CompatibilityState $identity) -cne 'RoundTripVerified') {
        throw 'Desktop identity is not admitted for production writes. A verified round trip is required.'
    }
    $cli = $identity.Cli
    $cliHash = $identity.Sha256

    $backup = $null
    $destination = $Operation
    if ($Operation -eq 'Restore') {
        $backup = Read-Backup $Id
        $destination = $backup.Mode
    }
    elseif ($mode -eq $destination) {
        throw 'Already in the requested provider mode. No changes needed.'
    }
    elseif ($Operation -eq 'OpenAI') {
        $backup = Get-OpenAiBackup
    }

    if ($destination -eq 'DeepSeek') {
        if (!(Test-Path Env:DEEPSEEK_API_KEY)) { throw 'DEEPSEEK_API_KEY is missing from the shell environment.' }
        Assert-DeepSeekCatalog
        $candidate = Build-DeepSeekConfig $current
        if ($backup) {
            $model = Get-TopValue $backup.Text 'model'
            $candidate = $candidate -replace '(?m)^model = "deepseek-flash"', ('model = "' + $model + '"')
            if ((Normalize-Text ((Get-TopManagedLines $candidate) -join "`n")) -cne
                (Normalize-Text ((Get-TopManagedLines $backup.Text) -join "`n"))) {
                throw 'Backup DeepSeek fields differ from the supported generated layout.'
            }
        }
    }
    else {
        if ($env:OPENAI_BASE_URL) { throw 'Custom OPENAI_BASE_URL is unsupported.' }
        $candidate = Build-OpenAiRestoreConfig $current $backup.Text
    }

    if ((Get-Mode $candidate) -ne $destination -or
        (Normalize-Text (Get-UnmanagedBody $current)).Trim("`r","`n") -cne
        (Normalize-Text (Get-UnmanagedBody $candidate)).Trim("`r","`n")) {
        throw 'Provider or unmanaged configuration validation failed.'
    }

    $after = Get-TextHash $candidate
    if ($before -ceq $after) { throw 'The selected backup would make no changes.' }
    $token = Get-TextHash (@($ConfigPath,$Operation,$backup.Id,$backup.Hash,$before,$after,$identity.PackageFullName,$identity.BinaryRoot,$cli,$cliHash,
        $ExpectedCatalogSha256) | ConvertTo-Json -Compress)
    [pscustomobject]@{
        Mode = $mode; Destination = $destination; Before = $before; After = $after
        Candidate = $candidate; Cli = $cli; CliHash = $cliHash; Approval = $token; Backup = $backup.Id
        Changes = @($ManagedKeys | Where-Object {
            (Get-TopValue $current $_) -cne (Get-TopValue $candidate $_)
        })
        ProviderSectionChanges = (Test-HasDeepSeekProvider $current) -ne (Test-HasDeepSeekProvider $candidate)
    }
}

function Show-SwitchPlan($Plan) {
    [pscustomobject]@{
        ConfigPath = $ConfigPath
        Current = $Plan.Mode
        Destination = $Plan.Destination
        Service = if ($Plan.Destination -eq 'DeepSeek') { 'DeepSeek (https://api.deepseek.com/)' } else { 'OpenAI' }
        ChangedFields = $Plan.Changes
        DeepSeekProviderSectionChanges = $Plan.ProviderSectionChanges
        BackupId = $Plan.Backup
        BeforeSha256 = $Plan.Before
        Approval = $Plan.Approval
    }
}

function Test-IsolatedCli($Plan, [string]$Scratch) {
    $candidate = $Plan.Candidate
    if ($Plan.Destination -eq 'DeepSeek') {
        $copy = Join-Path $Scratch 'deepseek-models.json'
        Copy-Item -LiteralPath $CatalogPath -Destination $copy
        if ((Get-Sha256 $copy) -cne $ExpectedCatalogSha256) { throw 'Catalog changed before parsing.' }
        $catalogLine = 'model_catalog_json = "' + $CatalogPath.Replace('\','/') + '"'
        $copyLine = 'model_catalog_json = "' + $copy.Replace('\','/') + '"'
        $candidate = $candidate.Replace($catalogLine,$copyLine)
    }
    Write-Utf8NoBom (Join-Path $Scratch 'config.toml') $candidate
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Plan.Cli
    $start.Arguments = 'features list'
    $start.WorkingDirectory = $Scratch
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['CODEX_HOME'] = $Scratch
    $start.EnvironmentVariables.Remove('DEEPSEEK_API_KEY')
    $start.EnvironmentVariables.Remove('OPENAI_API_KEY')
    if ((Get-Sha256 $Plan.Cli) -cne $Plan.CliHash) { throw 'Desktop CLI changed before parsing.' }
    $proc = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (!$proc.WaitForExit(30000)) {
            $proc.Kill()
            $null = $proc.WaitForExit(5000)
            throw 'Isolated CLI parser timed out.'
        }
        if ($proc.ExitCode -ne 0) { throw 'Isolated CLI parser rejected the candidate.' }
    }
    finally { $proc.Dispose() }
}

function Invoke-ProviderGuard {
    [CmdletBinding()]
    param([string]$Action, [string]$HomePath, [string]$Target = 'DeepSeek', [string]$BackupId, [string]$Approval)

    if (!$HomePath -or $HomePath -match '["''\r\n]') { throw 'Specify a valid absolute HomePath explicitly.' }
    Assert-LocalPath $HomePath
    $homeDir = [IO.Path]::GetFullPath($HomePath).TrimEnd('\')
    if ($homeDir -match '^[A-Za-z]:$') { throw 'A drive root cannot be used as CODEX_HOME.' }
    $ConfigPath = Join-Path $homeDir 'config.toml'
    $SwitchRoot = Join-Path $homeDir 'provider-switch-guard'
    $BackupRoot = Join-Path $SwitchRoot 'backups'
    $CatalogPath = Join-Path $SwitchRoot 'deepseek-models.json'
    $LockPath = Join-Path $SwitchRoot 'writer.lock'
    foreach ($path in @($ConfigPath,$BackupRoot,$CatalogPath,$LockPath)) { Assert-LocalPath $path }
    if (!(Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw 'config.toml is missing.' }

    if ($Action -eq 'Status') {
        $config = Read-Utf8Strict $ConfigPath
        $mode = Get-Mode $config
        $identity = $null
        $compatibility = 'Unconfirmed'
        $reason = $null
        try {
            $identity = Get-DesktopIdentity
            $compatibility = Get-CompatibilityState $identity
        }
        catch { $reason = $_.Exception.Message }
        return [pscustomobject]@{ ConfigPath = $ConfigPath; Mode = $mode
            Desktop = $identity; Compatibility = $compatibility; DesktopIssue = $reason
            VerifiedDesktop = $compatibility -ceq 'RoundTripVerified'
            CatalogMatches = (Test-Path -LiteralPath $CatalogPath -PathType Leaf) -and
                ((Get-Sha256 $CatalogPath) -eq $ExpectedCatalogSha256) }
    }
    if ($Action -eq 'Backups') {
        foreach ($id in Get-BackupIds) {
            try {
                $backup = Read-Backup $id
                [pscustomobject]@{ Id = $id; Valid = $true; Mode = $backup.Mode; Sha256 = $backup.Hash }
            }
            catch { [pscustomobject]@{ Id = $id; Valid = $false; Reason = $_.Exception.Message } }
        }
        return
    }
    if ($Action -eq 'Preflight') { return (Show-SwitchPlan (New-SwitchPlan $Target $BackupId)) }
    if ($Action -notin @('DeepSeek','OpenAI','Restore')) { throw 'Unsupported operation.' }

    $plan = New-SwitchPlan $Action $BackupId
    if (!$Approval -or $Approval -cne $plan.Approval) {
        Show-SwitchPlan $plan
        throw 'Explicit confirmation and the matching preflight Approval token are required.'
    }
    Assert-NoCodexProcesses
    New-Item -ItemType Directory -Path $SwitchRoot -Force | Out-Null
    try { $lock = [IO.File]::Open($LockPath,'OpenOrCreate','ReadWrite','None') }
    catch { throw 'Another writer holds the guard lock, or the lock path is inaccessible.' }

    try {
        $lockedPlan = New-SwitchPlan $Action $BackupId
        if ($lockedPlan.Approval -cne $Approval) { throw 'Plan changed. Run preflight again.' }
        $scratch = Join-Path $SwitchRoot ('parse-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $scratch | Out-Null
        try { Test-IsolatedCli $lockedPlan $scratch }
        finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
        Assert-NoCodexProcesses

        $finalPlan = New-SwitchPlan $Action $BackupId
        if ($finalPlan.Approval -cne $Approval) { throw 'Plan changed during parsing. Run preflight again.' }
        $id = [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfffffff') + '-' + [guid]::NewGuid().ToString('N')
        $folder = Join-Path $BackupRoot $id
        New-Item -ItemType Directory -Path $folder | Out-Null
        $checkpoint = @{ schema = 1; beforeSha256 = $finalPlan.Before; mode = $finalPlan.Mode }
        Write-Utf8NoBom (Join-Path $folder 'checkpoint.json') ($checkpoint | ConvertTo-Json)
        $rollback = Join-Path $folder 'before.toml'
        if ((Get-Sha256 $ConfigPath) -ne $finalPlan.Before) { throw 'Config changed before replacement.' }
        Replace-ConfigAtomically $finalPlan.Candidate $rollback
        $actual = Get-Sha256 $ConfigPath
        $saved = Get-Sha256 $rollback
        if ($actual -ne $finalPlan.After -or $saved -ne $finalPlan.Before) {
            throw "Concurrent config activity detected. Inspect current config and backup $id before recovery."
        }
        [pscustomobject]@{ Mode = $finalPlan.Destination; BackupId = $id; ConfigSha256 = $actual }
    }
    finally { $lock.Dispose() }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ProviderGuard @PSBoundParameters
}
