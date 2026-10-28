# Packages a built Haoze Connect Windows Release tree into internal-distribution
# artifacts:
#   dist\HaozeConnect\HaozeConnect-Windows-Standalone-x64.zip
#   dist\HaozeConnect\HaozeConnect-Windows-Setup-x64-<version>.exe
#
# Prereqs:
#   - flutter build windows --release (produces build\windows\x64\runner\Release)
#     with the prebuilt hiddify-lib DLLs installed (hiddify-core.dll +
#     HiddifyCli.exe).
#   - Inno Setup 6.5+ (ISCC.exe) on PATH or in the default install location.
#
# The standalone ZIP needs no installation; settings remain in AppData and do
# not travel with the ZIP folder. Both formats use the same non-portable build.
# No signing is attempted. CI artifact labels include "-unsigned".
# This script never uploads or publishes.

[CmdletBinding()]
param(
    [string]$BuildDir = "build\windows\x64\runner\Release",
    [string]$OutDir = "dist\HaozeConnect"
)

$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Resolve-RepoPath([string]$Path) {
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path $repoRoot $Path
    }
    return [System.IO.Path]::GetFullPath($Path)
}

# --- Locate the build tree ----------------------------------------------------
$BuildDir = (Get-Item -LiteralPath (Resolve-RepoPath $BuildDir) -ErrorAction Stop).FullName
$OutDir = Resolve-RepoPath $OutDir
if (-not (Test-Path -LiteralPath $BuildDir -PathType Container)) { throw "BuildDir must be a directory" }
if ($OutDir.Equals($BuildDir, [StringComparison]::OrdinalIgnoreCase) -or
    $OutDir.StartsWith($BuildDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutDir must be outside BuildDir"
}
$exe = Join-Path $BuildDir "HaozeConnect.exe"
$required = @($exe,
    (Join-Path $BuildDir "hiddify-core.dll"),
    (Join-Path $BuildDir "HiddifyCli.exe"),
    (Join-Path $BuildDir "libcronet.dll"),
    (Join-Path $BuildDir "data"))
foreach ($f in $required) {
    if (-not (Test-Path -LiteralPath $f)) {
        throw "Missing required build output: $f - did you run 'flutter build windows --release' after 'hiddify-core\bin' is populated?"
    }
}

# --- Locate Inno Setup --------------------------------------------------------
$iscc = (Get-Command iscc.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    $candidates = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe")
    $iscc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $iscc) { throw "Inno Setup 6 (ISCC.exe) not found. Run: choco install innosetup -y" }

# --- Version from pubspec (X.Y.Z+NNNN -> X.Y.Z) -------------------------------
$pubspec = Join-Path $repoRoot "pubspec.yaml"
$version = (Select-String -Path $pubspec -Pattern '^version:\s*(\d+\.\d+\.\d+)(\+.*)?$').Matches[0].Groups[1].Value
if (-not $version) { throw "Could not read version from pubspec.yaml" }
Write-Host "Haoze Connect Windows packaging, version $version"

# --- Standalone ZIP -----------------------------------------------------------
$zipOut = Join-Path $OutDir "HaozeConnect-Windows-Standalone-x64.zip"
$StagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ("haoze-package-" + [guid]::NewGuid().ToString("N"))
$tmpZipDir = Join-Path $StagingDir "HaozeConnect"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
try {
    New-Item -ItemType Directory -Path $tmpZipDir -Force | Out-Null
    Get-ChildItem -LiteralPath $BuildDir -Force | Copy-Item -Destination $tmpZipDir -Recurse -Force
    Compress-Archive -Force -LiteralPath $tmpZipDir -DestinationPath $zipOut
} finally {
    if (Test-Path -LiteralPath $StagingDir) { Remove-Item -LiteralPath $StagingDir -Recurse -Force }
}
Write-Host "Wrote $zipOut"

# --- Inno Setup EXE installer -------------------------------------------------
$iss = Join-Path $PSScriptRoot "haoze-windows-installer.iss"
& $iscc "/DAPP_VERSION=$version" "/DSOURCE_DIR=$BuildDir" "/DOUTPUT_DIR=$OutDir" $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }
Write-Host "Done. Artifacts in $OutDir"
