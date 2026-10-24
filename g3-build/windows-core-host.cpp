#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdio>
#include <cwchar>
#include <string>
#include <shellapi.h>
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "shell32.lib")

namespace {
NOTIFYICONDATAW tray = {};
UINT taskbar_created = 0;
std::wstring gate_path;

bool updating() {
    HANDLE file = CreateFileW(gate_path.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    OVERLAPPED overlap = {};
    const BOOL locked = LockFileEx(file, LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &overlap);
    const DWORD error = GetLastError();
    CloseHandle(file);
    return !locked && error == ERROR_LOCK_VIOLATION;
}

LRESULT CALLBACK tray_window(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == taskbar_created) {
        Shell_NotifyIconW(NIM_ADD, &tray);
        return 0;
    }
    if (message == WM_TIMER) {
        if (updating()) DestroyWindow(window);
        return 0;
    }
    if (message == WM_APP + 1 && l == WM_RBUTTONUP) {
        HMENU menu = CreatePopupMenu();
        AppendMenuW(menu, MF_STRING | MF_DISABLED, 1, L"g3 OpsLinX Host - g3.28");
        AppendMenuW(menu, MF_STRING | MF_DISABLED, 2, L"Fernwartungsdienst im Hintergrund");
        POINT point = {}; GetCursorPos(&point);
        SetForegroundWindow(window);
        TrackPopupMenu(menu, TPM_RIGHTBUTTON, point.x, point.y, 0, window, nullptr);
        DestroyMenu(menu);
        PostMessageW(window, WM_NULL, 0, 0);
        return 0;
    }
    if (message == WM_DESTROY) {
        KillTimer(window, 1);
        Shell_NotifyIconW(NIM_DELETE, &tray);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, w, l);
}

int run_tray(const std::wstring& directory) {
    DWORD session = 0;
    if (!ProcessIdToSessionId(GetCurrentProcessId(), &session) || session == 0) return 0;
    // Local namespace gives each interactive session its own single tray icon.
    HANDLE single = CreateMutexW(nullptr, FALSE, L"Local\\g3OpsLinXHostTray");
    if (!single) return 2;
    if (GetLastError() == ERROR_ALREADY_EXISTS) { CloseHandle(single); return 0; }
    gate_path = directory + L"g3-update-session.lock";
    HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSW cls = {}; cls.lpfnWndProc = tray_window;
    cls.hInstance = instance; cls.lpszClassName = L"g3OpsLinXHostTray";
    if (!RegisterClassW(&cls)) { CloseHandle(single); return 2; }
    HWND window = CreateWindowExW(WS_EX_TOOLWINDOW, cls.lpszClassName, L"g3 OpsLinX Host",
        WS_POPUP, 0, 0, 0, 0, nullptr, nullptr, instance, nullptr);
    if (!window) { CloseHandle(single); return 2; }
    taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
    tray.cbSize = sizeof(tray); tray.hWnd = window; tray.uID = 1;
    tray.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    tray.uCallbackMessage = WM_APP + 1;
    tray.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(1));
    if (!tray.hIcon) tray.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    wcscpy_s(tray.szTip, L"g3 OpsLinX Host - Fernwartungsdienst");
    // Explorer may start later; TaskbarCreated retries registration then.
    Shell_NotifyIconW(NIM_ADD, &tray);
    if (!SetTimer(window, 1, 500, nullptr)) { DestroyWindow(window); CloseHandle(single); return 2; }
    MSG message = {}; BOOL result;
    while ((result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        TranslateMessage(&message); DispatchMessageW(&message);
    }
    CloseHandle(single);
    return result == -1 ? 2 : 0;
}
}

// Service/CLI entry point for Server Core. No Flutter, OpenGL or GUI plugins
// are linked. Authentication, transport and session leases stay in the native
// core; this launcher neither impersonates users nor implements a new server.
int wmain(int argc, wchar_t** argv) {
    if (argc >= 2 && wcscmp(argv[1], L"--cm") == 0) {
        std::puts("g3 OpsLinX Host Server Core: background service and administrative CLI only.");
        return 0;
    }
    wchar_t path[32768];
    const DWORD n = GetModuleFileNameW(nullptr, path, 32768);
    if (!n || n >= 32768) return 2;
    std::wstring file(path, n);
    const auto slash = file.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return 2;
    if (argc < 2 || wcscmp(argv[1], L"--tray") == 0)
        return run_tray(file.substr(0, slash + 1));
    const std::wstring dll = file.substr(0, slash + 1) + L"librustdesk.dll";
    // Explicit absolute path; dependencies can come only from this protected
    // application directory or System32, never the working directory/PATH.
    HMODULE core = LoadLibraryExW(dll.c_str(), nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!core) {
        std::fprintf(stderr, "Native core load failed: %lu\n", GetLastError());
        return 3;
    }
    using Main = char** (*)(int*);
    using Free = void (*)(char**, int);
    auto main = reinterpret_cast<Main>(GetProcAddress(core, "rustdesk_core_main_args"));
    auto release = reinterpret_cast<Free>(GetProcAddress(core, "free_c_args"));
    if (!main || !release) { FreeLibrary(core); return 4; }
    int count = 0;
    char** args = main(&count);
    if (args) {
        release(args, count);
        std::fputs("This operation requires a graphical client.\n", stderr);
        return 5;
    }
    // Native administrative commands can start worker/watch threads. Keep the
    // module alive until process shutdown rather than unloading their code.
    return 0;
}
