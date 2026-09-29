#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <windowsx.h>
#include <stdint.h>
#include <stdlib.h>
#include <wchar.h>

namespace {

HMODULE g_self = nullptr;
HMODULE g_realVersion = nullptr;
INIT_ONCE g_realVersionInit = INIT_ONCE_STATIC_INIT;
HWND g_gameWindow = nullptr;
WNDPROC g_previousWndProc = nullptr;
SRWLOCK g_stateLock = INIT_SRWLOCK;
volatile LONG g_pressed = 0;
volatile LONG g_sendRunning = 0;
ULONGLONG g_lastAcceptedClick = 0;
const UINT_PTR kPaintTimerId = 0x53B1;
const wchar_t* kButtonText = L"\uBC84\uD504";
const wchar_t* kBuffCommand = L".\uBC84\uD504";

struct ButtonConfig {
    int width;
    int height;
    int offsetX;
    int offsetY;
    int fontSize;
    int logEnabled;
};

ButtonConfig g_config = {72, 26, 56, 60, 14, 1};

void GetSelfDirectory(wchar_t* output, size_t capacity) {
    if (output == nullptr || capacity == 0) {
        return;
    }
    output[0] = L'\0';
    wchar_t modulePath[MAX_PATH] = {0};
    if (GetModuleFileNameW(g_self, modulePath, MAX_PATH) == 0) {
        return;
    }
    wchar_t* slash = wcsrchr(modulePath, L'\\');
    if (slash != nullptr) {
        *slash = L'\0';
    }
    wcsncpy_s(output, capacity, modulePath, _TRUNCATE);
}

void BuildLocalPath(const wchar_t* fileName, wchar_t* output, size_t capacity) {
    wchar_t directory[MAX_PATH] = {0};
    GetSelfDirectory(directory, _countof(directory));
    if (directory[0] == L'\0') {
        wcsncpy_s(output, capacity, fileName, _TRUNCATE);
        return;
    }
    _snwprintf_s(output, capacity, _TRUNCATE, L"%s\\%s", directory, fileName);
}

void WriteLog(const wchar_t* message) {
    if (g_config.logEnabled == 0 || message == nullptr) {
        return;
    }

    wchar_t logPath[MAX_PATH] = {0};
    BuildLocalPath(L"StarBuffButton.log", logPath, _countof(logPath));
    HANDLE file = CreateFileW(logPath, FILE_APPEND_DATA,
            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return;
    }

    SYSTEMTIME now = {};
    GetLocalTime(&now);
    wchar_t line[512] = {0};
    _snwprintf_s(line, _countof(line), _TRUNCATE,
            L"%04u-%02u-%02u %02u:%02u:%02u.%03u [StarBuffButton] %s\r\n",
            now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
            now.wSecond, now.wMilliseconds, message);

    DWORD bytesWritten = 0;
    WriteFile(file, line, static_cast<DWORD>(wcslen(line) * sizeof(wchar_t)),
            &bytesWritten, nullptr);
    CloseHandle(file);
}

void LoadConfig() {
    wchar_t iniPath[MAX_PATH] = {0};
    BuildLocalPath(L"StarBuffButton.ini", iniPath, _countof(iniPath));

    g_config.width = GetPrivateProfileIntW(L"Button", L"Width", 72, iniPath);
    g_config.height = GetPrivateProfileIntW(L"Button", L"Height", 26, iniPath);
    g_config.offsetX = GetPrivateProfileIntW(L"Button", L"OffsetX", 56, iniPath);
    g_config.offsetY = GetPrivateProfileIntW(L"Button", L"OffsetY", 60, iniPath);
    g_config.fontSize = GetPrivateProfileIntW(L"Button", L"FontSize", 14, iniPath);
    g_config.logEnabled = GetPrivateProfileIntW(L"Diagnostics", L"EnableLog", 1, iniPath);

    if (g_config.width < 40 || g_config.width > 240) g_config.width = 72;
    if (g_config.height < 18 || g_config.height > 100) g_config.height = 26;
    if (g_config.offsetX < 0 || g_config.offsetX > 1000) g_config.offsetX = 56;
    if (g_config.offsetY < 0 || g_config.offsetY > 1000) g_config.offsetY = 60;
    if (g_config.fontSize < 10 || g_config.fontSize > 36) g_config.fontSize = 14;
}

BOOL CALLBACK InitRealVersionModule(PINIT_ONCE, PVOID, PVOID*) {
    wchar_t systemDirectory[MAX_PATH] = {0};
    const UINT length = GetSystemDirectoryW(systemDirectory, MAX_PATH);
    if (length == 0 || length >= MAX_PATH - 16) {
        return TRUE;
    }
    wchar_t path[MAX_PATH] = {0};
    _snwprintf_s(path, _countof(path), _TRUNCATE, L"%s\\version.dll",
            systemDirectory);
    g_realVersion = LoadLibraryW(path);
    return TRUE;
}

FARPROC ResolveRealVersionProc(const char* name) {
    InitOnceExecuteOnce(&g_realVersionInit, InitRealVersionModule, nullptr, nullptr);
    if (g_realVersion == nullptr) {
        SetLastError(ERROR_MOD_NOT_FOUND);
        return nullptr;
    }
    FARPROC proc = GetProcAddress(g_realVersion, name);
    if (proc == nullptr) {
        SetLastError(ERROR_PROC_NOT_FOUND);
    }
    return proc;
}

RECT GetButtonRect(HWND hwnd) {
    RECT client = {0, 0, 0, 0};
    GetClientRect(hwnd, &client);
    const int clientWidth = client.right - client.left;
    const int clientHeight = client.bottom - client.top;
    int x = clientWidth - g_config.width - g_config.offsetX;
    int y = clientHeight - g_config.height - g_config.offsetY;
    if (x < 4) x = 4;
    if (y < 4) y = 4;
    RECT button = {x, y, x + g_config.width, y + g_config.height};
    return button;
}

bool PointInButton(HWND hwnd, LPARAM lParam) {
    POINT point = {GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
    const RECT button = GetButtonRect(hwnd);
    return PtInRect(&button, point) != FALSE;
}

void DrawButton(HWND hwnd) {
    if (!IsWindow(hwnd) || IsIconic(hwnd)) {
        return;
    }
    HDC dc = GetDC(hwnd);
    if (dc == nullptr) {
        return;
    }

    const RECT button = GetButtonRect(hwnd);
    const bool pressed = InterlockedCompareExchange(&g_pressed, 0, 0) != 0;
    HBRUSH background = CreateSolidBrush(
            pressed ? RGB(56, 45, 24) : RGB(25, 25, 28));
    HBRUSH border = CreateSolidBrush(
            pressed ? RGB(255, 222, 122) : RGB(194, 155, 67));
    FillRect(dc, &button, background);
    FrameRect(dc, &button, border);

    HFONT font = CreateFontW(-g_config.fontSize, 0, 0, 0, FW_BOLD,
            FALSE, FALSE, FALSE, HANGEUL_CHARSET, OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
            DEFAULT_PITCH | FF_DONTCARE, L"Malgun Gothic");
    HFONT oldFont = nullptr;
    if (font != nullptr) {
        oldFont = static_cast<HFONT>(SelectObject(dc, font));
    }
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc,
            pressed ? RGB(255, 244, 196) : RGB(235, 217, 167));
    RECT textRect = button;
    DrawTextW(dc, kButtonText, -1, &textRect,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);

    if (oldFont != nullptr) SelectObject(dc, oldFont);
    if (font != nullptr) DeleteObject(font);
    DeleteObject(background);
    DeleteObject(border);
    ReleaseDC(hwnd, dc);
}

void PostVirtualKey(HWND hwnd, UINT virtualKey) {
    const UINT scanCode = MapVirtualKeyW(virtualKey, MAPVK_VK_TO_VSC);
    const LPARAM down = 1 | (static_cast<LPARAM>(scanCode) << 16);
    const LPARAM up = down | (static_cast<LPARAM>(1) << 30)
            | (static_cast<LPARAM>(1) << 31);
    PostMessageW(hwnd, WM_KEYDOWN, virtualKey, down);
    PostMessageW(hwnd, WM_KEYUP, virtualKey, up);
}

bool PostCommandCharacter(HWND hwnd, wchar_t character) {
    if (IsWindowUnicode(hwnd)) {
        return PostMessageW(hwnd, WM_CHAR, static_cast<WPARAM>(character), 1)
                != FALSE;
    }

    char bytes[4] = {0};
    BOOL usedDefault = FALSE;
    const int count = WideCharToMultiByte(949, WC_NO_BEST_FIT_CHARS,
            &character, 1, bytes, static_cast<int>(sizeof(bytes)), nullptr,
            &usedDefault);
    if (count <= 0 || usedDefault) {
        return false;
    }
    for (int index = 0; index < count; ++index) {
        const unsigned char value = static_cast<unsigned char>(bytes[index]);
        if (!PostMessageA(hwnd, WM_CHAR, static_cast<WPARAM>(value), 1)) {
            return false;
        }
        Sleep(3);
    }
    return true;
}

DWORD WINAPI SendBuffActionThread(LPVOID parameter) {
    HWND hwnd = static_cast<HWND>(parameter);
    if (!IsWindow(hwnd)) {
        InterlockedExchange(&g_sendRunning, 0);
        return 0;
    }

    WriteLog(L"button accepted; posting existing user command .buff(Korean)");
    SetForegroundWindow(hwnd);
    SetFocus(hwnd);

    PostVirtualKey(hwnd, VK_RETURN);
    Sleep(60);

    bool posted = true;
    for (const wchar_t* cursor = kBuffCommand; *cursor != L'\0'; ++cursor) {
        if (!PostCommandCharacter(hwnd, *cursor)) {
            posted = false;
            break;
        }
        Sleep(4);
    }

    if (posted) {
        Sleep(45);
        PostVirtualKey(hwnd, VK_RETURN);
        WriteLog(L"existing .buff(Korean) command was posted");
    } else {
        WriteLog(L"failed to encode or post the Korean buff command");
        PostVirtualKey(hwnd, VK_ESCAPE);
    }

    InterlockedExchange(&g_sendRunning, 0);
    return 0;
}

LRESULT CallPreviousWindowProc(HWND hwnd, UINT message, WPARAM wParam,
        LPARAM lParam) {
    if (g_previousWndProc == nullptr) {
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }
    if (IsWindowUnicode(hwnd)) {
        return CallWindowProcW(g_previousWndProc, hwnd, message, wParam, lParam);
    }
    return CallWindowProcA(g_previousWndProc, hwnd, message, wParam, lParam);
}

LRESULT CALLBACK BuffWindowProc(HWND hwnd, UINT message, WPARAM wParam,
        LPARAM lParam) {
    switch (message) {
        case WM_LBUTTONDOWN:
            if (PointInButton(hwnd, lParam)) {
                InterlockedExchange(&g_pressed, 1);
                SetCapture(hwnd);
                DrawButton(hwnd);
                return 0;
            }
            break;

        case WM_LBUTTONUP: {
            const bool wasPressed = InterlockedExchange(&g_pressed, 0) != 0;
            if (wasPressed) {
                if (GetCapture() == hwnd) ReleaseCapture();
                const bool matched = PointInButton(hwnd, lParam);
                DrawButton(hwnd);
                if (matched) {
                    const ULONGLONG now = GetTickCount64();
                    bool allowed = false;
                    AcquireSRWLockExclusive(&g_stateLock);
                    if (now - g_lastAcceptedClick >= 750) {
                        g_lastAcceptedClick = now;
                        allowed = true;
                    }
                    ReleaseSRWLockExclusive(&g_stateLock);

                    if (allowed
                            && InterlockedCompareExchange(&g_sendRunning, 1, 0)
                                    == 0) {
                        HANDLE thread = CreateThread(nullptr, 0,
                                SendBuffActionThread, hwnd, 0, nullptr);
                        if (thread != nullptr) {
                            CloseHandle(thread);
                        } else {
                            InterlockedExchange(&g_sendRunning, 0);
                            WriteLog(L"CreateThread failed while sending .buff(Korean)");
                        }
                    }
                }
                return 0;
            }
            break;
        }

        case WM_CANCELMODE:
        case WM_CAPTURECHANGED:
        case WM_KILLFOCUS:
            if (InterlockedExchange(&g_pressed, 0) != 0) DrawButton(hwnd);
            break;

        case WM_TIMER:
            if (wParam == kPaintTimerId) {
                LRESULT result = CallPreviousWindowProc(hwnd, message, wParam,
                        lParam);
                DrawButton(hwnd);
                return result;
            }
            break;

        case WM_PAINT: {
            LRESULT result = CallPreviousWindowProc(hwnd, message, wParam,
                    lParam);
            DrawButton(hwnd);
            return result;
        }

        case WM_NCDESTROY:
            KillTimer(hwnd, kPaintTimerId);
            g_gameWindow = nullptr;
            break;
    }
    return CallPreviousWindowProc(hwnd, message, wParam, lParam);
}

struct WindowSearchContext {
    DWORD processId;
    HWND window;
};

BOOL CALLBACK FindGameWindowCallback(HWND hwnd, LPARAM lParam) {
    WindowSearchContext* context =
            reinterpret_cast<WindowSearchContext*>(lParam);
    DWORD ownerProcessId = 0;
    GetWindowThreadProcessId(hwnd, &ownerProcessId);
    if (ownerProcessId != context->processId || !IsWindowVisible(hwnd)) {
        return TRUE;
    }
    RECT client = {0, 0, 0, 0};
    if (!GetClientRect(hwnd, &client)) return TRUE;
    if ((client.right - client.left) < 400
            || (client.bottom - client.top) < 300) {
        return TRUE;
    }
    context->window = hwnd;
    return FALSE;
}

HWND FindGameWindow() {
    WindowSearchContext context = {GetCurrentProcessId(), nullptr};
    EnumWindows(FindGameWindowCallback, reinterpret_cast<LPARAM>(&context));
    return context.window;
}

DWORD WINAPI InstallHookThread(LPVOID) {
    LoadConfig();
    WriteLog(L"version proxy loaded; waiting for Star game window");

    for (int attempt = 0; attempt < 180; ++attempt) {
        HWND hwnd = FindGameWindow();
        if (hwnd != nullptr) {
            Sleep(2000);
            if (!IsWindow(hwnd)) continue;

            SetLastError(ERROR_SUCCESS);
            LONG_PTR previous = SetWindowLongPtrW(hwnd, GWLP_WNDPROC,
                    reinterpret_cast<LONG_PTR>(BuffWindowProc));
            if (previous == 0 && GetLastError() != ERROR_SUCCESS) {
                WriteLog(L"SetWindowLongPtr failed; button was not installed");
                return 0;
            }

            g_gameWindow = hwnd;
            g_previousWndProc = reinterpret_cast<WNDPROC>(previous);
            SetTimer(hwnd, kPaintTimerId, 33, nullptr);
            DrawButton(hwnd);
            WriteLog(L"button installed successfully");
            return 0;
        }
        Sleep(500);
    }

    WriteLog(L"game window was not found within 90 seconds");
    return 0;
}

} // namespace

