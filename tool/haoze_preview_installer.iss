#ifndef HaozeVersion
  #error A release version must be supplied using /DHaozeVersion
#endif

[Setup]
AppId={{98273092-7dae-4b33-9b79-69400bf8f086}
AppName=Haoze
AppVerName=Haoze
UninstallDisplayName=Haoze
AppVersion={#HaozeVersion}
AppPublisher=Haoze
AppPublisherURL=https://www.haoze.cyou
DefaultDirName={autopf64}\Haoze
DefaultGroupName=Haoze
PrivilegesRequired=admin
UsePreviousAppDir=no
DisableDirPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\build\haoze-installer
OutputBaseFilename=Haoze-Windows-Setup-x64-unsigned
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\Haoze.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
Type: files; Name: "{autoprograms}\Haoze Connect Mihomo.lnk"

[Icons]
Name: "{autoprograms}\Haoze"; Filename: "{app}\Haoze.exe"

[Run]
Filename: "{app}\Haoze.exe"; Flags: postinstall nowait skipifsilent unchecked
