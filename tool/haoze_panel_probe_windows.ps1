param([string]$OutputPath = (Join-Path $PSScriptRoot 'haoze-panel-native.json'))

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Run this probe on the Windows device that cannot connect to the panel.'
}
Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$handler.AllowAutoRedirect = $false
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(20)
$client.MaxResponseContentBufferSize = 1048576
$client.DefaultRequestHeaders.UserAgent.ParseAdd('HaozeConnect-Prototype/0.1.0')
$checks = @()
try {
    1..4 | ForEach-Object {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $response = $null
        try {
            $response = $client.GetAsync('https://www.haoze.cyou/api/v1/guest/comm/config').GetAwaiter().GetResult()
            $status = [int]$response.StatusCode
            $jsonObject = $false
            if ($status -eq 200) {
                $data = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
                $jsonObject = $null -ne $data.data -and $data.data -is [pscustomobject]
            }
            $checks += [ordered]@{Attempt = $_; Ok = ($status -eq 200 -and $jsonObject); HttpStatus = $status; JsonObject = $jsonObject; ElapsedMs = $timer.ElapsedMilliseconds}
        } catch {
            $failure = $_.Exception.GetBaseException()
            $checks += [ordered]@{Attempt = $checks.Count + 1; Ok = $false; ErrorType = $failure.GetType().Name; HResult = $failure.HResult; ElapsedMs = $timer.ElapsedMilliseconds}
        } finally {
            if ($null -ne $response) { $response.Dispose() }
        }
    }
} finally {
    $client.Dispose()
    $handler.Dispose()
}

$report = [ordered]@{
    Runtime = 'System.Net.Http on Windows'
    PowerShell = $PSVersionTable.PSVersion.ToString()
    Utc = [DateTime]::UtcNow.ToString('o')
    Proxy = 'DIRECT (VPN/TUN routing may still apply)'
    CertificateVerification = 'required; platform defaults'
    Checks = $checks
}
$json = $report | ConvertTo-Json -Depth 6
$json | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$json
if (@($checks | Where-Object { -not $_.Ok }).Count -gt 0) { exit 1 }
