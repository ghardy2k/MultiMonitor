<#
.SYNOPSIS
    MultiMonitor agent - a tiny, dependency-free HTTP server that serves the
    MultiMonitor dashboard and exposes Windows performance counters as JSON.

.DESCRIPTION
    Runs on Windows PowerShell 5.1+ with no installs. By default it listens on
    http://localhost:8765/ only, serves dashboard.html, and answers:

        GET  /api/ping                          agent identity / health
        POST /api/sample     {computer, paths}  read counters (Get-Counter)
        GET  /api/sysinfo?computer=NAME         OS / CPU / RAM / disks (CIM)
        GET  /api/sets?computer=NAME            counter-set catalog (browser)
        GET  /api/configs                       list saved dashboard configs
        GET  /api/configs/NAME                  read a saved config
        PUT  /api/configs/NAME                  save a config (JSON body)

    Remote machines are read with the identity of the account running this
    script (Get-Counter -ComputerName / CIM). That account needs to be in the
    remote machine's "Performance Monitor Users" (or Administrators) group and
    the Remote Registry service must be running there.

.PARAMETER Port
    TCP port to listen on. Default 8765.

.PARAMETER AllowRemote
    Listen on all interfaces (http://+:PORT/) so other dashboards can use this
    machine as an agent. Requires -ApiKey and an elevated prompt (or a URL ACL:
    netsh http add urlacl url=http://+:8765/ user=DOMAIN\user).

.PARAMETER ApiKey
    Shared secret that callers must send in the X-MM-Key header. Required with
    -AllowRemote, optional otherwise.

.PARAMETER NoBrowser
    Do not open the dashboard in the default browser on start.

.EXAMPLE
    .\MultiMonitor.ps1
.EXAMPLE
    .\MultiMonitor.ps1 -AllowRemote -ApiKey 's3cret' -Port 9000 -NoBrowser
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)][int]$Port = 8765,
    [switch]$AllowRemote,
    [string]$ApiKey = '',
    [switch]$NoBrowser,
    [ValidateRange(2, 64)][int]$MaxThreads = 16
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$AgentVersion = '1.0.0'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path $Root 'configs'
if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }

if ($AllowRemote -and [string]::IsNullOrWhiteSpace($ApiKey)) {
    throw '-AllowRemote requires -ApiKey so that the agent is not open to the whole network.'
}

# State shared by every request runspace (caches).
$Shared = [hashtable]::Synchronized(@{
    Root         = $Root
    ConfigDir    = $ConfigDir
    Port         = $Port
    ApiKey       = $ApiKey
    AllowRemote  = [bool]$AllowRemote
    Version      = $AgentVersion
    SetCache     = [hashtable]::Synchronized(@{})
    SysInfoCache = [hashtable]::Synchronized(@{})
    PathCache    = [hashtable]::Synchronized(@{})
})

