# Native-loader smoke test on the Windows build runner. This does not validate
# account login, tunnel connectivity or Smart App Control enforcement.
[CmdletBinding()]
param(
    [string]$BuildDir = 'build\windows\x64\runner\Release',
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not [IO.Path]::IsPathRooted($BuildDir)) { $BuildDir = Join-Path $repoRoot $BuildDir }
$exe = Join-Path $BuildDir 'HaozeConnect.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing built app: $exe" }
if (Get-Process -Name 'HaozeConnect' -ErrorAction SilentlyContinue) {
    throw 'An existing HaozeConnect process would invalidate the launch smoke test.'
}

$app = $null
try {
    $app = Start-Process -FilePath $exe -WorkingDirectory $BuildDir -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $stableSince = $null
    do {
        Start-Sleep -Milliseconds 500
        $app.Refresh()
        if ($app.HasExited) {
            throw "Native launch failed; exit code: $($app.ExitCode). Check DLL dependencies and Windows Code Integrity events."
        }
        if ($app.MainWindowHandle -ne 0 -and $app.MainWindowTitle -eq 'Haoze Connect' -and $app.Responding) {
            if ($null -eq $stableSince) { $stableSince = [DateTime]::UtcNow }
            if (([DateTime]::UtcNow - $stableSince).TotalSeconds -ge 5) {
                Write-Host 'PASS: Haoze Connect created a responsive native window and remained running.'
                return
            }
        } else {
            $stableSince = $null
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Native launch timed out without a stable, responsive Haoze Connect window.'
} finally {
    if ($null -ne $app) {
        $app.Refresh()
        if (-not $app.HasExited) {
            $null = $app.CloseMainWindow()
            if (-not $app.WaitForExit(5000)) { $app.Kill(); $app.WaitForExit() }
        }
        $app.Dispose()
    }
}
