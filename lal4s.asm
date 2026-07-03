; ============================================================================
;  lal4s - standalone snippet / automation runner (AHK-like), no Forth kernel.
;
;  Extracted from cf22 color_iw.asm. The snippet engine (`run_script`) is a
;  self-contained mini-interpreter with its own stack (`script_stk`) and its own
;  command table (`sc_name_*` -> handlers), so it lifts out cleanly. This file
;  is the NEW glue: WinMain + a standard Windows message loop + a small
;  wnd_proc, replacing the Forth interpreter's key-wait pump.
;
;  Clean W^X PE: no runtime codegen, no RWX JIT, standard .code/.data sections.
;  See EXTRACTION_PLAN.md for the exact routines to lift (with source line refs).
; ============================================================================

.486p
.MODEL flat, stdcall

include win32.inc

WM_DESTROY   equ 0002h
WM_COMMAND   equ 0111h
WM_TIMER     equ 0113h
WM_HOTKEY    equ 0312h
WM_LBUTTONDBLCLK equ 0203h
WM_RBUTTONUP equ 0205h
WM_APP       equ 8000h
WM_TRAYCB    equ WM_APP+1          ; tray notification callback (match install_tray)
TRAY_MENU_EXIT equ 1002           ; tray "Exit" menu id (used by install_tray + wnd_proc)
; picker <-> LL-hook message channel (hook posts, picker_wnd_proc/main handle)
WM_SHOW_PICKER   equ 402h
WM_CLOSE_PICKER  equ 405h
WM_PICKER_INS_P1 equ 406h
WM_PICKER_INS_P2 equ 407h
WM_CONSENT_REJECT equ 408h        ; Ctrl+Alt+R -> helpers.dll ConsentRejectAll

MSG          struc
  m_hwnd     dd ?
  m_message  dd ?
  m_wParam   dd ?
  m_lParam   dd ?
  m_time     dd ?
  m_pt_x     dd ?
  m_pt_y     dd ?
MSG          ends

WNDCLASSEX   struc
  wc_cbSize        dd ?
  wc_style         dd ?
  wc_lpfnWndProc   dd ?
  wc_cbClsExtra    dd ?
  wc_cbWndExtra    dd ?
  wc_hInstance     dd ?
  wc_hIcon         dd ?
  wc_hCursor       dd ?
  wc_hbrBackground dd ?
  wc_lpszMenuName  dd ?
  wc_lpszClassName dd ?
  wc_hIconSm       dd ?
WNDCLASSEX   ends

.data
hinst        dd 0
hwndmsg      dd 0
hhook        dd 0                  ; LL keyboard hook handle (set by install_hook)
wmsg         MSG        <>     ; not "msg" — ML is case-insensitive, collides with MSG
wc           WNDCLASSEX <>
clsname      db 'lal4s', 0

; --- LIFTED DATA lives in snippets.asm (see EXTRACTION_PLAN.md): the snippet
;     table, script_stk/script_sp, hotkey table, sc_name_* strings +
;     sc_cmd_table, picker/tray data, helpers.dll fn ptrs, sni_input_buf. ---

.code
code_begin:

; ---------------------------------------------------------------------------
;  Entry point. Boot order mirrors color_iw minus the Forth kernel.
; ---------------------------------------------------------------------------
_start:
    push   0
    call   GetModuleHandleA
    mov    [hinst], eax

    call   open_dbg_log             ; snippets.asm: opens lal4s_debug.log (test/img diag)
    call   install_seh              ; snippets.asm: crash dump + recover-to-loop
    call   parse_cmdline            ; LIFT: optional snippets-file arg
    call   load_default_skip_classes ; LIFT
    call   load_settings_txt        ; LIFT (optional)
    call   parse_snippets_txt       ; LIFT: build snippet + hotkey tables
    call   load_image_dll           ; LIFT: best-effort (image search + helpers.dll)
    call   create_msgwin            ; NEW (below): hidden window for hotkeys + tray
    call   register_hotkeys         ; LIFT: retarget [hwndmain] -> [hwndmsg]
    call   install_tray             ; LIFT: retarget [hwndmain] -> [hwndmsg]
    call   install_hook             ; LIFT: SetWindowsHookEx(WH_KEYBOARD_LL)
    call   log_boot_state           ; snippets.asm: dump snippets/DLL/skip-list to log

; ---- message loop (replaces the Forth key-wait pump) ----
msg_loop:
    call   save_safe_state          ; snippets.asm: refresh the SEH recovery point
    push   0
    push   0
    push   0
    push   offset wmsg
    call   GetMessageA              ; 0 = WM_QUIT, -1 = error, else > 0
    test   eax, eax
    jle    msg_done
    push   offset wmsg
    call   TranslateMessage
    push   offset wmsg
    call   DispatchMessageA
    jmp    msg_loop
msg_done:
    call   remove_hook             ; NEW
    call   unregister_hotkeys      ; snippets.asm: tidy WM_HOTKEY registrations
    call   remove_tray            ; snippets.asm: Shell_NotifyIcon NIM_DELETE
    push   0
    call   ExitProcess

