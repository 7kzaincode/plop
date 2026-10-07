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
; Upgrading over a running plop, the usual case now that closing its window
; keeps it in the tray: the Restart Manager asks it to close, which plop
; answers by quitting (app/windows/runner/win32_window.cpp, WM_ENDSESSION),
; and force ends it if it does not. [Code] below catches what this misses.
CloseApplications=force
WizardStyle=modern
OutputDir=..\..\dist
OutputBaseFilename=plop-windows-setup

[Files]
Source: "..\..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; The AppUserModelID plop.exe gives itself before its window
; (app/windows/runner/main.cpp): a pinned shortcut groups with the running
; window, and Windows shows plop's notifications, which an unpackaged app
; only gets for an ID a Start menu shortcut carries (app/lib/notify.dart).
Name: "{autoprograms}\plop"; Filename: "{app}\plop.exe"; AppUserModelID: "plop"

[Registry]
; plop's "open at login" toggle writes this value (app/lib/login_item.dart).
; ValueType none writes nothing at install, so upgrading keeps the user's
; choice; uninsdeletevalue removes it at uninstall, or Windows would try to
; start the deleted exe at every login. Like the firewall rule cleanup, this
; assumes the account elevating is the one that installed.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "plop"; ValueType: none; Flags: uninsdeletevalue
; Where plop's window was last left (app/windows/runner/win32_window.cpp,
; RememberFrame): plop writes it, never the installer, and uninstalling
; removes it, with the same elevating-account caveat.
Root: HKCU; Subkey: "Software\plop"; Flags: dontcreatekey uninsdeletekey

[Run]
; Let the other devices reach plop's server (a random port) on any network
; profile, since Windows marks newly joined Wi-Fi as Public, but only from the
; local subnet, where its peers are. Deleting rules named plop first also
; clears the block rules Windows adds when its firewall prompt is cancelled.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=plop"; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=plop dir=in action=allow program=""{app}\plop.exe"" enable=yes profile=any remoteip=localsubnet"; Flags: runhidden
Filename: "{app}\plop.exe"; Description: "Open plop"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallDelete]
; The Start menu shortcut plop makes in the user's own folder when it runs
; from anywhere but here (the portable zip) so its notifications show:
; removing plop takes that second "plop" in Start with it. Like the Run
; value, this is the elevating account's folder.
Type: files; Name: "{userprograms}\plop.lnk"

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im plop.exe"; Flags: runhidden; RunOnceId: "StopPlop"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=plop"; Flags: runhidden; RunOnceId: "DeleteFirewallRule"

[Code]
// The fallback for a plop the Restart Manager left running (another user's,
// "do not close" picked on the Preparing page, a /NOCLOSEAPPLICATIONS run):
// end it just before the files are replaced, as the uninstaller does, and
// give Windows a moment to let go of plop.exe.
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssInstall then
  begin
    if Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im plop.exe', '',
        SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0) then
      Sleep(1000);
  end;
end;
