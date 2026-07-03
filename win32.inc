; win32.inc - Win32 API PROTOs for lal4s
; Extracted from cf22 color_iw.asm. Unused decls are harmless.

includelib kernel32.lib
includelib gdi32.lib
includelib user32.lib
includelib shell32.lib

AppendMenuA         PROTO :DWORD, :DWORD, :DWORD, :DWORD
BeginPaint         PROTO :DWORD, :DWORD
BitBlt             PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
CallNextHookEx     PROTO :DWORD, :DWORD, :DWORD, :DWORD
CallWindowProcA     PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
CloseClipboard     PROTO
CloseHandle        PROTO :DWORD
CreateCompatibleDC PROTO :DWORD
CreateDIBSection   PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
CreateFileA        PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
CreateFileMappingA PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
CreatePopupMenu     PROTO
CreateProcessA      PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
CreateWindowExA    PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
DefWindowProcA     PROTO :DWORD, :DWORD, :DWORD,:DWORD
DeleteDC           PROTO :DWORD
DeleteObject       PROTO :DWORD
DestroyMenu         PROTO :DWORD
DispatchMessageA   PROTO :DWORD
EmptyClipboard     PROTO
EndPaint           PROTO :DWORD, :DWORD
EnumChildWindows    PROTO :DWORD, :DWORD, :DWORD
EnumWindows         PROTO :DWORD, :DWORD
ExitProcess        PROTO :DWORD
FindWindowA         PROTO :DWORD, :DWORD
FindWindowExA       PROTO :DWORD, :DWORD, :DWORD, :DWORD
GetAsyncKeyState   PROTO :DWORD
GetClassNameA      PROTO :DWORD, :DWORD, :DWORD
GetCommandLineA    PROTO
GetCurrentObject   PROTO :DWORD, :DWORD
GetCursorPos       PROTO :DWORD
GetDC              PROTO :DWORD
GetFileSize        PROTO :DWORD, :DWORD
GetForegroundWindow PROTO
GetKeyState        PROTO :DWORD
GetKeyboardState   PROTO :DWORD
GetLastError       PROTO
GetWindowThreadProcessId PROTO :DWORD, :DWORD
GetCurrentThreadId  PROTO
AttachThreadInput   PROTO :DWORD, :DWORD, :DWORD
BringWindowToTop    PROTO :DWORD
SystemParametersInfoA PROTO :DWORD, :DWORD, :DWORD, :DWORD
SetTimer            PROTO :DWORD, :DWORD, :DWORD, :DWORD
KillTimer           PROTO :DWORD, :DWORD
GetTickCount        PROTO
FlushFileBuffers    PROTO :DWORD
GetMessageA        PROTO :DWORD, :DWORD, :DWORD, :DWORD
GetModuleHandleA   PROTO :DWORD
GetObjectA         PROTO :DWORD, :DWORD, :DWORD
GetPixel           PROTO :DWORD, :DWORD, :DWORD
GetProcAddress     PROTO :DWORD, :DWORD
GetSystemMetrics   PROTO :DWORD
GetWindowRect       PROTO :DWORD, :DWORD
GetWindowTextA      PROTO :DWORD, :DWORD, :DWORD
GlobalAlloc        PROTO :DWORD, :DWORD
GlobalLock         PROTO :DWORD
GlobalUnlock       PROTO :DWORD
InvalidateRect     PROTO :DWORD, :DWORD, :DWORD
IsWindowVisible     PROTO :DWORD
LoadCursorA        PROTO :DWORD, :DWORD
LoadIconA          PROTO :DWORD, :DWORD
LoadLibraryA       PROTO :DWORD
MapViewOfFile      PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
MapVirtualKeyA     PROTO :DWORD, :DWORD
MoveWindow          PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
SetWindowPos        PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
OpenClipboard      PROTO :DWORD
GetClipboardData   PROTO :DWORD
PeekMessageA       PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
PostMessageA        PROTO :DWORD, :DWORD, :DWORD, :DWORD
PostQuitMessage     PROTO :DWORD
ReadFile           PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
RegisterClassExA   PROTO :DWORD
RegisterHotKey     PROTO :DWORD, :DWORD, :DWORD, :DWORD
ReleaseDC          PROTO :DWORD, :DWORD
SelectObject       PROTO :DWORD, :DWORD
SendInput          PROTO :DWORD, :DWORD, :DWORD
SendMessageA        PROTO :DWORD, :DWORD, :DWORD, :DWORD
SendMessageTimeoutA PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
SetClipboardData   PROTO :DWORD, :DWORD
SetCursorPos       PROTO :DWORD, :DWORD
SetEndOfFile       PROTO :DWORD
SetFilePointer     PROTO :DWORD, :DWORD, :DWORD, :DWORD
SetFocus            PROTO :DWORD
SetForegroundWindow PROTO :DWORD
SetUnhandledExceptionFilter PROTO :DWORD
SetWindowLongA      PROTO :DWORD, :DWORD, :DWORD
SetWindowsHookExA  PROTO :DWORD, :DWORD, :DWORD, :DWORD
Shell_NotifyIconA  PROTO :DWORD, :DWORD
ShowWindow         PROTO :DWORD, :DWORD
Sleep              PROTO :DWORD
StretchDIBits      PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
ToAscii            PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
TrackPopupMenu      PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
TranslateMessage   PROTO :DWORD
UnhookWindowsHookEx PROTO :DWORD
UnmapViewOfFile    PROTO :DWORD
UnregisterHotKey   PROTO :DWORD, :DWORD
UpdateWindow       PROTO :DWORD
VirtualAlloc       PROTO :DWORD, :DWORD, :DWORD, :DWORD
VirtualFree        PROTO :DWORD, :DWORD, :DWORD
WriteFile          PROTO :DWORD, :DWORD, :DWORD, :DWORD, :DWORD