extern "C" BOOL WINAPI Proxy_GetFileVersionInfoA(LPCSTR fileName, DWORD handle,
        DWORD length, LPVOID data) {
    using Function = BOOL(WINAPI*)(LPCSTR, DWORD, DWORD, LPVOID);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("GetFileVersionInfoA"));
    return function != nullptr ? function(fileName, handle, length, data) : FALSE;
}

extern "C" BOOL WINAPI Proxy_GetFileVersionInfoW(LPCWSTR fileName, DWORD handle,
        DWORD length, LPVOID data) {
    using Function = BOOL(WINAPI*)(LPCWSTR, DWORD, DWORD, LPVOID);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("GetFileVersionInfoW"));
    return function != nullptr ? function(fileName, handle, length, data) : FALSE;
}

extern "C" BOOL WINAPI Proxy_GetFileVersionInfoExA(DWORD flags, LPCSTR fileName,
        DWORD handle, DWORD length, LPVOID data) {
    using Function = BOOL(WINAPI*)(DWORD, LPCSTR, DWORD, DWORD, LPVOID);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("GetFileVersionInfoExA"));
    return function != nullptr
            ? function(flags, fileName, handle, length, data) : FALSE;
}

extern "C" BOOL WINAPI Proxy_GetFileVersionInfoExW(DWORD flags,
        LPCWSTR fileName, DWORD handle, DWORD length, LPVOID data) {
    using Function = BOOL(WINAPI*)(DWORD, LPCWSTR, DWORD, DWORD, LPVOID);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("GetFileVersionInfoExW"));
    return function != nullptr
            ? function(flags, fileName, handle, length, data) : FALSE;
}

