$ErrorActionPreference = 'Stop'
Remove-Item Env:DEEPSEEK_API_KEY,Env:OPENAI_API_KEY -ErrorAction SilentlyContinue

# The only executable launched by this test is built from this synthetic source.
$work = Join-Path $PSScriptRoot ('run-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory $work
$scriptCopy = Join-Path $work 'scripts'
Copy-Item "$PSScriptRoot\..\scripts" $scriptCopy -Recurse
. "$scriptCopy\Switch-Provider.ps1"
$policy = Join-Path $scriptCopy 'verified-desktop.json'
$packageVersion = '1.2.3.4'
$packageFullName = "OpenAI.Codex_$($packageVersion)_x64__2p2nqsd0c76g0"
$fakeWindowsApps = Join-Path $work 'WindowsApps'
$fakePackage = Join-Path $fakeWindowsApps $packageFullName
$bin = Join-Path $fakePackage 'app\resources'
$null = New-Item -ItemType Directory $bin -Force
$cli = Join-Path $bin 'codex.exe'
Add-Type -OutputAssembly $cli -OutputType ConsoleApplication -TypeDefinition @"
using System;
using System.IO;
public class Fixture {
    public static int Main(string[] args) {
        string home = Environment.GetEnvironmentVariable("CODEX_HOME");
        return args.Length == 2 && args[0] == "features" && args[1] == "list"
            && Environment.CurrentDirectory == home && File.Exists(Path.Combine(home, "config.toml"))
            && Environment.GetEnvironmentVariable("DEEPSEEK_API_KEY") == null
            && Environment.GetEnvironmentVariable("OPENAI_API_KEY") == null
            && Environment.GetEnvironmentVariable("GUARD_TEST_REJECT") == null
            && ValidateInputs(home) ? 0 : 23;
    }
    static bool ValidateInputs(string home) {
        string config = File.ReadAllText(Path.Combine(home, "config.toml"));
        if (!config.Contains("notify = [")) return false;
        if (!config.Contains("model_provider = \"deepseek\"")) return config.Contains("model = \"gpt-test\"");
        string catalog = Path.Combine(home, "deepseek-models.json");
        return config.Contains(catalog.Replace('\\', '/')) && File.Exists(catalog)
            && File.ReadAllText(catalog).Contains("\"slug\":\"deepseek-v4-pro\"");
    }
}
"@
$fixtureCliHash = Get-Sha256 $cli
$fixtureHome = Join-Path $work 'isolated-home'
$state = Join-Path $fixtureHome 'provider-switch-guard'
$null = New-Item -ItemType Directory $state -Force
$config = Join-Path $fixtureHome 'config.toml'
$catalog = Join-Path $state 'deepseek-models.json'
$fixtureText = (Get-Content "$PSScriptRoot\openai.toml" -Raw)
Write-Utf8NoBom $config $fixtureText
Copy-Item "$PSScriptRoot\catalog.fixture.json" $catalog
$ExpectedCatalogSha256 = Get-Sha256 $catalog
$fixtureCatalogHash = $ExpectedCatalogSha256
# Mock Windows registration; retain real package validation, hashing, and policy.
$registration = [pscustomobject]@{
    PackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'
    Version = $packageVersion
    PackageFullName = $packageFullName
    InstallLocation = $fakePackage
    SignatureKind = 'Store'
    Status = 'Ok'
}
$fixturePackages = @($registration)
function Get-StablePackages { $fixturePackages }
function Get-WindowsAppsRoot { $fakeWindowsApps }
function Get-RegisteredAppxStores { $registeredStore }
function Set-FixtureState([string]$State) {
    $record = @{
        packageFullName = $packageFullName; packageVersion = $packageVersion
        cliSha256 = $fixtureCliHash; catalogSha256 = $ExpectedCatalogSha256
        state = $State; evidence = 'isolated fixture'
    }
    Write-Utf8NoBom $policy (ConvertTo-Json -InputObject @($record))
}
function Assert-NoCodexProcesses {
    if ($env:GUARD_TEST_BUSY) { throw 'Desktop process is running.' }
}
function Invoke-TestAction([string]$Action, [string]$Target = 'DeepSeek', [string]$BackupId, [string]$Approval) {
    Invoke-ProviderGuard -Action $Action -HomePath $fixtureHome -Target $Target -BackupId $BackupId -Approval $Approval
}
function Check([bool]$Condition, [string]$Name) {
    if (!$Condition) { throw "FAIL $Name" }
    Write-Host "PASS $Name"
}
function Reject([scriptblock]$Operation, [string]$Message, [string]$Name) {
    $caught = $null
    try { $null = & $Operation } catch { $caught = $_.Exception.Message }
    Check ($caught -like "*$Message*") "$Name ($caught)"
}

try {
    $env:DEEPSEEK_API_KEY = 'fixture-only-noncredential'
    $env:OPENAI_API_KEY = 'fixture-only-noncredential'
    Remove-Item Env:OPENAI_BASE_URL -ErrorAction SilentlyContinue
    $original = Get-Sha256 $config
    $status = Invoke-TestAction Status
    Check ($status.Mode -eq 'OpenAI' -and $status.Desktop.Cli -ceq $cli -and
        $status.Compatibility -eq 'IdentityConfirmed') 'status and Stable discovery with stale config path'
    Reject { Invoke-TestAction Preflight } 'round trip is required' 'identity alone cannot approve writes'
    Set-FixtureState OfflineParsed
    Check ((Invoke-TestAction Status).Compatibility -eq 'OfflineParsed') 'offline parsed state'
    Reject { Invoke-TestAction DeepSeek -Approval ('0' * 64) } 'round trip is required' 'offline parsed cannot approve writes'
    Set-FixtureState RoundTripVerified
    Check ((Invoke-TestAction Status).VerifiedDesktop) 'round trip admits matching tuple'
    $fixturePackages = @($registration,$registration)
    Check ((Invoke-TestAction Status).Mode -eq 'OpenAI') 'ambiguous package preserves config status'
    Reject { Invoke-TestAction Preflight } 'Expected one registered' 'ambiguous Stable registration'
    $fixturePackages = @($registration)
    $registration.InstallLocation = $work
    Reject { Invoke-TestAction Preflight } 'installation path' 'untrusted registration path'
    $registration.InstallLocation = $fakePackage
    $registeredStore = Join-Path $work 'secondary-appx'
    $null = New-Item -ItemType Directory $registeredStore
    $redirected = Join-Path $registeredStore $packageFullName
    Copy-Item -LiteralPath $fakePackage -Destination $redirected -Recurse
    # Mock only the package-root junction descriptor. The sandbox prohibits
    # creating a real junction. The binary, volume path and hashes are real fixtures.
    function Get-Item {
        param([string]$LiteralPath,[switch]$Force)
        if ($LiteralPath -ceq $fakePackage) {
            return [pscustomobject]@{
                Attributes = [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint
                LinkType = 'Junction'
                Target = $redirected
            }
        }
        Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force
    }
    try {
        Check ((Invoke-TestAction Status).VerifiedDesktop) 'registered AppX volume junction permitted'
        $registeredStore = Join-Path $work 'unregistered'
        Reject { Invoke-TestAction Preflight } 'registered AppX store' 'unregistered junction rejected'
    }
    finally { Remove-Item Function:Get-Item }
    $beforeFiles = @(Get-ChildItem $fixtureHome -Recurse -File | ForEach-Object { $_.FullName + (Get-Sha256 $_.FullName) })
    $plan = Invoke-TestAction Preflight
    $afterFiles = @(Get-ChildItem $fixtureHome -Recurse -File | ForEach-Object { $_.FullName + (Get-Sha256 $_.FullName) })
    Check (($plan.Destination -eq 'DeepSeek') -and !(Compare-Object $beforeFiles $afterFiles)) 'preflight read-only'
    Reject { Invoke-TestAction DeepSeek } 'matching preflight' 'approval required'
    $env:GUARD_TEST_BUSY = '1'
    Reject { Invoke-TestAction DeepSeek -Approval $plan.Approval } 'process is running' 'active Desktop blocks apply'
    Remove-Item Env:GUARD_TEST_BUSY
    Remove-Item Env:DEEPSEEK_API_KEY
    Reject { Invoke-TestAction Preflight } 'DEEPSEEK_API_KEY is missing' 'missing key'
    $env:DEEPSEEK_API_KEY = 'fixture-only-noncredential'
    Add-Content -LiteralPath $catalog ' '
    Reject { Invoke-TestAction Preflight } 'catalog hash changed' 'unknown catalog'
    Copy-Item "$PSScriptRoot\catalog.fixture.json" $catalog -Force
    $cliBytes = [IO.File]::ReadAllBytes($cli)
    [IO.File]::WriteAllBytes($cli, [byte[]]($cliBytes + 0))
    Reject { Invoke-TestAction DeepSeek -Approval $plan.Approval } 'round trip is required' 'changed CLI hash rejects old approval'
    [IO.File]::WriteAllBytes($cli,$cliBytes)
    $unknown = $registration.PSObject.Copy()
    $unknown.Version = '1.2.3.5'
    $unknown.PackageFullName = 'OpenAI.Codex_1.2.3.5_x64__2p2nqsd0c76g0'
    $unknown.InstallLocation = Join-Path $fakeWindowsApps $unknown.PackageFullName
    $unknownBin = Join-Path $unknown.InstallLocation 'app\resources'
    $null = New-Item -ItemType Directory $unknownBin -Force
    Copy-Item $cli (Join-Path $unknownBin 'codex.exe')
    $fixturePackages = @($unknown)
    Reject { Invoke-TestAction DeepSeek -Approval $plan.Approval } 'round trip is required' 'unknown package version with same CLI hash'
    $fixturePackages = @($registration)
    $invalidForms = [ordered]@{
        'multiline array' = "notify = [" + [Environment]::NewLine + "]"
        'inline table' = 'notify = { x = 1 }'
        'array table' = '[[entries]]'
        'nested array' = "notify = [['nested']]"
        'managed array' = 'model = ["gpt-test"]'
    }
    foreach ($form in $invalidForms.Keys) {
        Write-Utf8NoBom $config ($invalidForms[$form] + [Environment]::NewLine + $fixtureText)
        $message = if ($form -eq 'managed array') { 'Managed settings must use scalars' } else { 'Unsupported TOML' }
        Reject { Invoke-TestAction Preflight } $message "$form rejected"
    }
    Write-Utf8NoBom $config ($fixtureText + [Environment]::NewLine + "# drift")
    Reject { Invoke-TestAction DeepSeek -Approval $plan.Approval } 'matching preflight' 'stale approval'
    Write-Utf8NoBom $config $fixtureText
    $env:GUARD_TEST_REJECT = '1'
    Reject { Invoke-TestAction DeepSeek -Approval $plan.Approval } 'parser rejected' 'parser failure'
    Remove-Item Env:GUARD_TEST_REJECT
    Check ((Get-Sha256 $config) -eq $original) 'parser failure preserved original'

    $held = [IO.File]::Open($config,'Open','Read','Read')
    try {
        Reject { Invoke-TestAction DeepSeek -Approval $plan.Approval } 'used by another process' 'atomic write failure'
    }
    finally { $held.Dispose() }
    Check ((Get-Sha256 $config) -eq $original) 'failed replace preserved original'
    $held = [IO.File]::Open((Join-Path $state 'writer.lock'),'Open','ReadWrite','None')
    try { Reject { Invoke-TestAction DeepSeek -Approval $plan.Approval } 'guard lock' 'writer contention' }
    finally { $held.Dispose() }

    $deep = Invoke-TestAction DeepSeek -Approval $plan.Approval
    Check ((Invoke-TestAction Status).Mode -eq 'DeepSeek') 'switch to DeepSeek'
    Reject { Invoke-TestAction DeepSeek -Approval $plan.Approval } 'Already in' 'repeated switch'
    $fixturePackages = @()
    $backups = @(Invoke-TestAction Backups)
    Check (@($backups | Where-Object Valid).Count -eq 1) 'backup verifies with stale CLI path and no package discovery'
    $fixturePackages = @($registration)
    Check (@($backups | Where-Object Valid).Count -eq 1) 'verified backup plus incomplete failed checkpoint'
    $deepConfig = Join-Path $work 'deep.toml'
    Copy-Item $config $deepConfig
    Check ((Read-Utf8Strict $config).Contains('notify = ["C:\\fixture\\notify.exe", "arg,#[]"]')) 'notify preserved in DeepSeek config'
    $drift = (Read-Utf8Strict $config).Replace('shell_tool = false','shell_tool = true')
    Write-Utf8NoBom $config $drift
    $plan = Invoke-TestAction Preflight OpenAI
    $openai = Invoke-TestAction OpenAI -Approval $plan.Approval
    Check (((Invoke-TestAction Status).Mode -eq 'OpenAI') -and
        ((Read-Utf8Strict $config) -match 'shell_tool = true')) 'switch to OpenAI preserved unrelated changes'

    $plan = Invoke-TestAction Preflight Restore -BackupId $openai.BackupId
    $null = Invoke-TestAction Restore -BackupId $openai.BackupId -Approval $plan.Approval
    Check ((Invoke-TestAction Status).Mode -eq 'DeepSeek') 'restore verified DeepSeek backup'
    $plan = Invoke-TestAction Preflight Restore -BackupId $deep.BackupId
    $null = Invoke-TestAction Restore -BackupId $deep.BackupId -Approval $plan.Approval
    Check (((Invoke-TestAction Status).Mode -eq 'OpenAI') -and
        ((Read-Utf8Strict $config) -match 'shell_tool = true')) 'restore verified OpenAI backup preserved drift'

    $beforeConfig = Join-Path $work 'original.toml'
    Write-Utf8NoBom $beforeConfig $fixtureText
    & python -I -B "$PSScriptRoot\verify_toml.py" $beforeConfig $deepConfig $config
    Check ($LASTEXITCODE -eq 0) 'independent TOML semantic verification'
    $backupPath = Join-Path $state "backups\$($deep.BackupId)\before.toml"
    Add-Content -LiteralPath $backupPath '# tampered'
    Reject { Invoke-TestAction Preflight Restore -BackupId $deep.BackupId } 'checksum mismatch' 'tampered backup'
    Write-Utf8NoBom $config ($fixtureText + [Environment]::NewLine + 'secret = "fixture-inline"')
    Reject { Invoke-TestAction Preflight } 'Inline credential' 'inline credential field rejected'
    Write-Utf8NoBom $config $fixtureText
    Check (@(Get-ChildItem $fixtureHome -Recurse -File | Select-String -SimpleMatch 'fixture-only-noncredential').Count -eq 0) 'no test credentials persisted'
    Write-Host 'All isolated tests passed.'
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
