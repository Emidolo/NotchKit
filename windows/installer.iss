; Inno Setup script for NotchKit-<version>-setup.exe. Built by build-installer.ps1, which publishes the two exes first.
#ifndef Version
  #define Version "0.0.0"
#endif

[Setup]
AppId={{DC26E48E-3CAE-4235-B81F-A855F2E3D2C7}
AppName=NotchKit
AppVersion={#Version}
AppPublisher=Emidolo
AppPublisherURL=https://github.com/Emidolo/NotchKit
DefaultDirName={autopf}\NotchKit
DisableProgramGroupPage=yes
; The service needs an administrator to register.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
LicenseFile=..\LICENSE
OutputDir=..\build
OutputBaseFilename=NotchKit-{#Version}-setup
Compression=lzma2
SolidCompression=yes
UninstallDisplayIcon={app}\NotchKit.exe
; The Run key below is the installing user's own, on purpose.
UsedUserAreasWarning=no

[Tasks]
Name: startup; Description: "Start NotchKit when I sign in"

[Files]
Source: "..\build\windows\NotchKit.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\NotchKitService.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\NotchKit"; Filename: "{app}\NotchKit.exe"

[Registry]
; Same value the app writes for Settings → Launch at login, so the switch there shows it as on.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "NotchKit"; \
  ValueData: """{app}\NotchKit.exe"""; Tasks: startup; Flags: uninsdeletevalue

[Run]
; "create" fails harmlessly on an update, when the service already exists at the same path.
Filename: "{sys}\sc.exe"; Parameters: "create NotchKitService binPath= ""\""{app}\NotchKitService.exe\"""" start= auto DisplayName= ""NotchKit Service"""; Flags: runhidden
Filename: "{sys}\sc.exe"; Parameters: "description NotchKitService ""Keeps the PC awake and handles the lid for NotchKit."""; Flags: runhidden
Filename: "{sys}\net.exe"; Parameters: "start NotchKitService"; Flags: runhidden
; As the signed-in user, not elevated: Windows blocks drag and drop from Explorer into an elevated window.
; Also in a silent install (NotchKit-Installer.exe runs Setup with /SILENT), so NotchKit opens at the end either way.
Filename: "{app}\NotchKit.exe"; Description: "Start NotchKit"; Flags: nowait postinstall runasoriginaluser

[UninstallRun]
; Stopping the service lets the PC sleep and puts the lid action back.
Filename: "{sys}\net.exe"; Parameters: "stop NotchKitService"; Flags: runhidden; RunOnceId: "StopService"
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im NotchKit.exe"; Flags: runhidden; RunOnceId: "StopApp"
Filename: "{sys}\sc.exe"; Parameters: "delete NotchKitService"; Flags: runhidden; RunOnceId: "DeleteService"

[Code]
// An update replaces both exes, so both must have stopped. "net stop" waits for the service.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Exec(ExpandConstant('{sys}\net.exe'), 'stop NotchKitService', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im NotchKit.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := '';
end;
