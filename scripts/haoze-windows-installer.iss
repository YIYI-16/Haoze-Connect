; Haoze Connect standalone EXE installer (Inno Setup 6).
; Structurally mirrors windows/packaging/exe/inno_setup.sas (the fastforge
; template), but with Haoze's own install identity:
;   - own AppId GUID (different install from upstream Hiddify),
;   - own exe name HaozeConnect.exe (BINARY_NAME in windows/CMakeLists.txt,
;     must stay in sync with windows/runner/Runner.rc OriginalFilename),
;   - install dir {autopf64}\HaozeConnect.
; Core-side Windows service names (HiddifyAdminBG / HiddifyTunnelService) are
; owned by the hiddify-lib Go core and must NOT be renamed here.

#ifndef APP_VERSION
#define APP_VERSION "0.0.0"
#endif
#ifndef SOURCE_DIR
#define SOURCE_DIR "..\build\windows\x64\runner\Release"
#endif
#ifndef OUTPUT_DIR
#define OUTPUT_DIR "..\dist\HaozeConnect"
#endif

#define MyAppName "Haoze Connect"
#define MyAppExeName "HaozeConnect.exe"
#define MyAppId "c20913cb-7ffa-4db4-b003-b5944d757d21"

[Setup]
AppId={{c20913cb-7ffa-4db4-b003-b5944d757d21}
AppVersion={#APP_VERSION}
AppName={#MyAppName}
AppPublisher=Haoze
AppPublisherURL=https://www.haoze.cyou
AppSupportURL=https://www.haoze.cyou
AppUpdatesURL=https://www.haoze.cyou
DefaultDirName={autopf64}\HaozeConnect
DisableProgramGroupPage=yes
OutputDir={#OUTPUT_DIR}
OutputBaseFilename=HaozeConnect-Windows-Setup-x64-{#APP_VERSION}
Compression=lzma
SolidCompression=no
SetupIconFile=..\windows\runner\resources\app_icon.ico
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
; Closes locked app binaries before file replace — prefer this over taskkill.exe heuristics.
CloseApplications=force

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "inno-languages\ChineseSimplified.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce
Name: "launchAtStartup"; Description: "{cm:AutoStartProgram,{#MyAppName}}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SOURCE_DIR}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: launchAtStartup

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: runasoriginaluser nowait postinstall skipifsilent

; NOTE on uninstall/user data:
; - There is deliberately NO [UninstallDelete] section: uninstalling Haoze
;   Connect preserves the user's settings/data (%APPDATA%\Haoze\Haoze Connect,
;   derived by path_provider from CompanyName\ProductName in Runner.rc).
; - No installer code stops or deletes core services shared with Hiddify.
