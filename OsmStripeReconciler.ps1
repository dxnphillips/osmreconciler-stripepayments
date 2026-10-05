#Requires -Version 7.2
<#
.SYNOPSIS
    Interactive local tool for reconciling Stripe payments into OSM Accountancy.

.DESCRIPTION
    Run it from PowerShell 7 on Windows:  pwsh .\OsmStripeReconciler.ps1
    Move through the menus with the Up and Down arrow keys, Enter to select,
    Esc to go back.

    Current stage: setup and exploration.
      - Setup stores secrets encrypted in a SecretStore vault (never in plain text).
      - OSM login opens your browser and catches the authorisation code locally.
      - Stripe balance transactions can be downloaded for a date range.
      - Any OSM or Stripe GET URL can be tried and its output saved, so the
        matching rules and OSM import calls can be worked out from real data.

    Nothing in this version writes to OSM or Stripe. Every API call is a GET,
    apart from the OSM OAuth token exchange.

.PARAMETER VerboseLogging
    Shows DEBUG lines (API URLs, rate limit headers). Secrets are never logged.

.NOTES
    Requires PowerShell 7.2+ and the Microsoft.PowerShell.SecretManagement and
    Microsoft.PowerShell.SecretStore modules (Setup offers to install them).
#>

[CmdletBinding()]
param(
    [switch]$VerboseLogging
)

$ErrorActionPreference = 'Stop'

#region -- CONSTANTS AND PATHS ------------------------------------------------

$script:AppName      = 'OsmStripeReconciler'
$script:VaultName    = 'OsmStripeReconciler'
$script:OsmBaseUrl   = 'https://www.onlinescoutmanager.co.uk'
$script:OsmHost      = 'www.onlinescoutmanager.co.uk'
$script:StripeBase   = 'https://api.stripe.com'
$script:StripeHost   = 'api.stripe.com'
$script:ApiDelayMs   = 500

$appRoot = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME '.config' }
$script:AppDir     = Join-Path $appRoot $script:AppName
$script:OutputDir  = Join-Path $script:AppDir 'Output'
$script:ConfigPath = Join-Path $script:AppDir 'config.json'

# Secret names inside the vault
$script:SecretOsmClientSecret = 'OsmClientSecret'
$script:SecretOsmRefreshToken = 'OsmRefreshToken'
$script:SecretStripeKey       = 'StripeRestrictedKey'

# In memory only, never written to disk
$script:OsmAccessToken  = $null
$script:OsmTokenExpires = [datetime]::MinValue

$script:UkTz = try { [TimeZoneInfo]::FindSystemTimeZoneById('GMT Standard Time') }
               catch { [TimeZoneInfo]::FindSystemTimeZoneById('Europe/London') }

$script:UkCulture = [Globalization.CultureInfo]::GetCultureInfo('en-GB')

#endregion


#region -- LOGGING ------------------------------------------------------------

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR','ACTION','DEBUG')]
        [string]$Level = 'INFO'
    )
    if ($Level -eq 'DEBUG' -and -not $VerboseLogging) { return }
    $colour = switch ($Level) {
        'OK'     { 'Green' }
        'WARN'   { 'Yellow' }
        'ERROR'  { 'Red' }
        'ACTION' { 'Cyan' }
        'DEBUG'  { 'DarkGray' }
        default  { 'Gray' }
    }
    Write-Host "[$Level] $Message" -ForegroundColor $colour
}

#endregion


#region -- MENU AND INPUT HELPERS ---------------------------------------------

function Show-Menu {
    <#
        Arrow key menu. Returns the selected index, or -1 for Esc.
        Number keys 1 to 9 jump straight to that option.
        Falls back to a numbered prompt when input is redirected.
    #>
    param(
        [string]$Title,
        [string[]]$Options,
        [string[]]$Header = @(),
        [int]$Selected = 0
    )

    if ([Console]::IsInputRedirected) {
        Write-Host "`n$Title"
        for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host "  $($i + 1). $($Options[$i])" }
        $answer = Read-Host 'Choose a number (blank to go back)'
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return $n - 1 }
        return -1
    }

    $previousCursor = $true
    try { $previousCursor = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch {}
    try {
        while ($true) {
            Clear-Host
            Write-Host ''
            Write-Host "  $Title" -ForegroundColor Cyan
            Write-Host "  $('=' * $Title.Length)" -ForegroundColor DarkCyan
            foreach ($line in $Header) { Write-Host "  $line" -ForegroundColor DarkGray }
            Write-Host ''
            for ($i = 0; $i -lt $Options.Count; $i++) {
                if ($i -eq $Selected) {
                    Write-Host "  > $($Options[$i]) " -ForegroundColor Black -BackgroundColor Cyan
                } else {
                    Write-Host "    $($Options[$i])"
                }
            }
            Write-Host ''
            Write-Host '  Up/Down to move, Enter to select, Esc to go back' -ForegroundColor DarkGray

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $Selected = if ($Selected -le 0) { $Options.Count - 1 } else { $Selected - 1 } }
                'DownArrow' { $Selected = if ($Selected -ge $Options.Count - 1) { 0 } else { $Selected + 1 } }
                'Home'      { $Selected = 0 }
                'End'       { $Selected = $Options.Count - 1 }
                'Enter'     { return $Selected }
                'Escape'    { return -1 }
                default {
                    $digit = 0
                    if ([int]::TryParse("$($key.KeyChar)", [ref]$digit) -and $digit -ge 1 -and $digit -le $Options.Count) {
                        $Selected = $digit - 1
                    }
                }
            }
        }
    }
    finally {
        try { [Console]::CursorVisible = $previousCursor } catch {}
    }
}

