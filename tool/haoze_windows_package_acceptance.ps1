param(
    [Parameter(Mandatory = $true)][string]$SetupPath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$setup = (Resolve-Path $SetupPath).Path
$installDirectory = Join-Path $env:RUNNER_TEMP 'Haoze-install-acceptance'
$executable = Join-Path $installDirectory 'Haoze.exe'
$uninstaller = Join-Path $installDirectory 'unins000.exe'
$registry = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{98273092-7dae-4b33-9b79-69400bf8f086}_is1'
if ((Test-Path $installDirectory) -or (Test-Path $registry)) { throw 'Acceptance location is already occupied' }
$expectedVersion = (Select-String -Path pubspec.yaml -Pattern '^version:\s+(\d+\.\d+\.\d+)').Matches.Groups[1].Value
$record = $null
try {
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/DIR="' + $installDirectory + '"'))
    $process = Start-Process -FilePath $setup -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { throw "Installer failed: $($process.ExitCode)" }
    if (-not (Test-Path $executable)) { throw 'Haoze.exe was not installed' }
    if (Test-Path (Join-Path $installDirectory 'HaozeConnectMihomo.exe')) { throw 'Legacy executable was installed' }
    $info = (Get-Item $executable).VersionInfo
    foreach ($value in @($info.ProductName, $info.FileDescription, $info.InternalName)) {
        if ($value -ne 'Haoze') { throw 'Installed executable still exposes a legacy name' }
    }
    if ($info.OriginalFilename -ne 'Haoze.exe') { throw 'Executable identity mismatch' }
    if (-not $info.ProductVersion.StartsWith($expectedVersion)) { throw 'Installed version mismatch' }
    $registration = Get-ItemProperty $registry
    if ($registration.DisplayName -ne 'Haoze') { throw 'Installed-app display name mismatch' }
    if ($registration.DisplayVersion -ne $expectedVersion) { throw 'Installed-app version mismatch' }
    $shortcut = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Haoze.lnk'
    if (-not (Test-Path $shortcut)) { throw 'Haoze Start Menu shortcut is missing' }
    $shell = New-Object -ComObject WScript.Shell
    if ($shell.CreateShortcut($shortcut).TargetPath -ne $executable) { throw 'Shortcut targets the wrong executable' }
    $record = @{
        displayName = $registration.DisplayName
        productName = $info.ProductName
        executable = 'Haoze.exe'
        version = $registration.DisplayVersion
        executableSha256 = (Get-FileHash $executable -Algorithm SHA256).Hash.ToLowerInvariant()
        shortcut = 'Haoze.lnk'
        install = 'PASS'
    }
} finally {
    if (Test-Path $uninstaller) {
        $process = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
        if ($process.ExitCode -notin @(0, 3010)) { throw "Uninstaller failed: $($process.ExitCode)" }
    }
}
if (Test-Path $registry) { throw 'Uninstaller left the installed-app registration behind' }
$record['uninstall'] = 'PASS'
$record | ConvertTo-Json | Set-Content -Encoding utf8 $OutputPath
Write-Output 'PASS Windows installer, executable identity, shortcut and uninstall'
