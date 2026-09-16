; Установщик AxiOm для Windows — один на все версии.
; Версию передаёт scripts/build_windows.ps1:  ISCC /DAppVersion=4.5.1 AxiOm.iss
; Пути относительные (от этого файла), чтобы собиралось в любом клоне.
; AppId НЕ МЕНЯТЬ: по нему установщик узнаёт уже установленный AxiOm и
; обновляет его, а не ставит вторую копию.
#ifndef AppVersion
  #error Передайте версию: ISCC /DAppVersion=X.Y.Z AxiOm.iss
#endif

[Setup]
AppId={{6L903538-42B1-4596-G479-BJ779F21A65D}
AppVersion={#AppVersion}
AppName=AxiOm
AppPublisher=AxiOm
AppPublisherURL=https://github.com/AxiOm-Labs-Inc/AxiOm-v2
AppSupportURL=https://github.com/AxiOm-Labs-Inc/AxiOm-v2
AppUpdatesURL=https://github.com/AxiOm-Labs-Inc/AxiOm-v2
DefaultDirName={autopf64}\AxiOm
DisableProgramGroupPage=yes
OutputDir=..\..\..\dist
OutputBaseFilename=AxiOm-v{#AppVersion}-Setup
Compression=lzma
SolidCompression=yes
SetupIconFile=..\..\runner\resources\app_icon.ico
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
; Excludes: build\...\Release не чистится между сборками — там лежат hiddify-core.dll
; и HiddifyCli.exe от 4.4.x. Без исключения установщик вёз бы их снова, а
; [InstallDelete] (выполняется ДО [Files]) удалял бы их лишь затем, чтобы
; [Files] тут же положил обратно.
Source: "..\..\..\build\windows\x64\runner\Release\*"; Excludes: "hiddify-core.dll,HiddifyCli.exe"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; С 4.5.0 ядро ставится как axiom-core.dll, а CLI апстрима не ставится вовсе.
; [Files] с ignoreversion старые файлы не удаляет — без этого при обновлении
; поверх 4.4.x в {app} остались бы hiddify-core.dll и HiddifyCli.exe. Это наши
; старые файлы в нашей папке, не чужой Hiddify.
Type: files; Name: "{app}\hiddify-core.dll"
Type: files; Name: "{app}\HiddifyCli.exe"

[Icons]
Name: "{autoprograms}\AxiOm"; Filename: "{app}\AxiOm.exe"
Name: "{autodesktop}\AxiOm"; Filename: "{app}\AxiOm.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\AxiOm.exe"; Description: "{cm:LaunchProgram,AxiOm}"; Flags: runascurrentuser nowait postinstall

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\AxiOm"
; {userappdata}\Hiddify здесь не трогаем: наш exe зовётся AxiOm.exe с первого
; коммита, а CompanyName/ProductName в Runner.rc — AxiOm, то есть наши данные
; лежат только в {userappdata}\AxiOm. Каталог Hiddify принадлежит настоящему
; апстрим-приложению, и удаление AxiOm стирало бы чужие профили и ключи — ровно
; тот вред, от которого уходит развод идентификаторов (6170fdf, 6e8edcc).

[Code]
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Exec('taskkill', '/F /IM AxiOm.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
  // hiddify.exe не убиваем: это чужой процесс. Установка AxiOm рвала бы
  // активное соединение настоящего Hiddify на той же машине.
  Result := True;
end;