function Wait-ForKey {
    param([string]$Message = 'Press any key to return to the menu...')
    Write-Host ''
    Write-Host $Message -ForegroundColor DarkGray
    if ([Console]::IsInputRedirected) { $null = Read-Host; return }
    $null = [Console]::ReadKey($true)
}

function Read-YesNo {
    param([string]$Question, [bool]$Default = $false)
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $a = (Read-Host "$Question $suffix").Trim().ToLower()
    if ($a -eq '') { return $Default }
    return $a -in @('y','yes')
}

function ConvertTo-PlainText {
    param([securestring]$Secure)
    return (ConvertFrom-SecureString -SecureString $Secure -AsPlainText)
}

#endregion


#region -- CONFIG (non secret settings only) ----------------------------------

function Get-DefaultConfig {
    return [ordered]@{
        OsmClientId    = ''
        OsmRedirectUri = 'http://localhost:53682/callback'
        OsmScope       = ''
    }
}

function Get-Config {
    $cfg = Get-DefaultConfig
    if (Test-Path $script:ConfigPath) {
        try {
            $saved = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
        } catch { Write-Log "Could not read config file, using defaults: $_" -Level WARN }
    }
    return $cfg
}

function Save-Config {
    param($Cfg)
    if (-not (Test-Path $script:AppDir)) { $null = New-Item -ItemType Directory -Path $script:AppDir }
    $Cfg | ConvertTo-Json | Set-Content -Path $script:ConfigPath -Encoding utf8
    Write-Log "Settings saved to $script:ConfigPath" -Level DEBUG
}

#endregion


#region -- SECRET STORAGE -----------------------------------------------------