# ---------------------------------------------------------------------------
# Request handler. Runs inside a RunspacePool worker so that one slow remote
# machine never blocks the rest of the dashboard.
# ---------------------------------------------------------------------------
$Handler = {
    param($Context, $Shared)

    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'

    function Send-Bytes([int]$Status, [byte[]]$Bytes, [string]$ContentType) {
        $res = $Context.Response
        $res.StatusCode = $Status
        $res.ContentType = $ContentType
        $res.Headers['Cache-Control'] = 'no-store'
        $res.Headers['X-Content-Type-Options'] = 'nosniff'
        $res.ContentLength64 = $Bytes.Length
        $res.OutputStream.Write($Bytes, 0, $Bytes.Length)
    }

    function Send-Json([int]$Status, $Object) {
        $json = ConvertTo-Json -InputObject $Object -Depth 8 -Compress
        Send-Bytes $Status ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8'
    }

    function Send-Error([int]$Status, [string]$Message) {
        Send-Json $Status ([ordered]@{ ok = $false; error = $Message })
    }

    function Read-Body([int]$MaxBytes = 2MB) {
        $req = $Context.Request
        if ($req.ContentLength64 -gt $MaxBytes) { throw [InvalidOperationException]::new('Request body too large.') }
        $reader = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if ($text.Length -gt $MaxBytes) { throw [InvalidOperationException]::new('Request body too large.') }
        return $text
    }

    function Test-LocalName([string]$Name) {
        return ([string]::IsNullOrWhiteSpace($Name) -or $Name -eq '.' -or $Name -eq 'localhost' -or
                $Name -eq '127.0.0.1' -or $Name -eq '::1' -or $Name -ieq $env:COMPUTERNAME)
    }

    function Assert-ComputerName([string]$Name) {
        # Host names, FQDNs, IPv4 and IPv6 literals only - never paths or switches.
        if (-not [string]::IsNullOrWhiteSpace($Name) -and $Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._:\-]{0,253}$') {
            throw [ArgumentException]::new("Invalid computer name '$Name'.")
        }
    }

    function ConvertTo-PathRegex([string]$Path) {
        # "\Processor(*)\% Processor Time" -> regex matching sample paths
        # such as "\\host\processor(0)\% processor time".
        $p = $Path.Trim().ToLowerInvariant()
        $p = $p -replace '^\\\\[^\\]+', ''                  # drop an explicit \\machine prefix
        $escaped = [regex]::Escape($p) -replace '\\\*', '.*' -replace '\\\?', '.'
        return '^' + $escaped + '$'
    }

    function Split-CounterPath([string]$Path) {
        if ($Path.Trim() -match '^(?:\\\\[^\\]+)?\\(?<set>[^\\(]+)(?:\((?<inst>.*)\))?\\(?<ctr>[^\\]+)$') {
            return @{ Set = $Matches['set']; Instance = $Matches['inst']; Counter = $Matches['ctr'] }
        }
        return $null
    }

    function Test-CounterPath([string]$Computer, [string]$Path) {
        # Cheap metadata check (no sampling). Windows PowerShell's Get-Counter fails the
        # *whole* batch when a single path is missing, so filter the batch first.
        $key = $(if (Test-LocalName $Computer) { '.' } else { $Computer.ToLowerInvariant() }) + '|' + $Path.ToLowerInvariant()
        $hit = $Shared.PathCache[$key]
        if ($hit -and ((Get-Date) - $hit.At).TotalMinutes -lt 5) { return $hit }
        $parts = Split-CounterPath $Path
        $result = @{ At = Get-Date; Ok = $false; Error = 'Malformed counter path.' }
        if ($parts) {
            $params = @{ ListSet = $parts.Set; ErrorAction = 'SilentlyContinue' }
            if (-not (Test-LocalName $Computer)) { $params.ComputerName = $Computer }
            $ls = @(Get-Counter @params | Where-Object { $_.CounterSetName -ieq $parts.Set })
            if ($ls.Count -eq 0) {
                $result.Error = "Counter set '$($parts.Set)' is not installed on this machine."
            } else {
                $want = ('\' + $parts.Counter).ToLowerInvariant()
                $found = $false
                foreach ($cp in $ls[0].Paths) { if (([string]$cp).ToLowerInvariant().EndsWith($want)) { $found = $true; break } }
                if ($found) { $result.Ok = $true; $result.Error = $null }
                else { $result.Error = "Counter '$($parts.Counter)' does not exist in set '$($parts.Set)'." }
            }
        }
        $Shared.PathCache[$key] = $result
        return $result
    }

    function Invoke-CounterRead([string]$Computer, [string[]]$Paths) {
        $params = @{ Counter = $Paths; MaxSamples = 1; ErrorAction = 'SilentlyContinue'; ErrorVariable = '+cerr' }
        if (-not (Test-LocalName $Computer)) { $params.ComputerName = $Computer }
        $cerr = @()
        $set = Get-Counter @params
        $msg = $null
        if ($cerr.Count -gt 0) { $msg = $cerr[0].Exception.Message }
        return @{ Set = $set; Error = $msg }
    }

    function Get-CounterValues([string]$Computer, [string[]]$Paths) {
        $results = [ordered]@{}
        foreach ($p in $Paths) { $results[$p] = [ordered]@{ ok = $false; error = 'No data for this counter instance.'; values = @(); source = 'pdh' } }

        # Reachability first: a quick metadata call that fails fast for dead hosts.
        # (It can also fail on a reachable host whose counter registry is damaged, so
        # the CIM fallback below gets a chance before we report the machine offline.)
        $perfError = $null
        if (-not (Test-LocalName $Computer)) {
            $probe = @(Get-Counter -ListSet 'System' -ComputerName $Computer -ErrorAction SilentlyContinue -ErrorVariable perr)
            if ($probe.Count -eq 0) {
                $perfError = 'Unable to connect to the specified computer or the computer is offline.'
                if ($perr) { $perfError = $perr[0].Exception.Message }
            }
        }

        $samples = @()
        $valid = @()
        if (-not $perfError) {
            foreach ($p in $Paths) {
                $t = Test-CounterPath $Computer $p
                if ($t.Ok) { $valid += $p } else { $results[$p].error = $t.Error }
            }
            if ($valid.Count -gt 0) {
                $read = Invoke-CounterRead $Computer $valid
                if ($read.Set) {
                    $samples = @($read.Set.CounterSamples)
                } elseif ($read.Error -and $read.Error -match 'Unable to connect|offline|network path|RPC server|Access is denied') {
                    $perfError = $read.Error
                } else {
                    # A specific instance (e.g. a named IIS site) is missing: read one by one.
                    foreach ($p in $valid) {
                        $one = Invoke-CounterRead $Computer @($p)
                        if ($one.Set) { $samples += @($one.Set.CounterSamples) }
                        elseif ($one.Error) { $results[$p].error = $one.Error }
                    }
                }
            }
        }

        $matchers = @()
        foreach ($p in $valid) { $matchers += , @($p, (ConvertTo-PathRegex $p)) }

        foreach ($s in $samples) {
            $sp = ($s.Path.ToLowerInvariant() -replace '^\\\\[^\\]+', '')
            foreach ($m in $matchers) {
                if ($sp -match $m[1]) {
                    $r = $results[$m[0]]
                    if (-not $r.ok) { $r.ok = $true; $r.error = $null; $r.values = New-Object System.Collections.ArrayList }
                    $v = [double]$s.CookedValue
                    if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { $v = $null }
                    elseif ($s.Status -ne 0) { $v = $null }
                    [void]$r.values.Add([ordered]@{ instance = [string]$s.InstanceName; value = $v })
                }
            }
        }

        # CIM fallback for core metrics the counter registry could not supply.
        $missing = @($Paths | Where-Object { -not $results[$_].ok -and (Get-FallbackKind $_) })
        if ($missing.Count -gt 0) {
            try {
                $fb = Get-CimFallback $Computer $missing
                foreach ($p in $fb.Keys) {
                    $results[$p] = [ordered]@{ ok = $true; error = $null; values = $fb[$p]; source = 'cim' }
                }
            } catch {
                if ($perfError) { throw [InvalidOperationException]::new($perfError) }
            }
        } elseif ($perfError) {
            throw [InvalidOperationException]::new($perfError)
        }
        return $results
    }

    function Get-FallbackKind([string]$Path) {
        $k = ($Path.Trim().ToLowerInvariant() -replace '^\\\\[^\\]+', '')
        switch ($k) {
            '\processor(_total)\% processor time'             { return 'cpu' }
            '\processor information(_total)\% processor time' { return 'cpu' }
            '\memory\available mbytes'                        { return 'memAvail' }
            '\memory\% committed bytes in use'                { return 'commit' }
            '\logicaldisk(*)\% free space'                    { return 'diskPct' }
            '\logicaldisk(_total)\% free space'               { return 'diskPctTotal' }
            '\logicaldisk(*)\free megabytes'                  { return 'diskMB' }
            '\system\processes'                               { return 'procs' }
            '\system\system up time'                          { return 'uptime' }
            '\tcpv4\connections established'                  { return 'tcp' }
        }
        return $null
    }

    function Get-CimFallback([string]$Computer, [string[]]$Paths) {
        $session = New-Cim $Computer
        try {
            $cim = @{ ErrorAction = 'Stop' }
            if ($session) { $cim.CimSession = $session }
            $os = $null; $disks = $null
            $out = @{}
            foreach ($p in $Paths) {
                $kind = Get-FallbackKind $p
                $vals = New-Object System.Collections.ArrayList
                if ($kind -in 'memAvail', 'commit', 'procs', 'uptime' -and -not $os) {
                    $os = Get-CimInstance @cim -ClassName Win32_OperatingSystem
                }
                if ($kind -like 'disk*' -and -not $disks) {
                    $disks = @(Get-CimInstance @cim -ClassName Win32_LogicalDisk -Filter 'DriveType=3')
                }
                switch ($kind) {
                    'cpu' {
                        $load = @(Get-CimInstance @cim -ClassName Win32_Processor | ForEach-Object { $_.LoadPercentage } | Where-Object { $_ -ne $null })
                        if ($load.Count) { [void]$vals.Add([ordered]@{ instance = '_total'; value = [double](($load | Measure-Object -Average).Average) }) }
                    }
                    'memAvail' { [void]$vals.Add([ordered]@{ instance = ''; value = [math]::Round([double]$os.FreePhysicalMemory / 1024, 0) }) }
                    'commit' {
                        $tv = [double]$os.TotalVirtualMemorySize
                        if ($tv -gt 0) { [void]$vals.Add([ordered]@{ instance = ''; value = 100 * ($tv - [double]$os.FreeVirtualMemory) / $tv }) }
                    }
                    'procs' { [void]$vals.Add([ordered]@{ instance = ''; value = [double]$os.NumberOfProcesses }) }
                    'uptime' {
                        if ($os.LastBootUpTime) { [void]$vals.Add([ordered]@{ instance = ''; value = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalSeconds) }) }
                    }
                    'diskPct' {
                        foreach ($d in $disks) { if ([double]$d.Size -gt 0) { [void]$vals.Add([ordered]@{ instance = ([string]$d.DeviceID).ToLowerInvariant(); value = 100 * [double]$d.FreeSpace / [double]$d.Size }) } }
                    }
                    'diskPctTotal' {
                        $size = [double](($disks | Measure-Object -Property Size -Sum).Sum)
                        $free = [double](($disks | Measure-Object -Property FreeSpace -Sum).Sum)
                        if ($size -gt 0) { [void]$vals.Add([ordered]@{ instance = '_total'; value = 100 * $free / $size }) }
                    }
                    'diskMB' {
                        foreach ($d in $disks) { [void]$vals.Add([ordered]@{ instance = ([string]$d.DeviceID).ToLowerInvariant(); value = [math]::Round([double]$d.FreeSpace / 1MB) }) }
                    }
                    'tcp' {
                        $tcpArgs = @{ Namespace = 'root/StandardCimv2'; ClassName = 'MSFT_NetTCPConnection'; Filter = 'State=5'; ErrorAction = 'Stop' }
                        if ($session) { $tcpArgs.CimSession = $session }
                        [void]$vals.Add([ordered]@{ instance = ''; value = [double]@(Get-CimInstance @tcpArgs).Count })
                    }
                }
                if ($vals.Count -gt 0) { $out[$p] = $vals }
            }
            return $out
        } finally {
            if ($session) { Remove-CimSession $session -ErrorAction SilentlyContinue }
        }
    }

    function New-Cim([string]$Computer) {
        if (Test-LocalName $Computer) { return $null }
        $opt = New-CimSessionOption -Protocol Wsman
        try {
            return New-CimSession -ComputerName $Computer -SessionOption $opt -OperationTimeoutSec 8 -ErrorAction Stop
        } catch {
            $dcom = New-CimSessionOption -Protocol Dcom
            return New-CimSession -ComputerName $Computer -SessionOption $dcom -OperationTimeoutSec 8 -ErrorAction Stop
        }
    }

    function Get-SysInfo([string]$Computer) {
        $key = if (Test-LocalName $Computer) { '.' } else { $Computer.ToLowerInvariant() }
        $cached = $Shared.SysInfoCache[$key]
        if ($cached -and ((Get-Date) - $cached.At).TotalSeconds -lt 30) { return $cached.Data }

        $session = New-Cim $Computer
        try {
            $cim = @{ ErrorAction = 'Stop' }
            if ($session) { $cim.CimSession = $session }
            $os = Get-CimInstance @cim -ClassName Win32_OperatingSystem
            $cs = Get-CimInstance @cim -ClassName Win32_ComputerSystem
            $cpu = @(Get-CimInstance @cim -ClassName Win32_Processor)
            $disks = @(Get-CimInstance @cim -ClassName Win32_LogicalDisk -Filter 'DriveType=3')

            $diskList = New-Object System.Collections.ArrayList
            foreach ($d in $disks) {
                [void]$diskList.Add([ordered]@{
                    name  = [string]$d.DeviceID
                    label = [string]$d.VolumeName
                    size  = [double]$d.Size
                    free  = [double]$d.FreeSpace
                })
            }
            $boot = $os.LastBootUpTime
            $data = [ordered]@{
                ok             = $true
                computer       = [string]$cs.Name
                domain         = [string]$cs.Domain
                manufacturer   = [string]$cs.Manufacturer
                model          = [string]$cs.Model
                os             = [string]$os.Caption
                osVersion      = [string]$os.Version
                osBuild        = [string]$os.BuildNumber
                lastBoot       = if ($boot) { $boot.ToUniversalTime().ToString('o') } else { $null }
                uptimeSec      = if ($boot) { [math]::Round(((Get-Date) - $boot).TotalSeconds) } else { $null }
                totalMemoryKB  = [double]$os.TotalVisibleMemorySize
                freeMemoryKB   = [double]$os.FreePhysicalMemory
                cpuName        = [string](($cpu | Select-Object -First 1).Name).Trim()
                sockets        = $cpu.Count
                cores          = [int](($cpu | Measure-Object -Property NumberOfCores -Sum).Sum)
                logicalCpus    = [int](($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
                disks          = $diskList
            }
            $Shared.SysInfoCache[$key] = @{ At = Get-Date; Data = $data }
            return $data
        } finally {
            if ($session) { Remove-CimSession $session -ErrorAction SilentlyContinue }
        }
    }

    function Get-CounterSets([string]$Computer, [bool]$Refresh) {
        $key = if (Test-LocalName $Computer) { '.' } else { $Computer.ToLowerInvariant() }
        if (-not $Refresh -and $Shared.SetCache.ContainsKey($key)) { return $Shared.SetCache[$key] }
        $params = @{ ListSet = '*'; ErrorAction = 'SilentlyContinue' }
        if (-not (Test-LocalName $Computer)) { $params.ComputerName = $Computer }
        $list = New-Object System.Collections.ArrayList
        foreach ($s in (Get-Counter @params | Sort-Object CounterSetName)) {
            [void]$list.Add([ordered]@{
                name        = [string]$s.CounterSetName
                description = [string]$s.Description
                multi       = ([string]$s.CounterSetType -eq 'MultiInstance')
                paths       = @($s.Paths | ForEach-Object { [string]$_ })
            })
        }
        if ($list.Count -eq 0) { throw [InvalidOperationException]::new("Could not read counter sets from '$Computer'.") }
        $Shared.SetCache[$key] = $list
        return $list
    }

    function Get-ConfigFile([string]$Name) {
        $n = [Uri]::UnescapeDataString($Name)
        if ($n.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) { $n = $n.Substring(0, $n.Length - 5) }
        if ($n -notmatch '^[A-Za-z0-9][A-Za-z0-9 _.\-]{0,79}$' -or $n.Contains('..')) {
            throw [ArgumentException]::new('Config names may contain letters, digits, spaces, dot, dash and underscore only.')
        }
        return Join-Path $Shared.ConfigDir ($n + '.json')
    }

    $req = $Context.Request
    $res = $Context.Response
    try {
        # ---- Security gates -------------------------------------------------
        $origin = $req.Headers['Origin']
        $hostHeader = ($req.Headers['Host'] -replace ':\d+$', '').Trim('[', ']')
        $isLoopbackHost = @('localhost', '127.0.0.1', '::1') -contains $hostHeader.ToLowerInvariant()

        # DNS-rebinding guard: when bound to loopback only, the Host header must be loopback.
        if (-not $Shared.AllowRemote -and -not $isLoopbackHost) { Send-Error 403 'Forbidden host.'; return }

        # Browsers may call us from file:// (Origin "null"), from our own origin, or
        # - when an API key is configured - from any origin that knows the key.
        $selfOrigins = @("http://localhost:$($Shared.Port)", "http://127.0.0.1:$($Shared.Port)", "http://[::1]:$($Shared.Port)")
        $originAllowed = (-not $origin) -or $origin -eq 'null' -or ($selfOrigins -contains $origin) -or
                         [bool]$Shared.ApiKey   # with a key configured, the key is the gate
        if ($origin -and $originAllowed) {
            $res.Headers['Access-Control-Allow-Origin'] = $origin
            $res.Headers['Vary'] = 'Origin'
            $res.Headers['Access-Control-Allow-Headers'] = 'Content-Type, X-MM-Key'
            $res.Headers['Access-Control-Allow-Methods'] = 'GET, POST, PUT, OPTIONS'
            $res.Headers['Access-Control-Max-Age'] = '600'
            # Chrome/Edge Private Network Access: allow file:// pages to reach this loopback agent.
            if ($req.Headers['Access-Control-Request-Private-Network'] -eq 'true') {
                $res.Headers['Access-Control-Allow-Private-Network'] = 'true'
            }
        }
        if ($req.HttpMethod -eq 'OPTIONS') { Send-Bytes 204 ([byte[]]@()) 'text/plain'; return }
        if (-not $originAllowed) { Send-Error 403 'Origin not allowed.'; return }

        $path = $req.Url.AbsolutePath
        $isApi = $path.StartsWith('/api/', [StringComparison]::OrdinalIgnoreCase)
        if ($isApi -and $Shared.ApiKey -and $path -ne '/api/ping' -and $req.Headers['X-MM-Key'] -ne $Shared.ApiKey) {
            Send-Error 401 'Missing or invalid X-MM-Key header.'; return
        }

        $computer = [string]$req.QueryString['computer']

        # ---- Routes ---------------------------------------------------------
        switch -Regex ($path) {
            '^/$|^/index\.html$|^/dashboard\.html$' {
                if ($req.HttpMethod -ne 'GET') { Send-Error 405 'Method not allowed.'; return }
                $file = Join-Path $Shared.Root 'dashboard.html'
                Send-Bytes 200 ([IO.File]::ReadAllBytes($file)) 'text/html; charset=utf-8'
                return
            }
            '^/api/ping$' {
                Send-Json 200 ([ordered]@{
                    ok = $true; agent = 'MultiMonitor'; version = $Shared.Version
                    computer = $env:COMPUTERNAME; user = "$env:USERDOMAIN\$env:USERNAME"
                    keyRequired = [bool]$Shared.ApiKey; time = (Get-Date).ToUniversalTime().ToString('o')
                })
                return
            }
            '^/api/sample$' {
                if ($req.HttpMethod -ne 'POST') { Send-Error 405 'Use POST.'; return }
                $body = Read-Body | ConvertFrom-Json
                $comp = [string]$body.computer
                Assert-ComputerName $comp
                $paths = @($body.paths | Where-Object { $_ -is [string] -and $_.Trim().StartsWith('\') } | Select-Object -Unique)
                if ($paths.Count -eq 0) { Send-Error 400 'No counter paths supplied.'; return }
                if ($paths.Count -gt 200) { Send-Error 400 'Too many counter paths (max 200).'; return }
                $started = Get-Date
                try {
                    $results = Get-CounterValues $comp $paths
                } catch {
                    Send-Json 200 ([ordered]@{ ok = $false; computer = $comp; error = $_.Exception.Message })
                    return
                }
                Send-Json 200 ([ordered]@{
                    ok = $true; computer = $comp
                    time = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
                    ms = [int]((Get-Date) - $started).TotalMilliseconds
                    results = $results
                })
                return
            }
            '^/api/sysinfo$' {
                Assert-ComputerName $computer
                try { Send-Json 200 (Get-SysInfo $computer) }
                catch { Send-Json 200 ([ordered]@{ ok = $false; error = $_.Exception.Message }) }
                return
            }
            '^/api/sets$' {
                Assert-ComputerName $computer
                $refresh = $req.QueryString['refresh'] -eq '1'
                try { Send-Json 200 ([ordered]@{ ok = $true; sets = (Get-CounterSets $computer $refresh) }) }
                catch { Send-Json 200 ([ordered]@{ ok = $false; error = $_.Exception.Message }) }
                return
            }
            '^/api/configs$' {
                $items = New-Object System.Collections.ArrayList
                foreach ($f in (Get-ChildItem -Path $Shared.ConfigDir -Filter '*.json' -File | Sort-Object LastWriteTime -Descending)) {
                    [void]$items.Add([ordered]@{ name = $f.BaseName; modified = $f.LastWriteTimeUtc.ToString('o'); size = $f.Length })
                }
                Send-Json 200 ([ordered]@{ ok = $true; configs = $items })
                return
            }
            '^/api/configs/(?<name>[^/]+)$' {
                $file = Get-ConfigFile $Matches['name']
                if ($req.HttpMethod -eq 'GET') {
                    if (-not (Test-Path -LiteralPath $file)) { Send-Error 404 'Config not found.'; return }
                    Send-Bytes 200 ([IO.File]::ReadAllBytes($file)) 'application/json; charset=utf-8'
                } elseif ($req.HttpMethod -eq 'PUT' -or $req.HttpMethod -eq 'POST') {
                    $text = Read-Body 1MB
                    try { $null = $text | ConvertFrom-Json } catch { Send-Error 400 'Body is not valid JSON.'; return }
                    [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding($false)))
                    Send-Json 200 ([ordered]@{ ok = $true; name = [IO.Path]::GetFileNameWithoutExtension($file) })
                } else { Send-Error 405 'Method not allowed.' }
                return
            }
            default { Send-Error 404 "Not found: $path"; return }
        }
    } catch [ArgumentException] {
        try { Send-Error 400 $_.Exception.Message } catch { }
    } catch {
        try { Send-Error 500 $_.Exception.Message } catch { }
    } finally {
        try { $res.OutputStream.Close() } catch { }
        try { $res.Close() } catch { }
    }
}

# ---------------------------------------------------------------------------
# Listener + worker pool
# ---------------------------------------------------------------------------
$prefix = if ($AllowRemote) { "http://+:$Port/" } else { "http://localhost:$Port/" }
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
if (-not $AllowRemote) { $listener.Prefixes.Add("http://127.0.0.1:$Port/") }
try {
    $listener.Start()
} catch {
    Write-Host "Could not listen on $prefix : $($_.Exception.Message)" -ForegroundColor Red
    if ($AllowRemote) {
        Write-Host "Run elevated, or reserve the URL once with:" -ForegroundColor Yellow
        Write-Host "  netsh http add urlacl url=http://+:$Port/ user=$env:USERDOMAIN\$env:USERNAME" -ForegroundColor Yellow
    } else {
        Write-Host "Is another copy already running? Try -Port <other>." -ForegroundColor Yellow
    }
    exit 1
}

$iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$pool = [RunspaceFactory]::CreateRunspacePool(1, $MaxThreads, $iss, $Host)
$pool.Open()
$jobs = New-Object System.Collections.ArrayList

$url = "http://localhost:$Port/"
Write-Host ''
Write-Host '  MultiMonitor agent' -ForegroundColor Cyan -NoNewline
Write-Host " v$AgentVersion" -ForegroundColor DarkGray
Write-Host "  Dashboard : $url" -ForegroundColor Green
if ($AllowRemote) { Write-Host "  Remote    : listening on all interfaces, X-MM-Key required" -ForegroundColor Yellow }
Write-Host "  Configs   : $ConfigDir" -ForegroundColor DarkGray
Write-Host '  Press Ctrl+C to stop.' -ForegroundColor DarkGray
Write-Host ''

if (-not $NoBrowser) { try { Start-Process $url } catch { } }

try {
    while ($listener.IsListening) {
        # Poll with a timeout so Ctrl+C is honoured between requests.
        $pending = $listener.BeginGetContext($null, $null)
        while (-not $pending.AsyncWaitHandle.WaitOne(250)) {
            for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
                $j = $jobs[$i]
                if ($j.Handle.IsCompleted) {
                    try { [void]$j.PS.EndInvoke($j.Handle) } catch { Write-Verbose $_.Exception.Message }
                    $j.PS.Dispose(); $jobs.RemoveAt($i)
                }
            }
        }
        $context = $listener.EndGetContext($pending)
        Write-Verbose ("{0} {1}" -f $context.Request.HttpMethod, $context.Request.Url.PathAndQuery)
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($Handler).AddArgument($context).AddArgument($Shared)
        [void]$jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
    }
} finally {
    Write-Host 'Stopping MultiMonitor agent...' -ForegroundColor DarkGray
    $listener.Stop(); $listener.Close()
    foreach ($j in $jobs) { try { $j.PS.Stop(); $j.PS.Dispose() } catch { } }
    $pool.Close(); $pool.Dispose()
}
