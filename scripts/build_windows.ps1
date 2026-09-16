# Релизная сборка Windows: приложение + установщик AxiOm-v<версия>-Setup.exe.
#
#   powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1 -SkipGen
#
# Нужно: Flutter, Visual Studio Community с «Разработкой классических приложений
# на C++» и ATL, NuGet (nuget.exe в PATH или в tools\), Inno Setup 6, ядро в
# hiddify-core\bin (scripts/fetch_core.sh windows), .env с DEVICE_API_KEY.
# Подробности — docs/BUILD_AND_RELEASE.md.
param([switch]$SkipGen)
$ErrorActionPreference = 'Stop'
# Консоль в cp1251/cp1252 искажает кириллицу сообщений
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
function Fail($msg) { Write-Host "✗ $msg" -ForegroundColor Red; exit 1 }

# --- Что должно лежать до сборки -------------------------------------------
if (-not (Test-Path .env)) { Fail 'нет .env — скопируйте .env.example и впишите DEVICE_API_KEY' }
$keyLine = Get-Content .env | Where-Object { $_ -match '^DEVICE_API_KEY=' } | Select-Object -First 1
$DeviceApiKey = if ($keyLine) { ($keyLine -split '=', 2)[1].Trim() } else { '' }
if (-not $DeviceApiKey) { Fail 'DEVICE_API_KEY в .env пустой' }

foreach ($f in 'hiddify-core\bin\hiddify-core.dll', 'hiddify-core\bin\libcronet.dll') {
    if (-not (Test-Path $f)) { Fail "нет $f — запустите scripts/fetch_core.sh windows" }
}

if (-not (Get-Command nuget -ErrorAction SilentlyContinue)) {
    if (Test-Path tools\nuget.exe) { $env:PATH = "$Root\tools;$env:PATH" }
    else { Fail 'нет nuget.exe: скачайте https://dist.nuget.org/win-x86-commandline/latest/nuget.exe в tools\' }
}

# Visual Studio с ATL. Если рядом стоят Build Tools без ATL, CMake сам выберет
# их и сборка упадёт на atlstr.h (flutter_secure_storage_windows). Входим в
# окружение нужной студии: при заданном VSINSTALLDIR CMake берёт её.
$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $VsWhere)) { Fail 'не найден Visual Studio (vswhere.exe)' }
$Vs = & $VsWhere -products * -latest -requires Microsoft.VisualStudio.Component.VC.ATL -property installationPath | Select-Object -First 1
if (-not $Vs) { Fail 'нет Visual Studio с ATL: в установщике VS добавьте компонент «ATL C++» к «Разработке классических приложений на C++»' }
if ($env:VSINSTALLDIR -ne "$Vs\") {
    Import-Module "$Vs\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
    Enter-VsDevShell -VsInstallPath $Vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
}
# Кэш CMake помнит студию прошлой сборки — с другой студией его нужно сбросить
$Cache = 'build\windows\x64\CMakeCache.txt'
if ((Test-Path $Cache) -and -not (Select-String -Path $Cache -SimpleMatch "CMAKE_GENERATOR_INSTANCE:INTERNAL=$($Vs -replace '\\', '/')" -Quiet)) {
    Write-Host 'Прошлая сборка была другой студией — сбрасываю кэш CMake'
    Remove-Item -Recurse -Force build\windows\x64
}

$Iscc = @(
    $(if ($env:INNO_SETUP_PATH) { Join-Path $env:INNO_SETUP_PATH 'ISCC.exe' }),
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $Iscc) { Fail 'не найден Inno Setup 6 (ISCC.exe); задайте INNO_SETUP_PATH' }

$Version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([\d.]+)\+').Matches[0].Groups[1].Value
Write-Host "Сборка AxiOm $Version для Windows"

# --- Сборка ----------------------------------------------------------------
function Run($exe) {
    & $exe @args
    # Аргументы не печатаем: среди них DEVICE_API_KEY
    if ($LASTEXITCODE -ne 0) { Fail "$exe $($args[0]) — код $LASTEXITCODE" }
}
Run flutter pub get
if (-not $SkipGen) { Run dart run build_runner build --delete-conflicting-outputs }
# -t lib/main_prod.dart обязателен: точка входа по умолчанию поднимает dev-окружение
Run flutter build windows --release -t lib/main_prod.dart "--dart-define=DEVICE_API_KEY=$DeviceApiKey"

# --- Проверка собранного ---------------------------------------------------
$Release = 'build\windows\x64\runner\Release'
if (-not (Test-Path "$Release\axiom-core.dll")) { Fail "в $Release нет axiom-core.dll" }
$app = [System.IO.File]::ReadAllBytes("$Root\$Release\data\app.so")
$text = [System.Text.Encoding]::ASCII.GetString($app)
if (-not $text.Contains('main_prod')) { Fail 'собрано не из lib/main_prod.dart' }
if (-not $text.Contains($DeviceApiKey)) { Fail 'DEVICE_API_KEY не вкомпилирован' }
if (-not $text.Contains('fr.arcohouse.space/devices')) { Fail 'нет адреса лимитера устройств FR' }
Write-Host '✓ main_prod, DEVICE_API_KEY и адрес лимитера на месте'

# --- Установщик ------------------------------------------------------------
Run $Iscc /Q "/DAppVersion=$Version" windows\packaging\exe\AxiOm.iss
$Setup = "dist\AxiOm-v$Version-Setup.exe"
if (-not (Test-Path $Setup)) { Fail "ISCC отработал, но $Setup нет" }
Write-Host "✓ Готово: $Setup"