function Test-SecretModules {
    $needed = @('Microsoft.PowerShell.SecretManagement','Microsoft.PowerShell.SecretStore')
    return @($needed | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
}

function Install-SecretModules {
    $missing = Test-SecretModules
    if ($missing.Count -eq 0) { Write-Log 'Secret storage modules are installed.' -Level OK; return $true }

    Write-Log "Missing modules: $($missing -join ', ')" -Level WARN
    Write-Log 'These are official Microsoft modules from the PowerShell Gallery, installed for your user only.' -Level INFO
    if (-not (Read-YesNo 'Install them now?' $true)) { return $false }
    foreach ($m in $missing) {
        Install-Module -Name $m -Scope CurrentUser -Repository PSGallery
    }
    Write-Log 'Modules installed.' -Level OK
    return $true
}

function Initialize-Vault {
    if ((Test-SecretModules).Count -gt 0) {
        throw 'Secret storage modules are not installed. Run Setup > Install or check secret storage first.'
    }
    Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
    Import-Module Microsoft.PowerShell.SecretStore -ErrorAction Stop
    if (-not (Get-SecretVault -Name $script:VaultName -ErrorAction SilentlyContinue)) {
        Write-Log "Creating encrypted vault '$script:VaultName'. You will be asked to choose a vault password." -Level ACTION
        Register-SecretVault -Name $script:VaultName -ModuleName Microsoft.PowerShell.SecretStore
    }
}

function Test-VaultRegistered {
    if ((Test-SecretModules).Count -gt 0) { return $false }
    Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
    return [bool](Get-SecretVault -Name $script:VaultName -ErrorAction SilentlyContinue)
}

function Get-StoredSecret {
    param([string]$Name)
    Initialize-Vault
    try { return Get-Secret -Name $Name -Vault $script:VaultName -AsPlainText -ErrorAction Stop }
    catch { return $null }
}

function Test-StoredSecret {
    param([string]$Name)
    Initialize-Vault
    return [bool](Get-SecretInfo -Name $Name -Vault $script:VaultName -ErrorAction SilentlyContinue)
}

function Set-StoredSecret {
    param([string]$Name, $Value)
    Initialize-Vault
    Set-Secret -Name $Name -Vault $script:VaultName -Secret $Value
}

function Remove-StoredSecret {
    param([string]$Name)
    Initialize-Vault
    if (Test-StoredSecret $Name) { Remove-Secret -Name $Name -Vault $script:VaultName }
}

#endregion


#region -- OSM API ------------------------------------------------------------
# OAuth 2.0 authorisation code flow. Bearer token in the Authorization header.
# All POST bodies MUST be application/x-www-form-urlencoded (never JSON).

function New-OAuthState {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return ([Convert]::ToBase64String($bytes) -replace '\+','-' -replace '/','_' -replace '=','')
}

function Get-OsmAuthUrl {
    param($Cfg, [string]$State)
    $q = @(
        'response_type=code'
        "client_id=$([Uri]::EscapeDataString($Cfg.OsmClientId))"
        "redirect_uri=$([Uri]::EscapeDataString($Cfg.OsmRedirectUri))"
        "scope=$([Uri]::EscapeDataString($Cfg.OsmScope))"
        "state=$State"
    ) -join '&'
    return "$script:OsmBaseUrl/oauth/authorize?$q"
}

function Test-IsLoopbackHttp {
    param([string]$RedirectUri)
    try { $u = [Uri]$RedirectUri } catch { return $false }
    return ($u.Scheme -eq 'http' -and $u.Host -in @('localhost','127.0.0.1'))
}

function Wait-OsmAuthCodeViaListener {
    <# Listens on the loopback redirect URI and returns the code once OSM redirects back. #>
    param([string]$RedirectUri, [string]$AuthUrl, [string]$ExpectedState, [int]$TimeoutMinutes = 5)

    $u = [Uri]$RedirectUri
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://$($u.Host):$($u.Port)/")
    $listener.Start()
    try {
        Write-Log 'Opening your browser to log in to OSM...' -Level ACTION
        Write-Log "If it does not open, copy this URL into your browser:`n$AuthUrl" -Level INFO
        Start-Process $AuthUrl

        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        while ($true) {
            $task = $listener.GetContextAsync()
            while (-not $task.Wait(500)) {
                if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutMinutes minutes waiting for the OSM login." }
            }
            $ctx = $task.Result
            # Ignore anything that is not the callback path (for example favicon requests)
            if ($ctx.Request.Url.AbsolutePath -ne $u.AbsolutePath) {
                $ctx.Response.StatusCode = 404; $ctx.Response.Close(); continue
            }

            $query = [System.Web.HttpUtility]::ParseQueryString($ctx.Request.Url.Query)
            $ok = $query['code'] -and $query['state'] -eq $ExpectedState
            $html = if ($ok) { '<h2>OSM login complete.</h2><p>You can close this tab and return to PowerShell.</p>' }
                    else { '<h2>OSM login failed.</h2><p>Return to PowerShell for details.</p>' }
            $bytes = [Text.Encoding]::UTF8.GetBytes("<html><body style='font-family:sans-serif'>$html</body></html>")
            $ctx.Response.ContentType = 'text/html; charset=utf-8'
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $ctx.Response.Close()

            if ($query['error']) { throw "OSM returned an error: $($query['error']) $($query['error_description'])" }
            if ($query['state'] -ne $ExpectedState) { throw 'State did not match. Login aborted for safety; please try again.' }
            if (-not $query['code']) { throw 'No authorisation code was returned.' }
            return $query['code']
        }
    }
    finally {
        $listener.Stop(); $listener.Close()
    }
}

function Read-OsmAuthCodeManually {
    <# Fallback for non loopback redirect URIs: user pastes the URL they were sent to. #>
    param([string]$AuthUrl, [string]$ExpectedState)
    Write-Log 'Opening your browser to log in to OSM...' -Level ACTION
    Write-Log "If it does not open, copy this URL into your browser:`n$AuthUrl" -Level INFO
    Start-Process $AuthUrl
    Write-Log 'After clicking Authorise the page will fail to load. That is expected.' -Level INFO
    $pasted = (Read-Host 'Paste the FULL address from the browser bar').Trim()
    try { $uri = [Uri]$pasted } catch { throw 'That did not look like a URL.' }
    $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
    if ($query['error']) { throw "OSM returned an error: $($query['error']) $($query['error_description'])" }
    if ($query['state'] -ne $ExpectedState) { throw 'State did not match. Login aborted for safety; please try again.' }
    if (-not $query['code']) { throw 'No code found in that URL.' }
    return $query['code']
}

function Connect-Osm {
    $cfg = Get-Config
    if (-not $cfg.OsmClientId) { throw 'Set the OSM client ID and secret first.' }
    if (-not $cfg.OsmScope)    { throw 'Set the OSM scope first.' }
    $secret = Get-StoredSecret $script:SecretOsmClientSecret
    if (-not $secret) { throw 'OSM client secret is not saved. Set it first.' }

    $state = New-OAuthState
    $authUrl = Get-OsmAuthUrl -Cfg $cfg -State $state
    $code = if (Test-IsLoopbackHttp $cfg.OsmRedirectUri) {
        Wait-OsmAuthCodeViaListener -RedirectUri $cfg.OsmRedirectUri -AuthUrl $authUrl -ExpectedState $state
    } else {
        Read-OsmAuthCodeManually -AuthUrl $authUrl -ExpectedState $state
    }

    Write-Log 'Exchanging authorisation code for tokens...' -Level INFO
    $r = Invoke-RestMethod -Uri "$script:OsmBaseUrl/oauth/token" -Method Post `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type='authorization_code'; client_id=$cfg.OsmClientId; client_secret=$secret; code=$code; redirect_uri=$cfg.OsmRedirectUri }
    if (-not $r.access_token)  { throw 'Token exchange failed: no access_token returned.' }
    if (-not $r.refresh_token) { throw 'Token exchange failed: no refresh_token returned.' }

    Set-StoredSecret $script:SecretOsmRefreshToken ($r.refresh_token.Trim())
    $script:OsmAccessToken  = ($r.access_token -replace '[^\x20-\x7E]','').Trim()
    $script:OsmTokenExpires = (Get-Date).AddSeconds([int]($r.expires_in ?? 3600) - 60)
    Write-Log 'OSM connected. Refresh token saved to the encrypted vault.' -Level OK
}

function Get-OsmAccessToken {
    if ($script:OsmAccessToken -and (Get-Date) -lt $script:OsmTokenExpires) { return $script:OsmAccessToken }

    $cfg = Get-Config
    $secret  = Get-StoredSecret $script:SecretOsmClientSecret
    $refresh = Get-StoredSecret $script:SecretOsmRefreshToken
    if (-not $cfg.OsmClientId -or -not $secret) { throw 'OSM client ID or secret not set. Run Setup.' }
    if (-not $refresh) { throw 'Not connected to OSM. Run Setup > Connect to OSM.' }

    Write-Log 'Refreshing OSM access token...' -Level DEBUG
    $r = Invoke-RestMethod -Uri "$script:OsmBaseUrl/oauth/token" -Method Post `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type='refresh_token'; client_id=$cfg.OsmClientId; client_secret=$secret; refresh_token=$refresh }
    if (-not $r.access_token) { throw 'OSM token refresh failed. Run Setup > Connect to OSM again.' }

    # OSM rotates refresh tokens; save the new one straight away
    if ($r.refresh_token -and $r.refresh_token -ne $refresh) {
        Set-StoredSecret $script:SecretOsmRefreshToken ($r.refresh_token.Trim())
        Write-Log 'New OSM refresh token saved.' -Level DEBUG
    }
    $script:OsmAccessToken  = ($r.access_token -replace '[^\x20-\x7E]','').Trim()
    $script:OsmTokenExpires = (Get-Date).AddSeconds([int]($r.expires_in ?? 3600) - 60)
    return $script:OsmAccessToken
}

