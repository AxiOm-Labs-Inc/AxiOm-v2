[Setup]
AppId={{APP_ID}}
AppVersion={{APP_VERSION}}
AppName={{DISPLAY_NAME}}
AppPublisher={{PUBLISHER_NAME}}
AppPublisherURL={{PUBLISHER_URL}}
AppSupportURL={{PUBLISHER_URL}}
AppUpdatesURL={{PUBLISHER_URL}}
DefaultDirName={{INSTALL_DIR_NAME}}
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename={{OUTPUT_BASE_FILENAME}}
Compression=lzma
SolidCompression=yes
SetupIconFile={{SETUP_ICON_FILE}}
WizardStyle=modern
PrivilegesRequired=admin
ChangesEnvironment=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
CloseApplications=force

[Languages]
{% for locale in LOCALES %}
{% if locale == 'en' %}Name: "english"; MessagesFile: "compiler:Default.isl"{% endif %}
{% if locale == 'hy' %}Name: "armenian"; MessagesFile: "compiler:Languages\\Armenian.isl"{% endif %}
{% if locale == 'bg' %}Name: "bulgarian"; MessagesFile: "compiler:Languages\\Bulgarian.isl"{% endif %}
{% if locale == 'ca' %}Name: "catalan"; MessagesFile: "compiler:Languages\\Catalan.isl"{% endif %}
{% if locale == 'zh' %}Name: "chinesesimplified"; MessagesFile: "compiler:Languages\\ChineseSimplified.isl"{% endif %}
{% if locale == 'co' %}Name: "corsican"; MessagesFile: "compiler:Languages\\Corsican.isl"{% endif %}
{% if locale == 'cs' %}Name: "czech"; MessagesFile: "compiler:Languages\\Czech.isl"{% endif %}
{% if locale == 'da' %}Name: "danish"; MessagesFile: "compiler:Languages\\Danish.isl"{% endif %}
{% if locale == 'nl' %}Name: "dutch"; MessagesFile: "compiler:Languages\\Dutch.isl"{% endif %}
{% if locale == 'fi' %}Name: "finnish"; MessagesFile: "compiler:Languages\\Finnish.isl"{% endif %}
{% if locale == 'fr' %}Name: "french"; MessagesFile: "compiler:Languages\\French.isl"{% endif %}
{% if locale == 'de' %}Name: "german"; MessagesFile: "compiler:Languages\\German.isl"{% endif %}
{% if locale == 'he' %}Name: "hebrew"; MessagesFile: "compiler:Languages\\Hebrew.isl"{% endif %}
{% if locale == 'is' %}Name: "icelandic"; MessagesFile: "compiler:Languages\\Icelandic.isl"{% endif %}
{% if locale == 'it' %}Name: "italian"; MessagesFile: "compiler:Languages\\Italian.isl"{% endif %}
{% if locale == 'ja' %}Name: "japanese"; MessagesFile: "compiler:Languages\\Japanese.isl"{% endif %}
{% if locale == 'no' %}Name: "norwegian"; MessagesFile: "compiler:Languages\\Norwegian.isl"{% endif %}
{% if locale == 'pl' %}Name: "polish"; MessagesFile: "compiler:Languages\\Polish.isl"{% endif %}
{% if locale == 'pt' %}Name: "portuguese"; MessagesFile: "compiler:Languages\\Portuguese.isl"{% endif %}
{% if locale == 'ru' %}Name: "russian"; MessagesFile: "compiler:Languages\\Russian.isl"{% endif %}
{% if locale == 'sk' %}Name: "slovak"; MessagesFile: "compiler:Languages\\Slovak.isl"{% endif %}
{% if locale == 'sl' %}Name: "slovenian"; MessagesFile: "compiler:Languages\\Slovenian.isl"{% endif %}
{% if locale == 'es' %}Name: "spanish"; MessagesFile: "compiler:Languages\\Spanish.isl"{% endif %}
{% if locale == 'tr' %}Name: "turkish"; MessagesFile: "compiler:Languages\\Turkish.isl"{% endif %}
{% if locale == 'uk' %}Name: "ukrainian"; MessagesFile: "compiler:Languages\\Ukrainian.isl"{% endif %}
{% endfor %}

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: {% if CREATE_DESKTOP_ICON != true %}unchecked{% else %}checkedonce{% endif %}
Name: "launchAtStartup"; Description: "{cm:AutoStartProgram,{{DISPLAY_NAME}}}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: {% if LAUNCH_AT_STARTUP != true %}unchecked{% else %}checkedonce{% endif %}
[Files]
Source: "{{SOURCE_DIR}}\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"
Name: "{autodesktop}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"; Tasks: desktopicon
Name: "{userstartup}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"; WorkingDir: "{app}"; Tasks: launchAtStartup
[Run]
Filename: "{app}\\{{EXECUTABLE_NAME}}"; Description: "{cm:LaunchProgram,{{DISPLAY_NAME}}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\Hiddify"
Type: filesandordirs; Name: "{app}\cli"

