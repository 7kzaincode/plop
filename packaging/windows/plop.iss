; Windows installer for plop (Inno Setup 6). .github/workflows/release.yml
; builds it after `flutter build windows --release` and copying the VC++
; runtime DLLs next to plop.exe:
;   iscc /DAppVersion=1.2.3 packaging\windows\plop.iss
; Paths are relative to this file; the installer lands in dist\.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{2775617E-2DB9-4612-AFC0-300DC9BE3871}
AppName=plop
AppVersion={#AppVersion}
AppPublisher=7kzaincode
AppPublisherURL=https://github.com/7kzaincode/plop
DefaultDirName={autopf}\plop
DisableDirPage=yes
DisableProgramGroupPage=yes
; Admin for Program Files and the firewall rule: one UAC prompt.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\plop.exe
WizardStyle=modern
OutputDir=..\..\dist
OutputBaseFilename=plop-windows-setup

[Files]
Source: "..\..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\plop"; Filename: "{app}\plop.exe"

[Registry]
; plop's "open at login" toggle writes this value (app/lib/login_item.dart).
; ValueType none writes nothing at install, so upgrading keeps the user's
; choice; uninsdeletevalue removes it at uninstall, or Windows would try to
; start the deleted exe at every login. Like the firewall rule cleanup, this
; assumes the account elevating is the one that installed.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "plop"; ValueType: none; Flags: uninsdeletevalue

[Run]
; Let the other devices reach plop's server (a random port) on any network
; profile, since Windows marks newly joined Wi-Fi as Public, but only from the
; local subnet, where its peers are. Deleting rules named plop first also
; clears the block rules Windows adds when its firewall prompt is cancelled.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=plop"; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=plop dir=in action=allow program=""{app}\plop.exe"" enable=yes profile=any remoteip=localsubnet"; Flags: runhidden
Filename: "{app}\plop.exe"; Description: "Open plop"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im plop.exe"; Flags: runhidden; RunOnceId: "StopPlop"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=plop"; Flags: runhidden; RunOnceId: "DeleteFirewallRule"