function Resolve-OsmUri {
    <# Accepts a path like /ext/... or a full URL, and refuses anything not on the OSM host over HTTPS. #>
    param([string]$PathOrUrl)
    $p = $PathOrUrl.Trim()
    if ($p -notmatch '^https?://') { $p = $script:OsmBaseUrl + '/' + $p.TrimStart('/') }
    $u = [Uri]$p
    if ($u.Scheme -ne 'https' -or $u.Host -ne $script:OsmHost) {
        throw "Refusing to send the OSM token to '$($u.Scheme)://$($u.Host)'. Only $script:OsmBaseUrl is allowed."
    }
    return $u.AbsoluteUri
}

function Invoke-OsmGet {
    param([string]$PathOrUrl)
    $uri = Resolve-OsmUri $PathOrUrl
    $token = Get-OsmAccessToken
    Write-Log "OSM GET $uri" -Level DEBUG
    $headers = $null
    $r = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ Authorization = "Bearer $token" } -ResponseHeadersVariable headers
    Start-Sleep -Milliseconds $script:ApiDelayMs
    if ($headers -and $headers['X-RateLimit-Remaining']) {
        $remaining = [int]("$($headers['X-RateLimit-Remaining'])")
        Write-Log "OSM rate limit remaining: $remaining" -Level DEBUG
        if ($remaining -lt 20) { Write-Log "OSM rate limit is low ($remaining left). Slow down for a while." -Level WARN }
    }
    return $r
}

#endregion


#region -- STRIPE API ---------------------------------------------------------
# Uses a restricted, read only key. Full secret keys (sk_) are refused.

function Get-StripeKey {
    $k = Get-StoredSecret $script:SecretStripeKey
    if (-not $k) { throw 'Stripe key not set. Run Setup > Set Stripe restricted key.' }
    return $k
}

function Resolve-StripeUri {
    param([string]$PathOrUrl)
    $p = $PathOrUrl.Trim()
    if ($p -notmatch '^https?://') { $p = $script:StripeBase + '/' + $p.TrimStart('/') }
    $u = [Uri]$p
    if ($u.Scheme -ne 'https' -or $u.Host -ne $script:StripeHost) {
        throw "Refusing to send the Stripe key to '$($u.Scheme)://$($u.Host)'. Only $script:StripeBase is allowed."
    }
    if (-not $u.AbsolutePath.StartsWith('/v1/')) { throw 'Stripe paths must start with /v1/' }
    return $u.AbsoluteUri
}

