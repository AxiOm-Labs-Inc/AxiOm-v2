#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"
#include "app_links/app_links_plugin_c_api.h"
// #include <protocol_handler_windows/protocol_handler_windows_plugin_c_api.h>

namespace
{

  // Поднят ли токен процесса до администратора.
  bool IsProcessElevated()
  {
    HANDLE token = nullptr;
    if (!::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token))
    {
      return false;
    }
    TOKEN_ELEVATION elevation = {};
    DWORD size = 0;
    const bool ok = ::GetTokenInformation(token, TokenElevation, &elevation,
                                          sizeof(elevation), &size) != FALSE;
    ::CloseHandle(token);
    return ok && elevation.TokenIsElevated != 0;
  }

  bool HasFlag(const std::vector<std::string> &args, const char *flag)
  {
    for (const auto &arg : args)
    {
      if (arg == flag)
      {
        return true;
      }
    }
    return false;
  }

  // Перезапуск себя с запросом прав администратора.
  //
  // true  — elevated-копия стартовала, текущий процесс обязан молча выйти.
  // false — пользователь нажал «Нет» в UAC либо повышение невозможно; тогда
  //         работаем дальше без прав, а не закрываемся.
  bool RelaunchElevated()
  {
    wchar_t path[MAX_PATH] = {};
    if (::GetModuleFileNameW(nullptr, path, MAX_PATH) == 0)
    {
      return false;
    }

    SHELLEXECUTEINFOW info = {sizeof(SHELLEXECUTEINFOW)};
    info.lpVerb = L"runas";
    info.lpFile = path;
    // Флаг не даёт зациклиться: если повышение почему-то не сработало, вторая
    // копия уходит в ограниченный режим, а не открывает UAC по кругу.
    info.lpParameters = L"--no-elevate";
    info.nShow = SW_SHOWNORMAL;
    info.fMask = SEE_MASK_NOASYNC;
    return ::ShellExecuteExW(&info) != FALSE;
  }

} // namespace

bool SendAppLinkToInstance(const std::wstring &title)
{
  // Find our exact window
  HWND hwnd = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", title.c_str());

  if (hwnd)
  {
    // Dispatch new link to current window
    SendAppLink(hwnd);

    // (Optional) Restore our window to front in same state
    WINDOWPLACEMENT place = {sizeof(WINDOWPLACEMENT)};
    GetWindowPlacement(hwnd, &place);

    switch (place.showCmd)
    {
    case SW_SHOWMAXIMIZED:
      ShowWindow(hwnd, SW_SHOWMAXIMIZED);
      break;
    case SW_SHOWMINIMIZED:
      ShowWindow(hwnd, SW_RESTORE);
      break;
    default:
      ShowWindow(hwnd, SW_NORMAL);
      break;
    }

    SetWindowPos(0, HWND_TOP, 0, 0, 0, 0, SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
    SetForegroundWindow(hwnd);
    // END (Optional) Restore

    // Window has been found, don't create another one.
    return true;
  }

  return false;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command)
{

  // Replace "example" with the generated title found as parameter of `window.Create` in this file.
  // You may ignore the result if you need to create another window.
  if (SendAppLinkToInstance(L"AxiOm"))
  {
    return EXIT_SUCCESS;
  }

  // Права администратора нужны режиму службы VPN (TUN): виртуальный адаптер и
  // таблица маршрутов. Просим их здесь, а не манифестом, чтобы отказ в UAC не
  // означал «приложение не запустилось». Порядок важен: проверка чужого окна
  // выше нас — второй клик по ярлыку при уже запущенном приложении не должен
  // приводить к лишнему запросу UAC.
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  bool restricted_mode = false;
  if (!IsProcessElevated())
  {
    if (HasFlag(command_line_arguments, "--no-elevate") || !RelaunchElevated())
    {
      restricted_mode = true;
    }
    else
    {
      return EXIT_SUCCESS; // работу продолжает elevated-копия
    }
  }
  if (restricted_mode)
  {
    // Флаг читает Dart (`WindowsAdmin.init`): плашка в UI и подмена режима
    // службы на системный прокси, пока прав нет.
    command_line_arguments.push_back("--no-admin");
  }

  HANDLE hMutexInstance = CreateMutex(NULL, TRUE, L"AxiOmMutex");
  HWND handle = FindWindowA(NULL, "AxiOm");

  if (GetLastError() == ERROR_ALREADY_EXISTS)
  {
    flutter::DartProject project(L"data");
    project.set_dart_entrypoint_arguments(command_line_arguments);
    FlutterWindow window(project);
    if (window.SendAppLinkToInstance(L"AxiOm"))
    {
      return false;
    }

    WINDOWPLACEMENT place = {sizeof(WINDOWPLACEMENT)};
    GetWindowPlacement(handle, &place);
    ShowWindow(handle, SW_NORMAL);
    return 0;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent())
  {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(390, 780);
  if (!window.Create(L"AxiOm", origin, size))
  {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // Окно elevated-процесса по умолчанию не принимает сообщения от процессов с
  // обычными правами (UIPI). Без этого браузер не смог бы передать нам
  // deep-link `axiom://` — импорт подписки по ссылке молча перестал бы
  // работать. Разрешаем ровно то сообщение, которым пользуется app_links.
  if (HWND window_handle = window.GetHandle())
  {
    ::ChangeWindowMessageFilterEx(window_handle, WM_COPYDATA, MSGFLT_ALLOW, nullptr);
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0))
  {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ReleaseMutex(hMutexInstance);
  return EXIT_SUCCESS;
}
