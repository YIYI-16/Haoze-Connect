# Validate app-local release CRT files without executing them or making network
# requests. WinVerifyTrust checks file integrity and the locally trusted chain;
# online revocation is deliberately outside this reproducible build check.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RuntimeDirectory,
    [Parameter(Mandatory = $true)][version]$MinimumVersion,
    [Parameter(Mandatory = $true)][ValidateSet('x64', 'x86', 'arm64')][string]$Architecture
)
$ErrorActionPreference = 'Stop'

if (-not ('HaozeRuntimeTrust' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HaozeRuntimeTrust {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct FileInfo {
        public uint Size;
        [MarshalAs(UnmanagedType.LPWStr)] public string Path;
        public IntPtr File, Subject;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct TrustData {
        public uint Size;
        public IntPtr Policy, Sip;
        public uint UI, Revocation, Choice;
        public IntPtr File;
        public uint StateAction;
        public IntPtr State, Url;
        public uint Flags, Context;
        public IntPtr SignatureSettings;
    }
    [DllImport("wintrust.dll", ExactSpelling = true)]
    private static extern int WinVerifyTrust(IntPtr hwnd, ref Guid action, ref TrustData data);
    public static int Verify(string path) {
        var file = new FileInfo { Size = (uint)Marshal.SizeOf(typeof(FileInfo)), Path = path };
        IntPtr ptr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(FileInfo)));
        Marshal.StructureToPtr(file, ptr, false);
        var data = new TrustData {
            Size = (uint)Marshal.SizeOf(typeof(TrustData)), UI = 2, Choice = 1,
            File = ptr, StateAction = 1,
            Flags = 0x1000 | 0x10 // CACHE_ONLY_URL_RETRIEVAL | REVOCATION_CHECK_NONE
        };
        var action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
        try { return WinVerifyTrust(new IntPtr(-1), ref action, ref data); }
        finally {
            data.StateAction = 2;
            WinVerifyTrust(new IntPtr(-1), ref action, ref data);
            Marshal.DestroyStructure(ptr, typeof(FileInfo));
            Marshal.FreeHGlobal(ptr);
        }
    }
}
'@
}

$expectedMachine = @{ x64 = 0x8664; x86 = 0x014c; arm64 = 0xaa64 }[$Architecture]
$files = @(Get-ChildItem -LiteralPath $RuntimeDirectory -Filter '*.dll' -File)
if ($files.Count -eq 0) { throw "No runtime DLLs found in $RuntimeDirectory" }
foreach ($file in $files) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($file.FullName))
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw "Invalid DOS header: $file" }
        $reader.BaseStream.Position = 0x3c
        $peOffset = $reader.ReadUInt32()
        $reader.BaseStream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne $expectedMachine) {
            throw "Invalid PE header or wrong $Architecture architecture: $file"
        }
    } finally { $reader.Dispose() }
    $info = $file.VersionInfo
    $version = [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
    if ($version -lt $MinimumVersion) {
        throw "Runtime $file is $version; selected MSVC toolset requires >= $MinimumVersion"
    }
    $status = [HaozeRuntimeTrust]::Verify($file.FullName)
    if ($status -ne 0) {
        throw ('Local Authenticode validation failed for {0}: 0x{1:X8}' -f $file, $status)
    }
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        [Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($file.FullName))
    try {
        # Microsoft CRTs can be signed by the Windows compatibility publisher
        # as well as the general Microsoft code-signing publisher.
        $publisher = $certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
        if ($publisher -notin @('Microsoft Corporation', 'Microsoft Windows Software Compatibility Publisher')) {
            throw "Runtime signer is not Microsoft Corporation: $file"
        }
    } finally { $certificate.Dispose() }
    Write-Host "Verified Microsoft CRT: $($file.Name) $version $Architecture"
}