function Invoke-StripeGet {
    param([string]$PathOrUrl, [hashtable]$Query)
    $uri = Resolve-StripeUri $PathOrUrl
    $key = Get-StripeKey
    Write-Log "Stripe GET $uri" -Level DEBUG
    $params = @{ Uri = $uri; Method = 'Get'; Headers = @{ Authorization = "Bearer $key" } }
    if ($Query) { $params.Body = $Query }
    return Invoke-RestMethod @params
}

function Get-StripeList {
    <# Follows Stripe pagination (has_more / starting_after) and returns every item. #>
    param([string]$Path, [hashtable]$Query = @{})
    $all = [System.Collections.Generic.List[object]]::new()
    $q = @{} + $Query
    $q['limit'] = 100
    while ($true) {
        $page = Invoke-StripeGet $Path $q
        foreach ($item in $page.data) { $all.Add($item) }
        Write-Log "  Fetched $($all.Count) so far..." -Level INFO
        if (-not $page.has_more -or $page.data.Count -eq 0) { break }
        $q['starting_after'] = $page.data[-1].id
    }
    return ,$all
}

#endregion


#region -- DATES --------------------------------------------------------------

function ConvertTo-UkTime {
    param([long]$UnixSeconds)
    $utc = [DateTimeOffset]::FromUnixTimeSeconds($UnixSeconds).UtcDateTime
    return [TimeZoneInfo]::ConvertTimeFromUtc($utc, $script:UkTz)
}

function ConvertTo-UnixFromUkDate {
    <# UK midnight at the start of the given date, as Unix seconds. #>
    param([datetime]$UkDate)
    $local = [datetime]::SpecifyKind($UkDate.Date, [DateTimeKind]::Unspecified)
    $utc = [TimeZoneInfo]::ConvertTimeToUtc($local, $script:UkTz)
    return [DateTimeOffset]::new($utc, [TimeSpan]::Zero).ToUnixTimeSeconds()
}

function New-DateRange {
    param([datetime]$From, [datetime]$To)   # both inclusive UK dates
    return [pscustomobject]@{ From = $From.Date; To = $To.Date }
}

function Get-DefaultRange {
    $ukToday = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $script:UkTz).Date
    $firstThisMonth = [datetime]::new($ukToday.Year, $ukToday.Month, 1)
    return New-DateRange $firstThisMonth.AddMonths(-1) $firstThisMonth.AddDays(-1)
}

function Format-Range {
    param($Range)
    return "$($Range.From.ToString('dd/MM/yyyy')) to $($Range.To.ToString('dd/MM/yyyy')) (UK time, inclusive)"
}

function Read-UkDate {
    param([string]$Prompt)
    while ($true) {
        $s = (Read-Host "$Prompt (dd/mm/yyyy)").Trim()
        $d = [datetime]::MinValue
        if ([datetime]::TryParseExact($s, @('dd/MM/yyyy','d/M/yyyy'), $script:UkCulture, 'None', [ref]$d)) { return $d }
        Write-Log 'Please use the format dd/mm/yyyy, for example 01/09/2026.' -Level WARN
    }
}

#endregion


#region -- OUTPUT HELPERS -----------------------------------------------------

function Get-OutputPath {
    param([string]$Prefix, [string]$Extension)
    if (-not (Test-Path $script:OutputDir)) { $null = New-Item -ItemType Directory -Path $script:OutputDir -Force }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    return Join-Path $script:OutputDir "${Prefix}_$stamp.$Extension"
}

function Protect-CsvValue {
    <# Stops spreadsheet formula injection when the CSV is opened in Excel. #>
    param($Value)
    if ($Value -is [string] -and $Value -match '^[=+\-@\t\r]') { return "'" + $Value }
    return $Value
}

function Save-JsonOutput {
    param($Data, [string]$Prefix)
    $path = Get-OutputPath $Prefix 'json'
    $json = $Data | ConvertTo-Json -Depth 50
    Set-Content -Path $path -Value $json -Encoding utf8
    return @{ Path = $path; Json = $json }
}

function Show-Preview {
    param([string]$Json, [int]$Lines = 60)
    $all = $Json -split "`r?`n"
    $all | Select-Object -First $Lines | ForEach-Object { Write-Host $_ }
    if ($all.Count -gt $Lines) { Write-Host "... ($($all.Count - $Lines) more lines in the saved file)" -ForegroundColor DarkGray }
}

#endregion


#region -- ACTIONS ------------------------------------------------------------

