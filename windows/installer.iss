; Inno Setup script for the Windows installer of "Vẽ lại cho đẹp".
; Built by CI:  iscc /DAppVersion=1.0.0 /DSourceDir=..\build\windows\x64\runner\Release windows\installer.iss

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{6C1E7C2B-3F7A-4C55-9E57-8A6E0B7D2F11}
AppName=Vẽ lại cho đẹp
AppVersion={#AppVersion}
AppVerName=Vẽ lại cho đẹp {#AppVersion}
AppPublisher=NhamStudio
AppPublisherURL=https://topvl.net
AppSupportURL=https://topvl.net
AppUpdatesURL=https://github.com/aiplus4m-cmd/Redraw/releases
DefaultDirName={autopf}\NhamStudio\VeLaiChoDep
DefaultGroupName=NhamStudio
DisableProgramGroupPage=yes
OutputDir=..\build\installer
OutputBaseFilename=VeLaiChoDep-Setup-{#AppVersion}
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\VeLaiChoDep.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Vẽ lại cho đẹp"; Filename: "{app}\VeLaiChoDep.exe"
Name: "{autodesktop}\Vẽ lại cho đẹp"; Filename: "{app}\VeLaiChoDep.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\VeLaiChoDep.exe"; Description: "{cm:LaunchProgram,Vẽ lại cho đẹp}"; Flags: nowait postinstall skipifsilent
