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
; Keep the template value: fastforge defaults it to 'none', which every released installer used,
; so upgrades stay in the same install scope. Do not hardcode it in make_config.yaml.
PrivilegesRequired={{PRIVILEGES_REQUIRED}}
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
Filename: "{app}\\{{EXECUTABLE_NAME}}"; Description: "{cm:LaunchProgram,{{DISPLAY_NAME}}}"; Flags: {% if PRIVILEGES_REQUIRED == 'admin' %}runascurrentuser{% endif %} nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\Hiddify"
Type: filesandordirs; Name: "{app}\cli"

[Code]
const
  MachineEnvironmentKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';
  UserEnvironmentKey = 'Environment';
  CliAsset = 'sbx-windows-amd64.exe';
  CliUrl = 'https://github.com/Xenon-Tetraoxide/SBX-VPN-Client/releases/latest/download/';
  MoveReplaceExisting = 1;
  CliStateKey = 'Software\AxiOm\CLI';
  CliStateParentKey = 'Software\AxiOm';
  CliPathAddedValue = 'PathAdded';
  RegTypeSz = 1;
  RegTypeExpandSz = 2;
  KeyQueryValue = $0001;
  KeyWow64_64Key = $0100;

var
  CliNeedsRestart, CliDownloaded: Boolean;
  DownloadPage: TDownloadWizardPage;

function MoveFileEx(ExistingFile, NewFile: String; Flags: LongWord): Boolean;
  external 'MoveFileExW@kernel32.dll stdcall setuponly';

function RegOpenKeyExW(hKey: Integer; lpSubKey: String; ulOptions, samDesired: LongWord; var phkResult: Integer): LongInt;
  external 'RegOpenKeyExW@advapi32.dll stdcall';

function RegQueryValueExW(hKey: Integer; lpValueName: String; lpReserved: LongWord; var lpType: LongWord; lpData, lpcbData: LongWord): LongInt;
  external 'RegQueryValueExW@advapi32.dll stdcall';

function RegCloseKey(hKey: Integer): LongInt;
  external 'RegCloseKey@advapi32.dll stdcall';

function OnDownloadProgress(const Url, FileName: String; const Progress, ProgressMax: Int64): Boolean;
begin
  Result := True;
end;

procedure InitializeWizard();
begin
  DownloadPage := CreateDownloadPage(SetupMessage(msgWizardPreparing), SetupMessage(msgPreparingDesc), @OnDownloadProgress);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpReady) and not WizardSilent then
  begin
    DownloadPage.Clear;
    DownloadPage.Add(CliUrl + CliAsset, CliAsset, '');
    DownloadPage.Show;
    try
      try
        DownloadPage.Download;
        CliDownloaded := True;
      except
        Log('AxiOm CLI download failed or was cancelled: ' + GetExceptionMessage);
      end;
    finally
      DownloadPage.Hide;
    end;
  end;
end;

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

function GetPathValueType(RootKey: Integer; const EnvironmentKey: String; var ValueType: LongWord): Boolean;
var
  KeyHandle: Integer;
begin
  Result := False;
  if RegOpenKeyExW(RootKey, EnvironmentKey, 0, KeyQueryValue or KeyWow64_64Key, KeyHandle) = 0 then
  begin
    try
      Result := RegQueryValueExW(KeyHandle, 'Path', 0, ValueType, 0, 0) = 0;
    finally
      RegCloseKey(KeyHandle);
    end;
  end;
end;

function WritePathValue(RootKey: Integer; const EnvironmentKey, Value: String; ValueType: LongWord): Boolean;
begin
  if ValueType = RegTypeSz then
    Result := RegWriteStringValue(RootKey, EnvironmentKey, 'Path', Value)
  else
    Result := RegWriteExpandStringValue(RootKey, EnvironmentKey, 'Path', Value);
end;

procedure ClearCliPathMarker(RootKey: Integer);
begin
  RegDeleteValue(RootKey, CliStateKey, CliPathAddedValue);
  RegDeleteKeyIfEmpty(RootKey, CliStateKey);
  RegDeleteKeyIfEmpty(RootKey, CliStateParentKey);
end;

// AddEntry: append the cli folder to PATH, keeping the value type, and record in
// Software\AxiOm\CLI (same root as the PATH key) that Setup added it.
// Remove: only if that marker exists.
function UpdateCliPath(AddEntry: Boolean): Boolean;
var
  CliDir, PathValue, Entry, EnvironmentKey: String;
  EntryStart, EntryEnd, RootKey: Integer;
  ValueType: LongWord;
  PathExists: Boolean;
  MarkerValue: Cardinal;