extern "C" DWORD WINAPI Proxy_GetFileVersionInfoSizeA(LPCSTR fileName,
        LPDWORD handle) {
    using Function = DWORD(WINAPI*)(LPCSTR, LPDWORD);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("GetFileVersionInfoSizeA"));
    return function != nullptr ? function(fileName, handle) : 0;
}

extern "C" DWORD WINAPI Proxy_GetFileVersionInfoSizeW(LPCWSTR fileName,
        LPDWORD handle) {
    using Function = DWORD(WINAPI*)(LPCWSTR, LPDWORD);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("GetFileVersionInfoSizeW"));
    return function != nullptr ? function(fileName, handle) : 0;
}

extern "C" DWORD WINAPI Proxy_GetFileVersionInfoSizeExA(DWORD flags,
        LPCSTR fileName, LPDWORD handle) {
    using Function = DWORD(WINAPI*)(DWORD, LPCSTR, LPDWORD);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("GetFileVersionInfoSizeExA"));
    return function != nullptr ? function(flags, fileName, handle) : 0;
}

extern "C" DWORD WINAPI Proxy_GetFileVersionInfoSizeExW(DWORD flags,
        LPCWSTR fileName, LPDWORD handle) {
    using Function = DWORD(WINAPI*)(DWORD, LPCWSTR, LPDWORD);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("GetFileVersionInfoSizeExW"));
    return function != nullptr ? function(flags, fileName, handle) : 0;
}