function Invoke-TestConnections {
    Write-Log 'Testing OSM...' -Level ACTION
    try {
        $r = Invoke-OsmGet '/oauth/resource'
        if ($r.PSObject.Properties.Name -contains 'status' -and $r.status -eq $false) { throw "OSM error: $($r | ConvertTo-Json -Compress)" }
        Write-Log "OSM OK. Logged in as $($r.data.full_name)." -Level OK
        Write-Log 'Sections this login can see:' -Level INFO
        foreach ($s in $r.data.sections) {
            Write-Log "  $($s.group_name): $($s.section_name)  (section_id=$($s.section_id), type=$($s.section_type))" -Level INFO
        }
        if ($r.data.PSObject.Properties.Name -contains 'scopes') {
            Write-Log "Granted scopes: $($r.data.scopes -join ', ')" -Level INFO
        }
    } catch { Write-Log "OSM test failed: $_" -Level ERROR }

    Write-Host ''
    Write-Log 'Testing Stripe...' -Level ACTION
    try {
        $r = Invoke-StripeGet '/v1/balance_transactions' @{ limit = 1 }
        Write-Log "Stripe OK. Read access to balance transactions works ($(@($r.data).Count) sample row)." -Level OK
    } catch { Write-Log "Stripe test failed: $_" -Level ERROR }
}

function Invoke-StripeDownload {
    param($Range)
    $gte = ConvertTo-UnixFromUkDate $Range.From
    $lt  = ConvertTo-UnixFromUkDate $Range.To.AddDays(1)
    Write-Log "Downloading Stripe balance transactions for $(Format-Range $Range)..." -Level ACTION

    $txns = Get-StripeList '/v1/balance_transactions' @{
        'created[gte]' = $gte
        'created[lt]'  = $lt
        'expand[]'     = 'data.source'
    }
    if ($txns.Count -eq 0) { Write-Log 'No transactions in that range.' -Level WARN; return }

    $saved = Save-JsonOutput $txns 'stripe_balance_transactions'

    $rows = foreach ($t in $txns) {
        $src = $t.source
        $srcIsObj = $src -and $src -isnot [string]
        $meta = if ($srcIsObj -and $src.PSObject.Properties.Name -contains 'metadata' -and $src.metadata) { $src.metadata | ConvertTo-Json -Compress } else { '' }
        [pscustomobject]@{
            Id                = $t.id
            CreatedUk         = (ConvertTo-UkTime $t.created).ToString('dd/MM/yyyy HH:mm:ss')
            AvailableOnUk     = (ConvertTo-UkTime $t.available_on).ToString('dd/MM/yyyy')
            Type              = $t.type
            ReportingCategory = $t.reporting_category
            Currency          = "$($t.currency)".ToUpper()
            Gross             = [decimal]$t.amount / 100
            Fee               = [decimal]$t.fee / 100
            Net               = [decimal]$t.net / 100
            Status            = $t.status
            Description       = Protect-CsvValue $t.description
            SourceId          = if ($srcIsObj) { $src.id } else { "$src" }
            SourceDescription = if ($srcIsObj -and $src.PSObject.Properties.Name -contains 'description') { Protect-CsvValue $src.description } else { '' }
            SourceMetadata    = Protect-CsvValue $meta
            FeeDetails        = Protect-CsvValue ((@($t.fee_details) | Where-Object { $_ } | ForEach-Object { "$($_.type): $([decimal]$_.amount / 100) ($($_.description))" }) -join '; ')
        }
    }
    $csvPath = Get-OutputPath 'stripe_balance_transactions' 'csv'
    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8

    $byType = $rows | Group-Object Type | Sort-Object Count -Descending
    Write-Log "$($txns.Count) transactions downloaded." -Level OK
    foreach ($g in $byType) {
        $gross = ($g.Group | Measure-Object Gross -Sum).Sum
        $fee   = ($g.Group | Measure-Object Fee -Sum).Sum
        Write-Log ("  {0,-20} {1,5} rows   gross {2,10:N2}   fees {3,8:N2}" -f $g.Name, $g.Count, $gross, $fee) -Level INFO
    }
    Write-Log "Full JSON: $($saved.Path)" -Level INFO
    Write-Log "Flat CSV:  $csvPath" -Level INFO
    Write-Log 'These files contain personal data. Keep them on this PC and remove personal details before sharing.' -Level WARN
}

function Invoke-TryOsmUrl {
    Write-Log "Enter an OSM path or full URL to GET, for example /oauth/resource" -Level INFO
    Write-Log 'Only GET requests are sent. The token is only ever sent to the OSM site.' -Level INFO
    $entered = (Read-Host 'OSM path or URL').Trim()
    if (-not $entered) { return }
    try {
        $r = Invoke-OsmGet $entered
        $saved = Save-JsonOutput $r 'osm'
        Show-Preview $saved.Json
        Write-Log "Saved to $($saved.Path)" -Level OK
        Write-Log 'This may contain personal data. Remove personal details before sharing.' -Level WARN
    } catch { Write-Log "Request failed: $_" -Level ERROR }
}

function Invoke-TryStripeUrl {
    Write-Log 'Enter a Stripe path to GET, for example /v1/payouts?limit=3' -Level INFO
    Write-Log 'Only GET requests are sent. The key is only ever sent to api.stripe.com.' -Level INFO
    $entered = (Read-Host 'Stripe path or URL').Trim()
    if (-not $entered) { return }
    try {
        $r = Invoke-StripeGet $entered
        $saved = Save-JsonOutput $r 'stripe'
        Show-Preview $saved.Json
        Write-Log "Saved to $($saved.Path)" -Level OK
        Write-Log 'This may contain personal data. Remove personal details before sharing.' -Level WARN
    } catch { Write-Log "Request failed: $_" -Level ERROR }
}

