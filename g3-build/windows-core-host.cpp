#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdio>
#include <cwchar>
#include <string>

// Service/CLI entry point for Server Core. No Flutter, OpenGL or GUI plugins
// are linked. Authentication, transport and session leases stay in the native
// core; this launcher neither impersonates users nor implements a new server.
int wmain(int argc, wchar_t** argv) {
    if (argc < 2 || wcscmp(argv[1], L"--tray") == 0 || wcscmp(argv[1], L"--cm") == 0) {
        std::puts("g3 OpsLinX Host Server Core: background service and administrative CLI only.");
        return 0;
    }
    wchar_t path[32768];
    const DWORD n = GetModuleFileNameW(nullptr, path, 32768);
    if (!n || n >= 32768) return 2;
    std::wstring file(path, n);
    const auto slash = file.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return 2;
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