extern "C" DWORD WINAPI Proxy_GetFileVersionInfoByHandle(DWORD flags,
        HANDLE file, LPVOID data, DWORD length) {
    using Function = DWORD(WINAPI*)(DWORD, HANDLE, LPVOID, DWORD);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("GetFileVersionInfoByHandle"));
    return function != nullptr ? function(flags, file, data, length) : 0;
}

extern "C" DWORD WINAPI Proxy_VerFindFileA(DWORD flags, LPCSTR fileName,
        LPCSTR windowsDir, LPCSTR appDir, LPSTR currentDir,
        PUINT currentDirLength, LPSTR destinationDir,
        PUINT destinationDirLength) {
    using Function = DWORD(WINAPI*)(DWORD, LPCSTR, LPCSTR, LPCSTR, LPSTR,
            PUINT, LPSTR, PUINT);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("VerFindFileA"));
    return function != nullptr ? function(flags, fileName, windowsDir, appDir,
            currentDir, currentDirLength, destinationDir,
            destinationDirLength) : 0;
}

extern "C" DWORD WINAPI Proxy_VerFindFileW(DWORD flags, LPCWSTR fileName,
        LPCWSTR windowsDir, LPCWSTR appDir, LPWSTR currentDir,
        PUINT currentDirLength, LPWSTR destinationDir,
        PUINT destinationDirLength) {
    using Function = DWORD(WINAPI*)(DWORD, LPCWSTR, LPCWSTR, LPCWSTR, LPWSTR,
            PUINT, LPWSTR, PUINT);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("VerFindFileW"));
    return function != nullptr ? function(flags, fileName, windowsDir, appDir,
            currentDir, currentDirLength, destinationDir,
            destinationDirLength) : 0;
}