#endregion


#region -- SETUP MENU ---------------------------------------------------------

function Set-OsmAppDetails {
    $cfg = Get-Config
    Write-Log 'Create an OSM OAuth app under Settings > My Account Details > Developer Tools.' -Level INFO
    Write-Log "Its redirect URI must exactly match the one below." -Level INFO

    $id = (Read-Host "OSM client ID [$(if ($cfg.OsmClientId) { 'keep current' } else { 'none set' })]").Trim()
    if ($id) { $cfg.OsmClientId = $id }

    $redir = (Read-Host "Redirect URI [$($cfg.OsmRedirectUri)]").Trim()
    if ($redir) {
        try { $null = [Uri]$redir } catch { Write-Log 'That is not a valid URI; keeping the previous value.' -Level WARN; $redir = '' }
        if ($redir) { $cfg.OsmRedirectUri = $redir }
    }
    if (-not (Test-IsLoopbackHttp $cfg.OsmRedirectUri)) {
        Write-Log 'This redirect URI is not http://localhost, so you will paste the browser address back in after logging in.' -Level INFO
    }

    $scope = (Read-Host "OAuth scope(s), space separated [$(if ($cfg.OsmScope) { $cfg.OsmScope } else { 'none set' })]").Trim()
    if ($scope) { $cfg.OsmScope = $scope }

    if (Read-YesNo 'Enter or replace the OSM client secret now?' (-not (Test-StoredSecret $script:SecretOsmClientSecret))) {
        $sec = Read-Host 'OSM client secret (hidden)' -AsSecureString
        if ($sec.Length -gt 0) { Set-StoredSecret $script:SecretOsmClientSecret $sec; Write-Log 'Client secret saved to the encrypted vault.' -Level OK }
    }
    Save-Config $cfg
    Write-Log 'If you changed the scope, run Connect to OSM again so the new scope is granted.' -Level INFO
}

function Set-StripeKey {
    Write-Log 'Create a RESTRICTED key in the Stripe Dashboard: Developers > API keys > Create restricted key.' -Level INFO
    Write-Log 'Give it Read access only (for example Balance, Balance transaction sources, Charges, Payouts). Leave everything else as None.' -Level INFO
    $sec = Read-Host 'Stripe restricted key (hidden)' -AsSecureString
    if ($sec.Length -eq 0) { return }
    $plain = ConvertTo-PlainText $sec
    try {
        if ($plain -match '^sk_') {
            Write-Log 'That is a full secret key (sk_). It can move money, so it is refused. Please create a restricted key (rk_) instead.' -Level ERROR
            return
        }
        if ($plain -notmatch '^rk_(live|test)_[A-Za-z0-9]+$') {
            Write-Log 'That does not look like a Stripe restricted key (it should start rk_live_ or rk_test_).' -Level ERROR
            return
        }
        if ($plain -match '^rk_test_') { Write-Log 'This is a TEST mode key; it will not see real payments.' -Level WARN }
    } finally { $plain = $null }
    Set-StoredSecret $script:SecretStripeKey $sec
    Write-Log 'Stripe key saved to the encrypted vault.' -Level OK
}

function Show-Settings {
    $cfg = Get-Config
    Write-Log "Settings file:     $script:ConfigPath" -Level INFO
    Write-Log "Output folder:     $script:OutputDir" -Level INFO
    Write-Log "OSM client ID:     $(if ($cfg.OsmClientId) { $cfg.OsmClientId } else { '(not set)' })" -Level INFO
    Write-Log "OSM redirect URI:  $($cfg.OsmRedirectUri)" -Level INFO
    Write-Log "OSM scope:         $(if ($cfg.OsmScope) { $cfg.OsmScope } else { '(not set)' })" -Level INFO
    if ((Test-SecretModules).Count -gt 0) { Write-Log 'Secret storage modules not installed yet.' -Level WARN; return }
    foreach ($n in @($script:SecretOsmClientSecret, $script:SecretOsmRefreshToken, $script:SecretStripeKey)) {
        $state = if (Test-StoredSecret $n) { 'saved' } else { 'not set' }
        Write-Log ("{0,-19}{1}" -f "${n}:", $state) -Level INFO
    }
}

function Clear-AllSecrets {
    if (-not (Read-YesNo 'Remove the OSM client secret, OSM login and Stripe key from the vault?' $false)) { return }
    foreach ($n in @($script:SecretOsmClientSecret, $script:SecretOsmRefreshToken, $script:SecretStripeKey)) { Remove-StoredSecret $n }
    $script:OsmAccessToken = $null
    Write-Log 'Secrets removed. Revoke the Stripe key in the Stripe Dashboard too if you no longer need it.' -Level OK
}