[Code]
const
  EnvironmentKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';
  CliAsset = 'sbx-windows-amd64.exe';
  CliUrl = 'https://github.com/Xenon-Tetraoxide/SBX-VPN-Client/releases/latest/download/';
  MoveReplaceExisting = 1;

var
  CliNeedsRestart: Boolean;

function MoveFileEx(ExistingFile, NewFile: String; Flags: LongWord): Boolean;
  external 'MoveFileExW@kernel32.dll stdcall setuponly';

function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Exec('net', 'stop "HiddifyTunnelService"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('sc.exe', 'delete "HiddifyTunnelService"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := True;
end;

procedure StopDesktopApp();
var
  GuiPath: String;
  ResultCode: Integer;
begin
  GuiPath := ExpandConstant('{app}\AxiOm.exe');
  StringChangeEx(GuiPath, #39, #39#39, True);
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -NonInteractive -Command "Get-Process -Name AxiOm -ErrorAction SilentlyContinue | ' +
    'Where-Object { $_.Path -ieq ' + #39 + GuiPath + #39 + ' } | ' +
    'ForEach-Object { & (Join-Path $env:SystemRoot ''System32\taskkill.exe'') /F /PID $_.Id }"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function UpdateCliPath(AddEntry: Boolean): Boolean;
var
  CliDir, PathValue, Entry: String;
  EntryStart, EntryEnd: Integer;
begin
  CliDir := ExpandConstant('{app}\cli');
  Result := True;
  if not RegQueryStringValue(HKLM, EnvironmentKey, 'Path', PathValue) then
  begin
    if RegValueExists(HKLM, EnvironmentKey, 'Path') then
      Result := False;
    if not Result or not AddEntry then
      Exit;
    PathValue := '';
  end;

  EntryStart := 1;
  while EntryStart <= Length(PathValue) do
  begin
    EntryEnd := EntryStart;
    while EntryEnd <= Length(PathValue) do
    begin
      if PathValue[EntryEnd] = ';' then
        Break;
      EntryEnd := EntryEnd + 1;
    end;
    Entry := RemoveBackslashUnlessRoot(Trim(Copy(PathValue, EntryStart, EntryEnd - EntryStart)));
    if CompareText(Entry, CliDir) = 0 then
    begin
      if not AddEntry then
      begin
        if (EntryEnd > Length(PathValue)) and (EntryStart > 1) then
          EntryStart := EntryStart - 1;
        Delete(PathValue, EntryStart, EntryEnd - EntryStart + 1);
        Result := RegWriteExpandStringValue(HKLM, EnvironmentKey, 'Path', PathValue);
      end;
      Exit;
    end;
    EntryStart := EntryEnd + 1;
  end;

  if AddEntry then
  begin
    if (PathValue <> '') and (Copy(PathValue, Length(PathValue), 1) <> ';') then
      PathValue := PathValue + ';';
    Result := RegWriteExpandStringValue(HKLM, EnvironmentKey, 'Path', PathValue + CliDir);
  end;
end;

procedure InstallCli();
var
  CliDir, Destination, StagedFile, ErrorMessage: String;
begin
  try
    DownloadTemporaryFile(CliUrl + CliAsset, CliAsset, '', nil);
    CliDir := ExpandConstant('{app}\cli');
    Destination := CliDir + '\axiom.exe';
    StagedFile := Destination + '.new';
    if not ForceDirectories(CliDir) then
      RaiseException('Could not create ' + CliDir);
    if not FileCopy(ExpandConstant('{tmp}\') + CliAsset, StagedFile, False) then
      RaiseException('Could not stage ' + Destination);
    if not MoveFileEx(StagedFile, Destination, MoveReplaceExisting) then
    begin
      if not FileExists(Destination) then
      begin
        DeleteFile(StagedFile);
        RaiseException('Could not install ' + Destination);
      end;
      RestartReplace(StagedFile, Destination);
      CliNeedsRestart := True;
    end;
    if not UpdateCliPath(True) then
      RaiseException('Could not add ' + CliDir + ' to the system PATH');
  except
    ErrorMessage := 'Could not finish setting up AxiOm CLI (SBX): ' + GetExceptionMessage;
    Log(ErrorMessage);
    if not WizardSilent then
      SuppressibleMsgBox(ErrorMessage, mbError, MB_OK, IDOK);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    StopDesktopApp();
  if CurStep = ssPostInstall then
    InstallCli();
end;

function NeedRestart(): Boolean;
begin
  Result := CliNeedsRestart;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    if not UpdateCliPath(False) then
      Log('Could not remove AxiOm CLI from the system PATH');
end;