extern "C" DWORD WINAPI Proxy_VerInstallFileA(DWORD flags,
        LPCSTR sourceFileName, LPCSTR destinationFileName, LPCSTR sourceDir,
        LPCSTR destinationDir, LPCSTR currentDir, LPSTR tempFile,
        PUINT tempFileLength) {
    using Function = DWORD(WINAPI*)(DWORD, LPCSTR, LPCSTR, LPCSTR, LPCSTR,
            LPCSTR, LPSTR, PUINT);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("VerInstallFileA"));
    return function != nullptr ? function(flags, sourceFileName,
            destinationFileName, sourceDir, destinationDir, currentDir,
            tempFile, tempFileLength) : 0;
}

extern "C" DWORD WINAPI Proxy_VerInstallFileW(DWORD flags,
        LPCWSTR sourceFileName, LPCWSTR destinationFileName, LPCWSTR sourceDir,
        LPCWSTR destinationDir, LPCWSTR currentDir, LPWSTR tempFile,
        PUINT tempFileLength) {
    using Function = DWORD(WINAPI*)(DWORD, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR,
            LPCWSTR, LPWSTR, PUINT);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("VerInstallFileW"));
    return function != nullptr ? function(flags, sourceFileName,
            destinationFileName, sourceDir, destinationDir, currentDir,
            tempFile, tempFileLength) : 0;
}

