[Setup]
AppId={{6L903538-42B1-4596-G479-BJ779F21A65D}
AppVersion=4.4.3
AppName=AxiOm
AppPublisher=AxiOm
AppPublisherURL=https://github.com/AxiOm-Labs-Inc/AxiOm-v2
AppSupportURL=https://github.com/AxiOm-Labs-Inc/AxiOm-v2
AppUpdatesURL=https://github.com/AxiOm-Labs-Inc/AxiOm-v2
DefaultDirName={autopf64}\AxiOm
DisableProgramGroupPage=yes
OutputDir=D:\Creativ\AxiOm_APP_v2\hiddify-app\dist\4.4.3+40403
OutputBaseFilename=AxiOm-v4.4.3-Setup
Compression=lzma
SolidCompression=yes
SetupIconFile=D:\Creativ\AxiOm_APP_v2\hiddify-app\windows\runner\resources\app_icon.ico
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=force

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
Source: "D:\Creativ\AxiOm_APP_v2\hiddify-app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\AxiOm"; Filename: "{app}\AxiOm.exe"
Name: "{autodesktop}\AxiOm"; Filename: "{app}\AxiOm.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\AxiOm.exe"; Description: "{cm:LaunchProgram,AxiOm}"; Flags: runascurrentuser nowait postinstall

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\AxiOm"
Type: filesandordirs; Name: "{userappdata}\Hiddify"

[Code]
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Exec('taskkill', '/F /IM AxiOm.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
  Exec('taskkill', '/F /IM hiddify.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
  Result := True;
end;