; ---------------------------------------------------------------------------
;  create_msgwin - register class + hidden window -> [hwndmsg]
;  (hotkeys and the tray callback are delivered to this window's wnd_proc)
; ---------------------------------------------------------------------------
create_msgwin:
    mov    [wc.wc_cbSize], sizeof WNDCLASSEX
    mov    [wc.wc_style], 0
    mov    [wc.wc_lpfnWndProc], offset lal4s_wnd_proc
    mov    [wc.wc_cbClsExtra], 0
    mov    [wc.wc_cbWndExtra], 0
    mov    eax, [hinst]
    mov    [wc.wc_hInstance], eax
    mov    [wc.wc_hIcon], 0
    mov    [wc.wc_hCursor], 0
    mov    [wc.wc_hbrBackground], 0
    mov    [wc.wc_lpszMenuName], 0
    mov    [wc.wc_lpszClassName], offset clsname
    mov    [wc.wc_hIconSm], 0
    push   offset wc
    call   RegisterClassExA
    ; CreateWindowExA(0, clsname, clsname, 0(WS_OVERLAPPED), 0,0,0,0, 0,0, hinst,0)
    push   0
    push   [hinst]
    push   0
    push   0
    push   0                        ; nHeight
    push   0                        ; nWidth
    push   0                        ; y
    push   0                        ; x
    push   0                        ; dwStyle (not shown -> hidden)
    push   offset clsname           ; window name
    push   offset clsname           ; class name
    push   0                        ; dwExStyle
    call   CreateWindowExA
    mov    [hwndmsg], eax
    ret

; ---------------------------------------------------------------------------
;  lal4s_wnd_proc - the whole coupling fix. color_iw routed WM_HOTKEY ->
;  run_script from its big editor wnd_proc, pumped inside the Forth loop;
;  lal4s does it here from a plain message loop.
; ---------------------------------------------------------------------------
lal4s_wnd_proc proc hWnd:DWORD, uMsg:DWORD, wParam:DWORD, lParam:DWORD
    mov    eax, uMsg
    cmp    eax, WM_HOTKEY
    je     lw_hotkey
    cmp    eax, WM_TRAYCB
    je     lw_tray
    cmp    eax, WM_COMMAND
    je     lw_command
    cmp    eax, WM_SHOW_PICKER
    je     lw_showpicker
    cmp    eax, WM_CONSENT_REJECT
    je     lw_consent
    cmp    eax, WM_TIMER
    je     lw_timer
    cmp    eax, WM_DESTROY
    je     lw_destroy
    push   lParam
    push   wParam
    push   uMsg
    push   hWnd
    call   DefWindowProcA
    ret
lw_hotkey:                          ; wParam = hotkey id = snippet index.
    pushad                          ; log "[HOTKEY] fired id=NN"
    mov    edx, offset dbg_msg_hk_fire
    call   dbg_writez
    mov    eax, wParam
    call   dbg_writehex8
    call   dbg_writecrlf
    popad
    mov    ecx, wParam              ; expand_paste_no_bs routes `:::` scripts to
    call   expand_paste_no_bs      ;   run_script and `::` text to clipboard+Ctrl+V.
    xor    eax, eax
    ret
lw_tray:                            ; lParam = mouse msg. Right-click / double-click
    mov    eax, lParam             ;   -> pop the tray menu (snippets.asm).
    cmp    eax, WM_RBUTTONUP
    je     lw_tray_menu
    cmp    eax, WM_LBUTTONDBLCLK
    je     lw_tray_menu
    xor    eax, eax
    ret
lw_tray_menu:
    call   tray_show_menu
    xor    eax, eax
    ret
lw_command:                         ; menu selection. Low word of wParam = id.
    mov    eax, wParam
    and    eax, 0FFFFh
    cmp    eax, TRAY_MENU_EXIT
    jne    lw_cmd_ret
    push   0                        ; Exit -> quit the message loop
    call   PostQuitMessage
lw_cmd_ret:
    xor    eax, eax
    ret
lw_showpicker:                      ; CapsLock / Ctrl+Shift+Space (LL hook) -> picker
    call   show_picker             ; snippets.asm (picker_mode: 0 snippets, 1 tabnav)
    xor    eax, eax
    ret
lw_consent:                         ; Ctrl+Alt+R (LL hook). wParam = target HWND.
    cmp    dword ptr [consent_reject_fn], 0
    je     lw_consent_done
    mov    eax, wParam
    push   eax                      ; ConsentRejectAll(hwnd) — helpers.dll UIA
    call   [consent_reject_fn]
lw_consent_done:
    mov    dword ptr [consent_busy], 0   ; allow the next Ctrl+Alt+R to enqueue
    xor    eax, eax
    ret
lw_timer:                           ; background capture tick. wParam = timer id.
    mov    ecx, wParam
    call   winshot_on_timer         ; snippets.asm: capture + limit check
    xor    eax, eax
    ret
lw_destroy:
    push   0
    call   PostQuitMessage
    xor    eax, eax
    ret
lal4s_wnd_proc endp

; ---------------------------------------------------------------------------
remove_hook:                        ; NEW: UnhookWindowsHookEx([hhook])
    cmp    dword ptr [hhook], 0
    je     rh_ret
    push   [hhook]
    call   UnhookWindowsHookEx
    mov    dword ptr [hhook], 0
rh_ret:
    ret

; ===========================================================================
;  LIFTED CODE — snippet engine + primitives + config parsers + hotkeys +
;  LL hook. See snippets.asm (lifted/adapted from D:\cf22\color_iw.asm).
;
;  All 68 cf22 script commands are lifted (see snippets.asm / SCRIPTING.md):
;  the engine (run_script, scr_push/pop, script_cmds), every primitive
;  (keyboard/mouse, pixel*, img*, window-nav/run, the expect_* test suite,
;  ctrl_text/statusbar/winctrls, ocr_digit/mouselog, winshot/debug_box, web*),
;  the config parsers, hotkeys, the LL hook, the dbg log, the default tray icon
;  (install_tray/remove_tray/tray_show_menu), and the CapsLock snippet picker
;  (show_picker/picker_wnd_proc/picker_edit_proc). load_image_dll resolves the
;  helpers.dll exports. Port complete — see SCRIPTING.md / EXTRACTION_PLAN.md.
; ===========================================================================
include snippets.asm

end _start
