#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // ── Single-instance guard ──────────────────────────────────────────────────
  // Create a named mutex. If it already exists (ERROR_ALREADY_EXISTS),
  // another instance is running — exit silently.
  // bInitialOwner=FALSE so we don't have to release it; the OS releases
  // it atomically when this process exits.
  HANDLE hMutex = ::CreateMutex(nullptr, FALSE, L"VoiceForge_SingleInstance_Mutex_v1");
  if (hMutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ::CloseHandle(hMutex);
    return EXIT_SUCCESS;  // Another instance is running — quit silently
  }
  // ──────────────────────────────────────────────────────────────────────────

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"voice_forge_ui", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (hMutex != nullptr) ::CloseHandle(hMutex);
  return EXIT_SUCCESS;
}
