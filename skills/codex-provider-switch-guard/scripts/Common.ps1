# This exact catalog was already used in the successful real DeepSeek Desktop test.
$ExpectedCatalogSha256 = 'D47876F3BCA395FE2D9D3C7FC7312282A60DA8A2479DD13B995CB8E0FE2695DD'

$ManagedKeys = @(
    'model',
    'model_provider',
    'preferred_auth_method',
    'forced_login_method',
    'model_reasoning_effort',
    'web_search',
    'model_catalog_json'
)

function Read-Utf8Strict([string]$Path) {
    $enc = New-Object System.Text.UTF8Encoding($false, $true)
    return [System.IO.File]::ReadAllText($Path, $enc)
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Get-NewLine([string]$Text) {
    if ($Text.Contains("`r`n")) { return "`r`n" }
    return "`n"
}

function Normalize-Text([string]$Text) {
    return (($Text -replace "`r`n", "`n").TrimEnd("`n"))
}

function Get-TopValue([string]$Text, [string]$Key) {
    $lines = [regex]::Split($Text, "\r?\n")
    foreach ($line in $lines) {
        if ($line -match '^\s*\[') { break }
        if ($line -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*(.+?)\s*$')) {
            $raw = $Matches[1].Trim()
            if (($raw.StartsWith('"') -and $raw.EndsWith('"')) -or ($raw.StartsWith("'") -and $raw.EndsWith("'"))) {
                return $raw.Substring(1, $raw.Length - 2)
            }
            return $raw
        }
    }
    return $null
}

function Get-TopManagedLines([string]$Text) {
    $lines = [regex]::Split($Text, "\r?\n")
    $out = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        if ($line -match '^\s*\[') { break }

        foreach ($key in $ManagedKeys) {
            if ($line -match ('^\s*' + [regex]::Escape($key) + '\s*=')) {
                [void]$out.Add($line)
                break
            }
        }
    }

    return @($out)
}

function Remove-TopManagedKeys([string]$Text) {
    $nl = Get-NewLine $Text
    $lines = [regex]::Split($Text, "\r?\n")
    $out = New-Object System.Collections.Generic.List[string]
    $inTop = $true

    foreach ($line in $lines) {
        if ($inTop -and $line -match '^\s*\[') {
            $inTop = $false
        }

        $skip = $false
        if ($inTop) {
            foreach ($key in $ManagedKeys) {
                if ($line -match ('^\s*' + [regex]::Escape($key) + '\s*=')) {
                    $skip = $true
                    break
                }
            }
        }

        if (-not $skip) {
            [void]$out.Add($line)
        }
    }

    return ($out -join $nl)
}

function Remove-DeepSeekProvider([string]$Text) {
    $nl = Get-NewLine $Text
    $lines = [regex]::Split($Text, "\r?\n")
    $out = New-Object System.Collections.Generic.List[string]
    $skipping = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*\[model_providers\.deepseek\]\s*$') {
            $skipping = $true
            continue
        }

        if ($skipping -and $line -match '^\s*\[') {
            $skipping = $false
        }

        if (-not $skipping) {
            [void]$out.Add($line)
        }
    }

    return ($out -join $nl)
}

function Get-UnmanagedBody([string]$Text) {
    return (Remove-DeepSeekProvider (Remove-TopManagedKeys $Text))
}

function Test-HasDeepSeekProvider([string]$Text) {
    return [regex]::IsMatch($Text, '(?m)^\s*\[model_providers\.deepseek\]\s*$')
}

function Assert-NoCodexProcesses {
    $names = @('ChatGPT','codex','OpenAI.Codex')
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName })

    if ($procs.Count -gt 0) {
        Write-Host '[BLOCKED] Codex/ChatGPT is still running:'
        $procs | Select-Object ProcessName,Id,Path | Format-Table -AutoSize
        throw 'Fully quit Codex/ChatGPT, including the tray process, then retry.'
    }
}

function Assert-OpenAiMode([string]$Text) {
    $model = Get-TopValue $Text 'model'
    $provider = Get-TopValue $Text 'model_provider'
    $forced = Get-TopValue $Text 'forced_login_method'
    $preferred = Get-TopValue $Text 'preferred_auth_method'
    $catalog = Get-TopValue $Text 'model_catalog_json'

    if ([string]::IsNullOrWhiteSpace($model) -or $model -notmatch '^gpt-') {
        throw ('Current config is not a recognized OpenAI GPT mode. model=' + $model)
    }
    if (-not [string]::IsNullOrWhiteSpace($provider) -and $provider -ne 'openai') {
        throw ('Unexpected model_provider in OpenAI mode: ' + $provider)
    }
    if (-not [string]::IsNullOrWhiteSpace($forced)) {
        throw ('Unexpected forced_login_method in OpenAI mode: ' + $forced)
    }
    if (-not [string]::IsNullOrWhiteSpace($preferred)) {
        throw ('Unexpected preferred_auth_method in OpenAI mode: ' + $preferred)
    }
    if (-not [string]::IsNullOrWhiteSpace($catalog)) {
        throw ('Unexpected model_catalog_json in OpenAI mode: ' + $catalog)
    }
    if (Test-HasDeepSeekProvider $Text) {
        throw 'Current OpenAI config contains a DeepSeek provider section.'
    }

}