extern "C" DWORD WINAPI Proxy_VerLanguageNameA(DWORD language, LPSTR buffer,
        DWORD size) {
    using Function = DWORD(WINAPI*)(DWORD, LPSTR, DWORD);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("VerLanguageNameA"));
    return function != nullptr ? function(language, buffer, size) : 0;
}

extern "C" DWORD WINAPI Proxy_VerLanguageNameW(DWORD language, LPWSTR buffer,
        DWORD size) {
    using Function = DWORD(WINAPI*)(DWORD, LPWSTR, DWORD);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("VerLanguageNameW"));
    return function != nullptr ? function(language, buffer, size) : 0;
}

extern "C" BOOL WINAPI Proxy_VerQueryValueA(LPCVOID block, LPCSTR subBlock,
        LPVOID* buffer, PUINT length) {
    using Function = BOOL(WINAPI*)(LPCVOID, LPCSTR, LPVOID*, PUINT);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("VerQueryValueA"));
    return function != nullptr ? function(block, subBlock, buffer, length)
            : FALSE;
}

extern "C" BOOL WINAPI Proxy_VerQueryValueW(LPCVOID block, LPCWSTR subBlock,
        LPVOID* buffer, PUINT length) {
    using Function = BOOL(WINAPI*)(LPCVOID, LPCWSTR, LPVOID*, PUINT);
    Function function = reinterpret_cast<Function>(
            ResolveRealVersionProc("VerQueryValueW"));
    return function != nullptr ? function(block, subBlock, buffer, length)
            : FALSE;
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = module;
        DisableThreadLibraryCalls(module);
        HANDLE thread = CreateThread(nullptr, 0, InstallHookThread, nullptr, 0,
                nullptr);
        if (thread != nullptr) CloseHandle(thread);
    } else if (reason == DLL_PROCESS_DETACH) {
        if (g_gameWindow != nullptr && g_previousWndProc != nullptr
                && IsWindow(g_gameWindow)) {
            KillTimer(g_gameWindow, kPaintTimerId);
            SetWindowLongPtrW(g_gameWindow, GWLP_WNDPROC,
                    reinterpret_cast<LONG_PTR>(g_previousWndProc));
        }
        if (g_realVersion != nullptr) {
            FreeLibrary(g_realVersion);
            g_realVersion = nullptr;
        }
    }
    return TRUE;
}
