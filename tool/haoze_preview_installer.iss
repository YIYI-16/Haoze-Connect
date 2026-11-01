#ifndef HaozeVersion
  #error A release version must be supplied using /DHaozeVersion
#endif

[Setup]
AppId={{98273092-7dae-4b33-9b79-69400bf8f086}
AppName=Haoze Connect Mihomo
AppVersion={#HaozeVersion}
AppPublisher=Haoze
AppPublisherURL=https://www.haoze.cyou
DefaultDirName={autopf64}\HaozeConnectMihomoPreview
DefaultGroupName=Haoze Connect Mihomo
PrivilegesRequired=admin
UsePreviousAppDir=no
DisableDirPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\build\haoze-installer
OutputBaseFilename=HaozeConnect-Windows-Setup-x64-unsigned
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\HaozeConnectMihomo.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Haoze Connect Mihomo"; Filename: "{app}\HaozeConnectMihomo.exe"

[Run]
Filename: "{app}\HaozeConnectMihomo.exe"; Flags: postinstall nowait skipifsilent unchecked