function Assert-DeepSeekMode([string]$Text) {
    $model = Get-TopValue $Text 'model'
    $provider = Get-TopValue $Text 'model_provider'
    $forced = Get-TopValue $Text 'forced_login_method'
    $preferred = Get-TopValue $Text 'preferred_auth_method'
    $catalog = Get-TopValue $Text 'model_catalog_json'
    $expectedCatalog = $CatalogPath.Replace('\','/')

    if ($model -notin @('deepseek-flash','deepseek-v4-pro')) {
        throw ('Unexpected DeepSeek model: ' + $model)
    }
    if ($provider -ne 'deepseek') {
        throw ('model_provider is not deepseek: ' + $provider)
    }
    if ($forced -ne 'api') {
        throw ('forced_login_method is not api: ' + $forced)
    }
    if ($preferred -ne 'apikey') {
        throw ('preferred_auth_method is not apikey: ' + $preferred)
    }
    if ($catalog -ne $expectedCatalog) {
        throw ('Unexpected model_catalog_json: ' + $catalog)
    }
    if (-not (Test-HasDeepSeekProvider $Text)) {
        throw 'DeepSeek provider section is missing.'
    }

    foreach ($required in @(
        'base_url = "https://api.deepseek.com/"',
        'wire_api = "responses"',
        'env_key = "DEEPSEEK_API_KEY"',
        'requires_openai_auth = false'
    )) {
        if (-not $Text.Contains($required)) {
            throw ('DeepSeek provider section is missing: ' + $required)
        }
    }

}

function Assert-DeepSeekCatalog {
    if (-not (Test-Path -LiteralPath $CatalogPath)) {
        throw 'Verified DeepSeek catalog is missing. Fail-closed: this tool will not download a replacement automatically.'
    }

    $hash = Get-Sha256 $CatalogPath
    if ($hash -ne $ExpectedCatalogSha256) {
        throw ('DeepSeek catalog hash changed. Expected=' + $ExpectedCatalogSha256 + ' Actual=' + $hash + '. Fail-closed: review the new catalog before switching.')
    }

    try {
        $obj = (Read-Utf8Strict $CatalogPath) | ConvertFrom-Json
    }
    catch {
        throw ('DeepSeek catalog JSON parse failed: ' + $_.Exception.Message)
    }

    $slugs = @($obj.models | ForEach-Object { [string]$_.slug })
    if ($slugs.Count -ne 2 -or
        $slugs -notcontains 'deepseek-flash' -or
        $slugs -notcontains 'deepseek-v4-pro') {
        throw ('Unexpected DeepSeek model set: ' + ($slugs -join ', '))
    }
}

function Build-DeepSeekConfig([string]$OpenAiText) {
    $nl = Get-NewLine $OpenAiText
    $body = Get-UnmanagedBody $OpenAiText
    $body = $body.TrimStart("`r","`n")

    $catalogValue = $CatalogPath.Replace('\','/')
    $top = @(
        'model = "deepseek-flash"',
        'model_provider = "deepseek"',
        'preferred_auth_method = "apikey"',
        'forced_login_method = "api"',
        'model_reasoning_effort = "high"',
        'web_search = "disabled"',
        ('model_catalog_json = "' + $catalogValue + '"')
    ) -join $nl

    $provider = @(
        '[model_providers.deepseek]',
        'name = "deepseek"',
        'base_url = "https://api.deepseek.com/"',
        'wire_api = "responses"',
        'env_key = "DEEPSEEK_API_KEY"',
        'requires_openai_auth = false'
    ) -join $nl

    return $top + $nl + $body.TrimEnd("`r","`n") + $nl + $nl + $provider + $nl
}

function Build-OpenAiRestoreConfig([string]$CurrentDeepSeekText, [string]$SnapshotOpenAiText) {
    $nl = Get-NewLine $CurrentDeepSeekText
    $body = Get-UnmanagedBody $CurrentDeepSeekText
    $body = $body.TrimStart("`r","`n")

    $managed = @(Get-TopManagedLines $SnapshotOpenAiText)
    if ($managed.Count -eq 0) {
        throw 'OpenAI snapshot contains no managed top-level settings.'
    }

    return ($managed -join $nl) + $nl + $body.TrimEnd("`r","`n") + $nl
}

function Replace-ConfigAtomically([string]$CandidateText, [string]$RollbackPath) {
    $configDir = Split-Path -Parent $ConfigPath
    $tmp = Join-Path $configDir ('config.toml.switch-' + [guid]::NewGuid().ToString('N') + '.tmp')

    try {
        Write-Utf8NoBom $tmp $CandidateText
        [System.IO.File]::Replace($tmp, $ConfigPath, $RollbackPath, $true)
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