function Show-SetupMenu {
    $options = @(
        'Install or check secret storage'
        'Set OSM app details (client ID, secret, redirect, scope)'
        'Connect to OSM (browser login)'
        'Set Stripe restricted key'
        'Test connections'
        'Show current settings'
        'Remove all saved secrets'
        'Back'
    )
    $sel = 0
    while ($true) {
        $sel = Show-Menu -Title 'Setup' -Options $options -Selected $sel
        if ($sel -lt 0 -or $options[$sel] -eq 'Back') { return }
        Clear-Host
        try {
            switch ($sel) {
                0 { if (Install-SecretModules) { Initialize-Vault; Write-Log 'Vault ready.' -Level OK } }
                1 { Set-OsmAppDetails }
                2 { Connect-Osm }
                3 { Set-StripeKey }
                4 { Invoke-TestConnections }
                5 { Show-Settings }
                6 { Clear-AllSecrets }
            }
        } catch { Write-Log "$_" -Level ERROR }
        Wait-ForKey
    }
}

#endregion


#region -- DATE RANGE MENU ----------------------------------------------------

function Select-DateRange {
    param($Current)
    $ukToday = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $script:UkTz).Date
    $firstThisMonth = [datetime]::new($ukToday.Year, $ukToday.Month, 1)
    $options = @(
        "Last month ($($firstThisMonth.AddMonths(-1).ToString('MMMM yyyy', $script:UkCulture)))"
        "This month so far ($($firstThisMonth.ToString('MMMM yyyy', $script:UkCulture)))"
        'Pick a month'
        'Custom dates'
        'Back'
    )
    $sel = Show-Menu -Title 'Choose date range' -Options $options -Header @("Current: $(Format-Range $Current)")
    switch ($sel) {
        0 { return New-DateRange $firstThisMonth.AddMonths(-1) $firstThisMonth.AddDays(-1) }
        1 { return New-DateRange $firstThisMonth $ukToday }
        2 {
            $months = 0..11 | ForEach-Object { $firstThisMonth.AddMonths(-$_) }
            $m = Show-Menu -Title 'Pick a month' -Options @($months | ForEach-Object { $_.ToString('MMMM yyyy', $script:UkCulture) })
            if ($m -lt 0) { return $Current }
            return New-DateRange $months[$m] $months[$m].AddMonths(1).AddDays(-1)
        }
        3 {
            Clear-Host
            $from = Read-UkDate 'From'
            $to   = Read-UkDate 'To (inclusive)'
            if ($to -lt $from) { Write-Log "'To' is before 'From'; keeping the previous range." -Level WARN; Wait-ForKey; return $Current }
            return New-DateRange $from $to
        }
        default { return $Current }
    }
}

#endregion


#region -- MAIN MENU ----------------------------------------------------------

function Get-StatusHeader {
    param($Range)
    $osm = 'unknown'; $stripe = 'unknown'
    if ((Test-SecretModules).Count -eq 0 -and (Test-VaultRegistered)) {
        try {
            $osm    = if (Test-StoredSecret $script:SecretOsmRefreshToken) { 'connected' } else { 'not connected' }
            $stripe = if (Test-StoredSecret $script:SecretStripeKey) { 'key saved' } else { 'no key' }
        } catch { $osm = 'vault locked'; $stripe = 'vault locked' }
    } else { $osm = 'run Setup'; $stripe = 'run Setup' }
    return @(
        "OSM: $osm    Stripe: $stripe"
        "Date range: $(Format-Range $Range)"
    )
}

function Start-MainMenu {
    $range = Get-DefaultRange
    $options = @(
        'Setup'
        'Choose date range'
        'Download Stripe transactions for the date range'
        'Try an OSM URL (GET)'
        'Try a Stripe URL (GET)'
        'Open output folder'
        'Exit'
    )
    $sel = 0
    while ($true) {
        $sel = Show-Menu -Title 'OSM Stripe Reconciler' -Options $options -Header (Get-StatusHeader $range) -Selected $sel
        if ($sel -lt 0 -or $options[$sel] -eq 'Exit') { Clear-Host; return }
        try {
            switch ($sel) {
                0 { Show-SetupMenu }
                1 { $range = Select-DateRange $range }
                2 { Clear-Host; Invoke-StripeDownload $range; Wait-ForKey }
                3 { Clear-Host; Invoke-TryOsmUrl; Wait-ForKey }
                4 { Clear-Host; Invoke-TryStripeUrl; Wait-ForKey }
                5 {
                    if (-not (Test-Path $script:OutputDir)) { $null = New-Item -ItemType Directory -Path $script:OutputDir -Force }
                    Invoke-Item $script:OutputDir
                }
            }
        } catch { Write-Log "$_" -Level ERROR; Wait-ForKey }
    }
}

#endregion

# Dot sourcing (. .\OsmStripeReconciler.ps1) loads the functions without starting the menu
if ($MyInvocation.InvocationName -ne '.') { Start-MainMenu }