begin
  CliDir := ExpandConstant('{app}\cli');
  if IsAdminInstallMode then
  begin
    RootKey := HKLM;
    EnvironmentKey := MachineEnvironmentKey;
  end
  else
  begin
    RootKey := HKCU;
    EnvironmentKey := UserEnvironmentKey;
  end;
  Result := True;

  if not AddEntry then
  begin
    if not RegQueryDWordValue(RootKey, CliStateKey, CliPathAddedValue, MarkerValue) or (MarkerValue <> 1) then
    begin
      Log('PATH entry was not added by Setup; leaving PATH untouched');
      Exit;
    end;
  end;

  PathExists := RegValueExists(RootKey, EnvironmentKey, 'Path');
  PathValue := '';
  ValueType := RegTypeExpandSz;
  if PathExists then
  begin
    if not RegQueryStringValue(RootKey, EnvironmentKey, 'Path', PathValue) or
       not GetPathValueType(RootKey, EnvironmentKey, ValueType) or
       ((ValueType <> RegTypeSz) and (ValueType <> RegTypeExpandSz)) then
    begin
      Result := False;
      Exit;
    end;
  end
  else if not AddEntry then
  begin
    ClearCliPathMarker(RootKey);
    Exit;
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
        Result := WritePathValue(RootKey, EnvironmentKey, PathValue, ValueType);
        if Result then
          ClearCliPathMarker(RootKey);
      end;
      Exit;
    end;
    EntryStart := EntryEnd + 1;
  end;

  if AddEntry then
  begin
    if (PathValue <> '') and (Copy(PathValue, Length(PathValue), 1) <> ';') then
      PathValue := PathValue + ';';
    Result := WritePathValue(RootKey, EnvironmentKey, PathValue + CliDir, ValueType);
    if Result and not RegWriteDWordValue(RootKey, CliStateKey, CliPathAddedValue, 1) then
      Log('Could not record the PATH marker; the entry will not be removed on uninstall');
  end
  else
    ClearCliPathMarker(RootKey);
end;

procedure InstallCli();
var
  CliDir, Destination, StagedFile, OldFile, ErrorMessage: String;
begin
  try
    if not CliDownloaded then
    begin
      if not WizardSilent then
        RaiseException('the download was not completed');
      DownloadTemporaryFile(CliUrl + CliAsset, CliAsset, '', nil);
    end;
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
      OldFile := Destination + '.old';
      DeleteFile(OldFile);
      if RenameFile(Destination, OldFile) then
      begin
        if not RenameFile(StagedFile, Destination) then
        begin
          RenameFile(OldFile, Destination);
          RestartReplace(StagedFile, Destination);
          CliNeedsRestart := True;
        end;
      end
      else
      begin
        RestartReplace(StagedFile, Destination);
        CliNeedsRestart := True;
      end;
    end;
    if not UpdateCliPath(True) then
      RaiseException('Could not add ' + CliDir + ' to PATH');
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

function PsQuote(const Value: String): String;
var
  Escaped: String;
begin
  Escaped := Value;
  StringChangeEx(Escaped, #39, #39#39, True);
  Result := #39 + Escaped + #39;
end;

// Wrapper exit codes: 124 = timed out and killed, 125 = could not start.
procedure RunCliUninstall();
var
  CliPath, CliArgs: String;
  ResultCode: Integer;
begin
  CliPath := ExpandConstant('{app}\cli\axiom.exe');
  if not FileExists(CliPath) then
  begin
    Log('AxiOm CLI is not installed; skipping CLI cleanup');
    Exit;
  end;
  CliArgs := PsQuote('uninstall');
  if UninstallSilent then
    CliArgs := PsQuote('--no-elevate') + ',' + CliArgs;
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -NonInteractive -Command "$ErrorActionPreference = ' + PsQuote('Stop') +
    '; try { $p = Start-Process -FilePath ' + PsQuote(CliPath) + ' -ArgumentList ' + CliArgs +
    ' -WindowStyle Hidden -PassThru; $null = $p.Handle } catch { exit 125 }; ' +
    'if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch { }; exit 124 }; exit $p.ExitCode"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Log('Could not launch PowerShell for AxiOm CLI cleanup: ' + SysErrorMessage(ResultCode))
  else if ResultCode = 0 then
    Log('AxiOm CLI cleanup finished successfully')
  else if ResultCode = 124 then
    Log('AxiOm CLI cleanup timed out and was stopped')
  else if ResultCode = 125 then
    Log('AxiOm CLI cleanup could not be started')
  else
    Log('AxiOm CLI cleanup failed with exit code ' + IntToStr(ResultCode) + '; uninstall continues');
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    RunCliUninstall();
    if not UpdateCliPath(False) then
      Log('Could not remove AxiOm CLI from PATH');
  end;
end;
