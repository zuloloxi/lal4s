; ============================================================================
;  snippets.asm - lifted snippet engine + automation primitives for lal4s.
;
;  Extracted from cf22 color_iw.asm (2026-07-02). This is the self-contained
;  mini-interpreter (`run_script`) with its own stack (`script_stk`) + command
;  table (`script_cmds`), the `::`/`:::` snippet parser, the global hotkey
;  layer, and the WH_KEYBOARD_LL hotstring hook. NO Forth kernel is referenced.
;
;  Adaptations vs the cf22 originals:
;    * [hwndmain] -> [hwndmsg]         (lal4s uses a hidden message window)
;    * hook handle -> [hhook]          (declared in lal4s.asm)
;    * dbg_* logging calls removed     (no color_debug.log dependency)
;    * -kernel/-tray/-ctrace flag scan removed from parse_cmdline
;    * hook_proc trimmed: dropped the picker / consent (UIA) / dump triggers;
;      kept injected-key skip, terminal skip-list, and hotstring matching.
;
;  INCREMENT 1 command set (DLL-free, no Forth): wait paste enter tab type
;  send move click rclick dclick. Heavier primitives (pixel*/img*/web*/
;  expect_*/winwait/run/picker/tray) are NOT lifted yet; load_image_dll and
;  install_tray are stubs. Unknown script words are silently ignored by
;  run_script, so partial coverage degrades gracefully.
;
;  Included at the end of lal4s.asm (`include snippets.asm`).
; ============================================================================

; SEND_KEY <vk>, <flags> — fill the static INPUT struct and call SendInput.
; flags=0 -> key-down, flags=2 -> key-up (KEYEVENTF_KEYUP).
; Win32 stdcall preserves ebx/esi/edi/ebp; clobbers eax/ecx/edx.
SEND_KEY MACRO vk_code, flags
    mov   dword ptr [sni_input_buf+0], 1   ; INPUT_KEYBOARD
    mov   word  ptr [sni_input_buf+4], vk_code
    mov   word  ptr [sni_input_buf+6], 0
    mov   dword ptr [sni_input_buf+8], flags
    mov   dword ptr [sni_input_buf+12], 0
    mov   dword ptr [sni_input_buf+16], 0
    push  28
    push  offset sni_input_buf
    push  1
    call  SendInput
ENDM

; ============================================================================
;  DATA  — all writable state lives in .data so .text stays read-execute
;          (clean W^X; cf22 kept these in a writable .code section).
; ============================================================================
.data

; --- snippet source path ---
snippets_file           db  'snippets.txt', 0
cmdline_snippets_path   db  512 dup (0)
effective_snippets_path dd  offset snippets_file

; --- snippets.txt parse state ---
snippets_handle     dd  -1
snippets_buf        dd  0             ; allocated buffer holding file content
snippets_size       dd  0             ; bytes read
snippets_bytesread  dd  0
snippets_tbl        dd  0             ; record table: 16 bytes/record, max 256
snippets_cnt        dd  0             ; number of records

; hotkey_tbl[i] packs snippet i's registered hotkey:
;   high 16 bits = MOD_ALT(1)|CONTROL(2)|SHIFT(4)|WIN(8)
;   low  16 bits = VK code.  0 = no hotkey.
hotkey_tbl          dd  256 dup (0)

; is_script_tbl[i] = 1 if snippet i was declared with `:::` (script body),
; 0 for `::` (literal text pasted via clipboard).
is_script_tbl       dd  256 dup (0)

; script runtime scratch stack (separate from any interpreter state)
script_stk          dd  32 dup (0)
script_sp           dd  0

; expand_paste scratch
ep_rec              dd  0
ep_hmem             dd  0

; reusable INPUT struct (28 bytes on x86; covers KEYBD + MOUSE layouts)
sni_input_buf       db  28 dup (0)

; hotstring rolling buffer (LL hook)
hotstring_buf       db  64 dup (0)
hotstring_len       dd  0

; --- settings.txt (skip=<class> lines) ---
settings_file       db  'settings.txt', 0
settings_handle     dd  -1
settings_buf        dd  0
settings_size       dd  0
settings_bytesread  dd  0

; --- terminal skip-list: asciiz classes, single-NUL separated, double-NUL end
skip_class_buf      db  2048 dup (0)
skip_class_end      dd  offset skip_class_buf
fg_class_buf        db  128 dup (0)    ; GetClassNameA scratch (per keystroke)

default_skip_classes label byte
    db  'ConsoleWindowClass', 0
    db  'CASCADIA_HOSTING_WINDOW_CLASS', 0
    db  'Windows.UI.Core.CoreWindow', 0
    db  'PuTTY', 0
    db  'mintty', 0
    db  0                             ; double-NUL terminator

; --- script command name strings ---
sc_name_wait        db  'wait', 0
sc_name_paste       db  'paste', 0
sc_name_enter       db  'enter', 0
sc_name_tab         db  'tab', 0
sc_name_type        db  'type', 0
sc_name_send        db  'send', 0
sc_name_move        db  'move', 0
sc_name_click       db  'click', 0
sc_name_rclick      db  'rclick', 0
sc_name_dclick      db  'dclick', 0
sc_name_pixelcolor  db  'pixelcolor', 0
sc_name_pixelwait   db  'pixelwait', 0
sc_name_pix3eq      db  'pix3eq', 0
sc_name_imgfind     db  'imgfind', 0
sc_name_imgclick    db  'imgclick', 0
sc_name_imgwait     db  'imgwait', 0
sc_name_imgfindin   db  'imgfindin', 0
sc_name_imgclickin  db  'imgclickin', 0
sc_name_imgwaitin   db  'imgwaitin', 0
sc_name_imgfindc    db  'imgfindc', 0
sc_name_imgclickc   db  'imgclickc', 0
sc_name_imgwaitc    db  'imgwaitc', 0
sc_name_imgfindinc  db  'imgfindinc', 0
sc_name_imgclickinc db  'imgclickinc', 0
sc_name_imgwaitinc  db  'imgwaitinc', 0
sc_name_winact      db  'winactivate', 0
sc_name_winwait     db  'winwait', 0
sc_name_run         db  'run', 0
sc_name_tname         db  'tname', 0
sc_name_tpass         db  'tpass', 0
sc_name_tfail         db  'tfail', 0
sc_name_tsummary      db  'tsummary', 0
sc_name_expect_pixel  db  'expect_pixel', 0
sc_name_expect_img    db  'expect_img', 0
sc_name_expect_window db  'expect_window', 0
sc_name_expect_no_img    db  'expect_no_img', 0
sc_name_expect_no_window db  'expect_no_window', 0
sc_name_expect_no_img_in    db  'expect_no_img_in', 0
sc_name_expect_no_window_in db  'expect_no_window_in', 0
sc_name_findwin_substr      db  'findwin_substr', 0
sc_name_enumwins            db  'enumwins', 0
sc_name_enumwinsh           db  'enumwinsh', 0
sc_name_expect_ctrl_text        db  'expect_ctrl_text', 0
sc_name_expect_ctrl_text_in     db  'expect_ctrl_text_in', 0
sc_name_expect_no_ctrl_text_in  db  'expect_no_ctrl_text_in', 0
sc_name_expect_any_ctrl_text    db  'expect_any_ctrl_text', 0
sc_name_expect_any_ctrl_text_in db  'expect_any_ctrl_text_in', 0
sc_name_expect_statusbar        db  'expect_statusbar', 0
sc_name_expect_statusbar_in     db  'expect_statusbar_in', 0
sc_name_expect_no_statusbar_in  db  'expect_no_statusbar_in', 0
sc_name_winctrls                db  'winctrls', 0
sc_name_winctrls_in             db  'winctrls_in', 0
sc_name_expect_pixel_avg        db  'expect_pixel_avg', 0
sc_name_expect_pixel_any        db  'expect_pixel_any', 0
sc_name_expect_pix3eq           db  'expect_pix3eq', 0
sc_name_ocr_digit               db  'ocr_digit', 0
sc_name_mouselog                db  'mouselog', 0
sc_name_winshot                 db  'winshot', 0
sc_name_debug_box               db  'debug_box', 0
sc_name_winshotevery            db  'winshotevery', 0
sc_name_winshotstop             db  'winshotstop', 0
sc_name_winshotstopall          db  'winshotstopall', 0
sc_name_weburl                    db  'weburl', 0
sc_name_webeval                   db  'webeval', 0
sc_name_expect_dom                db  'expect_dom', 0
sc_name_expect_js                 db  'expect_js', 0
sc_name_expect_no_console_errors  db  'expect_no_console_errors', 0
sc_name_expect_no_net_failures    db  'expect_no_net_failures', 0
sc_name_webclear                  db  'webclear', 0
sc_name_webclose                  db  'webclose', 0
sc_name_webwatch                  db  'webwatch', 0
sc_name_weblog                    db  'weblog', 0
sc_name_winactivate_substr        db  'winactivate_substr', 0
sc_name_key                       db  'key', 0
sc_name_winclose                  db  'winclose', 0
sc_name_winmin                    db  'winmin', 0
sc_name_winmax                    db  'winmax', 0
sc_name_keydown                   db  'keydown', 0
sc_name_keyup                     db  'keyup', 0
sc_name_mousedown                 db  'mousedown', 0
sc_name_mouseup                   db  'mouseup', 0
sc_name_scroll                    db  'scroll', 0
sc_name_winmove                   db  'winmove', 0
sc_name_winsize                   db  'winsize', 0
sc_name_clipset                   db  'clipset', 0
sc_name_clipget                   db  'clipget', 0
sc_name_winhide                   db  'winhide', 0
sc_name_winshow                   db  'winshow', 0

; --- script_cmds: (name_ptr, name_len, handler) triples, NULL-terminated ---
script_cmds label dword
    dd  offset sc_name_wait,   4, offset sc_wait
    dd  offset sc_name_paste,  5, offset sc_paste
    dd  offset sc_name_enter,  5, offset sc_enter
    dd  offset sc_name_tab,    3, offset sc_tab
    dd  offset sc_name_type,   4, offset sc_type
    dd  offset sc_name_send,   4, offset sc_send
    dd  offset sc_name_move,   4, offset sc_move
    dd  offset sc_name_click,  5, offset sc_click
    dd  offset sc_name_rclick, 6, offset sc_rclick
    dd  offset sc_name_dclick, 6, offset sc_dclick
    dd  offset sc_name_pixelcolor,  10, offset sc_pixelcolor
    dd  offset sc_name_pixelwait,    9, offset sc_pixelwait
    dd  offset sc_name_pix3eq,       6, offset sc_pix3eq
    dd  offset sc_name_imgfind,      7, offset sc_imgfind
    dd  offset sc_name_imgclick,     8, offset sc_imgclick
    dd  offset sc_name_imgwait,      7, offset sc_imgwait
    dd  offset sc_name_imgfindin,    9, offset sc_imgfindin
    dd  offset sc_name_imgclickin,  10, offset sc_imgclickin
    dd  offset sc_name_imgwaitin,    9, offset sc_imgwaitin
    dd  offset sc_name_imgfindc,     8, offset sc_imgfindc
    dd  offset sc_name_imgclickc,    9, offset sc_imgclickc
    dd  offset sc_name_imgwaitc,     8, offset sc_imgwaitc
    dd  offset sc_name_imgfindinc,  10, offset sc_imgfindinc
    dd  offset sc_name_imgclickinc, 11, offset sc_imgclickinc
    dd  offset sc_name_imgwaitinc,  10, offset sc_imgwaitinc
    dd  offset sc_name_winact,      11, offset sc_winact
    dd  offset sc_name_winwait,      7, offset sc_winwait
    dd  offset sc_name_run,          3, offset sc_run
    dd  offset sc_name_tname,        5, offset sc_tname
    dd  offset sc_name_tpass,        5, offset sc_tpass
    dd  offset sc_name_tfail,        5, offset sc_tfail
    dd  offset sc_name_tsummary,     8, offset sc_tsummary
    dd  offset sc_name_expect_pixel,  12, offset sc_expect_pixel
    dd  offset sc_name_expect_img,    10, offset sc_expect_img
    dd  offset sc_name_expect_window, 13, offset sc_expect_window
    dd  offset sc_name_expect_no_img,    13, offset sc_expect_no_img
    dd  offset sc_name_expect_no_window, 16, offset sc_expect_no_window
    dd  offset sc_name_expect_no_img_in,    16, offset sc_expect_no_img_in
    dd  offset sc_name_expect_no_window_in, 19, offset sc_expect_no_window_in
    dd  offset sc_name_findwin_substr,      14, offset sc_findwin_substr
    dd  offset sc_name_enumwins,             8, offset sc_enumwins
    dd  offset sc_name_enumwinsh,            9, offset sc_enumwinsh
    dd  offset sc_name_expect_ctrl_text,        16, offset sc_expect_ctrl_text
    dd  offset sc_name_expect_ctrl_text_in,     19, offset sc_expect_ctrl_text_in
    dd  offset sc_name_expect_no_ctrl_text_in,  22, offset sc_expect_no_ctrl_text_in
    dd  offset sc_name_expect_any_ctrl_text,    20, offset sc_expect_any_ctrl_text
    dd  offset sc_name_expect_any_ctrl_text_in, 23, offset sc_expect_any_ctrl_text_in
    dd  offset sc_name_expect_statusbar,        16, offset sc_expect_statusbar
    dd  offset sc_name_expect_statusbar_in,     19, offset sc_expect_statusbar_in
    dd  offset sc_name_expect_no_statusbar_in,  22, offset sc_expect_no_statusbar_in
    dd  offset sc_name_winctrls,                 8, offset sc_winctrls
    dd  offset sc_name_winctrls_in,             11, offset sc_winctrls_in
    dd  offset sc_name_expect_pixel_avg, 16, offset sc_expect_pixel_avg
    dd  offset sc_name_expect_pixel_any, 16, offset sc_expect_pixel_any
    dd  offset sc_name_expect_pix3eq,    13, offset sc_expect_pix3eq
    dd  offset sc_name_ocr_digit,         9, offset sc_ocr_digit
    dd  offset sc_name_mouselog,          8, offset sc_mouselog
    dd  offset sc_name_winshot,           7, offset sc_winshot
    dd  offset sc_name_debug_box,         9, offset sc_debug_box
    dd  offset sc_name_winshotevery,     12, offset sc_winshotevery
    dd  offset sc_name_winshotstop,      11, offset sc_winshotstop
    dd  offset sc_name_winshotstopall,   14, offset sc_winshotstopall
    dd  offset sc_name_weburl,                    6, offset sc_weburl
    dd  offset sc_name_webeval,                   7, offset sc_webeval
    dd  offset sc_name_expect_dom,               10, offset sc_expect_dom
    dd  offset sc_name_expect_js,                 9, offset sc_expect_js
    dd  offset sc_name_expect_no_console_errors, 24, offset sc_expect_no_console_errors
    dd  offset sc_name_expect_no_net_failures,   22, offset sc_expect_no_net_failures
    dd  offset sc_name_webclear,                  8, offset sc_webclear
    dd  offset sc_name_webclose,                  8, offset sc_webclose
    dd  offset sc_name_webwatch,                  8, offset sc_webwatch
    dd  offset sc_name_weblog,                     6, offset sc_weblog
    dd  offset sc_name_winactivate_substr,        18, offset sc_winactivate_substr
    dd  offset sc_name_key,                        3, offset sc_key
    dd  offset sc_name_winclose,                   8, offset sc_winclose
    dd  offset sc_name_winmin,                     6, offset sc_winmin
    dd  offset sc_name_winmax,                     6, offset sc_winmax
    dd  offset sc_name_keydown,                    7, offset sc_keydown
    dd  offset sc_name_keyup,                       5, offset sc_keyup
    dd  offset sc_name_mousedown,                  9, offset sc_mousedown
    dd  offset sc_name_mouseup,                    7, offset sc_mouseup
    dd  offset sc_name_scroll,                     6, offset sc_scroll
    dd  offset sc_name_winmove,                    7, offset sc_winmove
    dd  offset sc_name_winsize,                    7, offset sc_winsize
    dd  offset sc_name_clipset,                    7, offset sc_clipset
    dd  offset sc_name_clipget,                    7, offset sc_clipget
    dd  offset sc_name_winhide,                    7, offset sc_winhide
    dd  offset sc_name_winshow,                    7, offset sc_winshow
    dd  0, 0, 0

; ============================================================================
;  CODE
; ============================================================================
.code

; ---------------------------------------------------------------------------
;  script stack helpers
; ---------------------------------------------------------------------------
; scr_push (eax = val) — push eax; clobbers eax/edx
scr_push:
    mov    edx, [script_sp]
    cmp    edx, 32
    jae    scr_pret                          ; overflow → drop silently
    mov    [script_stk + edx*4], eax
    inc    dword ptr [script_sp]
scr_pret:
    ret

; scr_pop (-- eax) — pop into eax; 0 on underflow
scr_pop:
    mov    edx, [script_sp]
    or     edx, edx
    jz     scr_pop_under
    dec    edx
    mov    [script_sp], edx
    mov    eax, [script_stk + edx*4]
    ret
scr_pop_under:
    xor    eax, eax
    ret

; ---------------------------------------------------------------------------
;  run_script (ecx = snippet idx) — tokenize + execute the snippet body.
;    "string" -> push (ptr,len);  number (dec / 0x-hex, optional '-') -> push;
;    identifier -> look up in script_cmds, call handler. '#' = line comment.
;    Unknown words / underflow are silently ignored.
; ---------------------------------------------------------------------------
run_script:
    cmp    ecx, [snippets_cnt]
    jae    rs_ret
    mov    eax, [snippets_tbl]
    shl    ecx, 4
    add    eax, ecx                         ; eax = record ptr
    mov    edi, [eax+8]                     ; edi = body cursor
    mov    esi, [eax+12]
    add    esi, edi                          ; esi = end-of-body (exclusive)
    mov    dword ptr [script_sp], 0
rs_loop:
    cmp    edi, esi
    jae    rs_ret
    mov    al, byte ptr [edi]
    cmp    al, 20h
    je     rs_skip
    cmp    al, 09h
    je     rs_skip
    cmp    al, 0Dh
    je     rs_skip
    cmp    al, 0Ah
    je     rs_skip
    cmp    al, '#'
    je     rs_comment
    cmp    al, '"'
    je     rs_string
    cmp    al, '0'
    jb     rs_ident
    cmp    al, '9'
    jbe    rs_number
    cmp    al, '-'
    je     rs_number
    jmp    rs_ident
rs_skip:
    inc    edi
    jmp    rs_loop
rs_comment:
    inc    edi
    cmp    edi, esi
    jae    rs_ret
    cmp    byte ptr [edi], 0Ah
    jne    rs_comment
    inc    edi
    jmp    rs_loop
rs_ret:
    ret

; --- string token: read until closing `"` ---
rs_string:
    inc    edi                              ; skip opening "
    mov    ebx, edi                         ; ebx = string start
rs_str_loop:
    cmp    edi, esi
    jae    rs_str_done
    cmp    byte ptr [edi], '"'
    je     rs_str_done
    inc    edi
    jmp    rs_str_loop
rs_str_done:
    mov    eax, ebx
    call   scr_push                         ; ptr
    mov    eax, edi
    sub    eax, ebx
    call   scr_push                         ; len (on top)
    cmp    edi, esi
    jae    rs_loop
    inc    edi
    jmp    rs_loop

; --- number token: decimal or 0x-hex, optional leading '-' ---
rs_number:
    xor    eax, eax                         ; accumulator
    xor    ecx, ecx                         ; sign flag (1 = negative)
    cmp    byte ptr [edi], '-'
    jne    rs_num_check_hex
    mov    ecx, 1
    inc    edi
rs_num_check_hex:
    cmp    edi, esi
    jae    rs_num_done
    cmp    byte ptr [edi], '0'
    jne    rs_num_loop
    mov    edx, edi
    inc    edx
    cmp    edx, esi
    jae    rs_num_loop
    cmp    byte ptr [edx], 'x'
    je     rs_num_skip_0x
    cmp    byte ptr [edx], 'X'
    je     rs_num_skip_0x
    jmp    rs_num_loop
rs_num_skip_0x:
    add    edi, 2
rs_num_hex_loop:
    cmp    edi, esi
    jae    rs_num_done
    mov    dl, byte ptr [edi]
    cmp    dl, '0'
    jb     rs_num_done
    cmp    dl, '9'
    ja     rs_num_hex_alpha
    sub    dl, '0'
    jmp    rs_num_hex_accum
rs_num_hex_alpha:
    cmp    dl, 'A'
    jb     rs_num_done
    cmp    dl, 'F'
    ja     rs_num_hex_lower
    sub    dl, 'A' - 10
    jmp    rs_num_hex_accum
rs_num_hex_lower:
    cmp    dl, 'a'
    jb     rs_num_done
    cmp    dl, 'f'
    ja     rs_num_done
    sub    dl, 'a' - 10
rs_num_hex_accum:
    shl    eax, 4
    movzx  edx, dl
    add    eax, edx
    inc    edi
    jmp    rs_num_hex_loop
rs_num_loop:
    cmp    edi, esi
    jae    rs_num_done
    mov    dl, byte ptr [edi]
    cmp    dl, '0'
    jb     rs_num_done
    cmp    dl, '9'
    ja     rs_num_done
    sub    dl, '0'
    mov    ebx, eax
    shl    eax, 1
    shl    ebx, 3                            ; ebx = old*8; eax = old*2
    add    eax, ebx                          ; eax = old*10
    movzx  edx, dl
    add    eax, edx
    inc    edi
    jmp    rs_num_loop
rs_num_done:
    or     ecx, ecx
    jz     @f
    neg    eax
@@: call   scr_push
    jmp    rs_loop

; --- identifier token: read until whitespace, look up in script_cmds ---
rs_ident:
    mov    ebx, edi                         ; ebx = name start
rs_id_loop:
    cmp    edi, esi
    jae    rs_id_done
    mov    al, byte ptr [edi]
    cmp    al, 20h
    je     rs_id_done
    cmp    al, 09h
    je     rs_id_done
    cmp    al, 0Dh
    je     rs_id_done
    cmp    al, 0Ah
    je     rs_id_done
    inc    edi
    jmp    rs_id_loop
rs_id_done:
    mov    eax, edi
    sub    eax, ebx                          ; eax = name_len
    push   edi                              ; save cursor
    push   esi
    mov    edx, offset script_cmds
rs_cmd_loop:
    mov    ecx, [edx+0]                      ; ptr to command name
    or     ecx, ecx
    jz     rs_cmd_notfound
    cmp    [edx+4], eax                      ; same length?
    jne    rs_cmd_next
    mov    esi, ecx                          ; cmd name
    mov    edi, ebx                          ; token start
    mov    ecx, eax                          ; length
    push   eax
    repe   cmpsb
    pop    eax
    jne    rs_cmd_next
    pop    esi
    pop    edi
    call   dword ptr [edx+8]
    jmp    rs_loop
rs_cmd_next:
    add    edx, 12
    jmp    rs_cmd_loop
rs_cmd_notfound:
    pop    esi
    pop    edi
    jmp    rs_loop                           ; silently ignore unknown

; ---------------------------------------------------------------------------
;  Phase 3A primitives (DLL-free)
; ---------------------------------------------------------------------------
; wait ( ms -- )
sc_wait:
    pushad
    call   scr_pop
    push   eax
    call   Sleep
    popad
    ret

; paste ( -- ) — release held mods then Ctrl+V
sc_paste:
    pushad
    SEND_KEY 5Bh, 2                          ; Left Win up
    SEND_KEY 5Ch, 2                          ; Right Win up
    SEND_KEY 12h, 2                          ; Alt up
    SEND_KEY 10h, 2                          ; Shift up
    SEND_KEY 11h, 2                          ; Ctrl up
    SEND_KEY 11h, 0                          ; Ctrl down
    SEND_KEY 56h, 0                          ; V down
    SEND_KEY 56h, 2                          ; V up
    SEND_KEY 11h, 2                          ; Ctrl up
    popad
    ret

; enter ( -- )
sc_enter:
    pushad
    SEND_KEY 0Dh, 0
    SEND_KEY 0Dh, 2
    popad
    ret

; tab ( -- )
sc_tab:
    pushad
    SEND_KEY 09h, 0
    SEND_KEY 09h, 2
    popad
    ret

; type ( str_ptr str_len -- ) — SendInput one Unicode char at a time
sc_type:
    pushad
    call   scr_pop                           ; eax = len
    mov    ecx, eax
    call   scr_pop                           ; eax = ptr
    mov    esi, eax
    or     ecx, ecx
    jz     sc_type_done
sc_type_loop:
    movzx  eax, byte ptr [esi]
    inc    esi
    push   ecx                               ; save loop counter
    mov    dword ptr [sni_input_buf+0],  1   ; INPUT_KEYBOARD
    mov    word  ptr [sni_input_buf+4],  0   ; wVk = 0 for Unicode
    mov    word  ptr [sni_input_buf+6],  ax  ; wScan = the char
    mov    dword ptr [sni_input_buf+8],  4   ; KEYEVENTF_UNICODE
    mov    dword ptr [sni_input_buf+12], 0
    mov    dword ptr [sni_input_buf+16], 0
    push   28
    push   offset sni_input_buf
    push   1
    call   SendInput
    mov    dword ptr [sni_input_buf+8],  6   ; UNICODE | KEYUP
    push   28
    push   offset sni_input_buf
    push   1
    call   SendInput
    pop    ecx
    dec    ecx
    jnz    sc_type_loop
sc_type_done:
    popad
    ret

; send ( str_ptr str_len -- ) — parse "ctrl+shift+p" etc via parse_hotkey,
;   then emit mods-down, vk down/up, mods-up (releasing held mods first).
sc_send:
    pushad
    call   scr_pop                           ; len
    mov    ecx, eax
    call   scr_pop                           ; ptr
    mov    edx, ecx
    add    ecx, eax                          ; ecx = end ptr
    call   parse_hotkey                      ; eax = (mods<<16)|vk or 0
    or     eax, eax
    jz     sc_send_done
    mov    ebx, eax
    movzx  edi, ax                           ; edi = vk
    shr    ebx, 16                           ; ebx = mods
    SEND_KEY 5Bh, 2                          ; Left Win up
    SEND_KEY 5Ch, 2                          ; Right Win up
    SEND_KEY 12h, 2                          ; Alt up
    SEND_KEY 10h, 2                          ; Shift up
    SEND_KEY 11h, 2                          ; Ctrl up
    test   bl, 2                             ; MOD_CONTROL
    jz     @f
    SEND_KEY 11h, 0
@@: test   bl, 4                             ; MOD_SHIFT
    jz     @f
    SEND_KEY 10h, 0
@@: test   bl, 1                             ; MOD_ALT
    jz     @f
    SEND_KEY 12h, 0
@@: test   bl, 8                             ; MOD_WIN
    jz     @f
    SEND_KEY 5Bh, 0
@@:
    mov    dword ptr [sni_input_buf+0], 1
    mov    word  ptr [sni_input_buf+4], di
    mov    word  ptr [sni_input_buf+6], 0
    mov    dword ptr [sni_input_buf+8], 0
    mov    dword ptr [sni_input_buf+12], 0
    mov    dword ptr [sni_input_buf+16], 0
    push   28
    push   offset sni_input_buf
    push   1
    call   SendInput
    mov    dword ptr [sni_input_buf+8], 2    ; KEYUP
    push   28
    push   offset sni_input_buf
    push   1
    call   SendInput
    test   bl, 8
    jz     @f
    SEND_KEY 5Bh, 2
@@: test   bl, 1
    jz     @f
    SEND_KEY 12h, 2
@@: test   bl, 4
    jz     @f
    SEND_KEY 10h, 2
@@: test   bl, 2
    jz     @f
    SEND_KEY 11h, 2
@@:
sc_send_done:
    popad
    ret

; move ( x y -- ) — SetCursorPos(x, y)
sc_move:
    pushad
    call   scr_pop                           ; y
    push   eax
    call   scr_pop                           ; x
    push   eax
    call   SetCursorPos
    popad
    ret

; click ( -- ) left button down + up
sc_click:
    pushad
    mov    dword ptr [sni_input_buf+0],  0   ; INPUT_MOUSE
    mov    dword ptr [sni_input_buf+4],  0
    mov    dword ptr [sni_input_buf+8],  0
    mov    dword ptr [sni_input_buf+12], 0
    mov    dword ptr [sni_input_buf+16], 2   ; MOUSEEVENTF_LEFTDOWN
    mov    dword ptr [sni_input_buf+20], 0
    mov    dword ptr [sni_input_buf+24], 0
    push   28
    push   offset sni_input_buf
    push   1
    call   SendInput
    mov    dword ptr [sni_input_buf+16], 4   ; MOUSEEVENTF_LEFTUP
    push   28
    push   offset sni_input_buf
    push   1
    call   SendInput
    popad
    ret

; rclick ( -- ) right button down + up
sc_rclick:
    pushad
    mov    dword ptr [sni_input_buf+0],  0
    mov    dword ptr [sni_input_buf+4],  0
    mov    dword ptr [sni_input_buf+8],  0
    mov    dword ptr [sni_input_buf+12], 0
    mov    dword ptr [sni_input_buf+16], 8   ; MOUSEEVENTF_RIGHTDOWN
    mov    dword ptr [sni_input_buf+20], 0
    mov    dword ptr [sni_input_buf+24], 0
    push   28
    push   offset sni_input_buf
    push   1
    call   SendInput
    mov    dword ptr [sni_input_buf+16], 10h ; MOUSEEVENTF_RIGHTUP
    push   28
    push   offset sni_input_buf
    push   1
    call   SendInput
    popad
    ret

; dclick ( -- ) two left clicks
sc_dclick:
    call   sc_click
    call   sc_click
    ret

; ---------------------------------------------------------------------------
;  expand_paste / expand_paste_no_bs (ecx = snippet index)
;    `:::` scripts route to run_script; `::` text goes to the clipboard + Ctrl+V.
;    _no_bs skips the backspace-erase (used by the WM_HOTKEY path, where the
;    user pressed a key combo rather than typing the short).
; ---------------------------------------------------------------------------
expand_paste_no_bs:
    cmp    ecx, [snippets_cnt]
    jae    ep_ret
    cmp    dword ptr [is_script_tbl + ecx*4], 0
    je     epnb_text
    jmp    run_script                       ; ecx already = snippet idx
epnb_text:
    mov    eax, [snippets_tbl]
    shl    ecx, 4
    add    eax, ecx
    mov    [ep_rec], eax
    jmp    ep_clip

expand_paste:
    cmp    ecx, [snippets_cnt]
    jae    ep_ret
    cmp    dword ptr [is_script_tbl + ecx*4], 0
    je     ep_text
    jmp    run_script
ep_text:
    mov    eax, [snippets_tbl]
    shl    ecx, 4
    add    eax, ecx                         ; eax = record ptr
    mov    [ep_rec], eax
    ; backspaces (count = short_len) to erase the typed short
    mov    ebx, [eax+4]
ep_bs:
    or     ebx, ebx
    jz     ep_clip
    SEND_KEY 8, 0                            ; VK_BACK down
    SEND_KEY 8, 2                            ; VK_BACK up
    dec    ebx
    jmp    ep_bs
ep_clip:
    push   0
    call   OpenClipboard
    or     eax, eax
    jz     ep_paste                          ; couldn't open; just try the paste
    call   EmptyClipboard
    mov    eax, [ep_rec]
    mov    ecx, [eax+12]                    ; body_len
    inc    ecx                              ; +1 for null
    push   ecx
    push   2                                ; GMEM_MOVEABLE
    call   GlobalAlloc
    or     eax, eax
    jz     ep_clip_close
    mov    [ep_hmem], eax
    push   eax
    call   GlobalLock
    or     eax, eax
    jz     ep_clip_close
    mov    edi, eax
    mov    esi, [ep_rec]
    mov    ecx, [esi+12]                    ; body_len
    mov    esi, [esi+8]                     ; body_ptr
    rep    movsb
    mov    byte ptr [edi], 0                ; null terminator
    push   [ep_hmem]
    call   GlobalUnlock
    push   [ep_hmem]
    push   1                                ; CF_TEXT
    call   SetClipboardData
    call   CloseClipboard
ep_paste:
    ; release any modifiers the trigger left held, then clean Ctrl+V
    SEND_KEY 5Bh, 2                          ; Left Win up
    SEND_KEY 5Ch, 2                          ; Right Win up
    SEND_KEY 12h, 2                          ; Alt up
    SEND_KEY 10h, 2                          ; Shift up
    SEND_KEY 11h, 2                          ; Ctrl up (in case held)
    SEND_KEY 11h, 0                          ; VK_CONTROL down
    SEND_KEY 56h, 0                          ; VK_V down
    SEND_KEY 56h, 2                          ; VK_V up
    SEND_KEY 11h, 2                          ; VK_CONTROL up
ep_ret:
    ret
ep_clip_close:
    call   CloseClipboard
    jmp    ep_ret

; ---------------------------------------------------------------------------
;  append_skip_class_n (eax = ptr, ecx = len) — append a class name to the
;  skip-list, single-NUL separated, keeping room for the double-NUL end.
; ---------------------------------------------------------------------------
append_skip_class_n:
    pushad
    test   ecx, ecx
    jz     ascn_done
    mov    esi, eax
    mov    edi, [skip_class_end]
    mov    edx, offset skip_class_buf
    add    edx, 2046                      ; reserve 2 bytes for double-NUL end
ascn_copy:
    cmp    edi, edx
    jae    ascn_finish
    test   ecx, ecx
    jz     ascn_finish
    mov    al, [esi]
    test   al, al
    jz     ascn_finish                    ; embedded NUL — stop early
    mov    [edi], al
    inc    esi
    inc    edi
    dec    ecx
    jmp    ascn_copy
ascn_finish:
    mov    byte ptr [edi], 0
    inc    edi
    mov    [skip_class_end], edi
ascn_done:
    popad
    ret

; load_default_skip_classes — copy compiled-in defaults into skip_class_buf
load_default_skip_classes:
    pushad
    mov    ebx, offset default_skip_classes
ldsc_next:
    cmp    byte ptr [ebx], 0
    je     ldsc_done
    mov    esi, ebx
ldsc_strlen:
    cmp    byte ptr [esi], 0
    je     ldsc_strlen_end
    inc    esi
    jmp    ldsc_strlen
ldsc_strlen_end:
    mov    ecx, esi
    sub    ecx, ebx
    mov    eax, ebx
    call   append_skip_class_n
    mov    ebx, esi
    inc    ebx                             ; past the NUL
    jmp    ldsc_next
ldsc_done:
    popad
    ret

; ---------------------------------------------------------------------------
;  load_settings_txt — read settings.txt, append each `skip=<class>` value.
; ---------------------------------------------------------------------------
load_settings_txt:
    pushad
    push   0
    push   80h
    push   3                              ; OPEN_EXISTING
    push   0
    push   1                              ; FILE_SHARE_READ
    push   80000000h                      ; GENERIC_READ
    push   offset settings_file
    call   CreateFileA
    cmp    eax, -1
    je     lst_done
    mov    [settings_handle], eax
    push   0
    push   eax
    call   GetFileSize
    test   eax, eax
    jz     lst_close
    cmp    eax, 32768
    ja     lst_close
    mov    [settings_size], eax
    push   4                              ; PAGE_READWRITE
    push   1000h                          ; MEM_COMMIT
    push   eax
    push   0
    call   VirtualAlloc
    or     eax, eax
    jz     lst_close
    mov    [settings_buf], eax
    push   0
    push   offset settings_bytesread
    push   [settings_size]
    push   [settings_buf]
    push   [settings_handle]
    call   ReadFile
    push   [settings_handle]
    call   CloseHandle
    mov    esi, [settings_buf]            ; cursor
    mov    edi, esi
    add    edi, [settings_size]           ; end
lst_line:
    cmp    esi, edi
    jae    lst_done
    mov    eax, esi                        ; line start
lst_seek_lf:
    cmp    esi, edi
    jae    lst_have_line
    cmp    byte ptr [esi], 0Ah
    je     lst_have_line
    inc    esi
    jmp    lst_seek_lf
lst_have_line:
    mov    ebx, esi                        ; ebx = line end (exclusive)
    cmp    ebx, eax
    je     lst_after
    cmp    byte ptr [ebx-1], 0Dh
    jne    @f
    dec    ebx
@@:
    cmp    ebx, eax
    je     lst_after
    cmp    byte ptr [eax], '#'
    je     lst_after
    mov    edx, ebx
    sub    edx, eax
    cmp    edx, 6
    jl     lst_after
    cmp    dword ptr [eax], 'piks'         ; 's','k','i','p'
    jne    lst_after
    cmp    byte ptr [eax+4], '='
    jne    lst_after
    push   eax
    push   ebx
    lea    edx, [eax+5]
    mov    ecx, ebx
    sub    ecx, edx                       ; ecx = length
    mov    eax, edx
    call   append_skip_class_n
    pop    ebx
    pop    eax
lst_after:
    cmp    esi, edi
    jae    lst_done
    inc    esi                             ; skip LF
    jmp    lst_line
lst_close:
    push   [settings_handle]
    call   CloseHandle
lst_done:
    popad
    ret

; ---------------------------------------------------------------------------
;  parse_snippets_txt — open the effective snippets file, build the record
;    table (16 bytes/record: short_ptr, short_len, body_ptr, body_len), the
;    hotkey table, the is_script flags, and any ::skip directives.
;    Missing file -> zero records. (dbg logging from cf22 removed.)
; ---------------------------------------------------------------------------
parse_snippets_txt:
    pushad
    push   0
    push   80h                  ; FILE_ATTRIBUTE_NORMAL
    push   3                    ; OPEN_EXISTING
    push   0
    push   1                    ; FILE_SHARE_READ
    push   80000000h            ; GENERIC_READ
    push   [effective_snippets_path]
    call   CreateFileA
    cmp    eax, -1
    je     ps_done
    mov    [snippets_handle], eax
    push   0
    push   eax
    call   GetFileSize
    or     eax, eax
    jz     ps_close
    mov    [snippets_size], eax
    mov    ecx, eax
    push   4                    ; PAGE_READWRITE
    push   1000h                ; MEM_COMMIT
    push   ecx
    push   0
    call   VirtualAlloc
    or     eax, eax
    jz     ps_close
    mov    [snippets_buf], eax
    push   0
    push   offset snippets_bytesread
    push   [snippets_size]
    push   [snippets_buf]
    push   [snippets_handle]
    call   ReadFile
    push   [snippets_handle]
    call   CloseHandle
    ; allocate record table: 256 * 16 bytes = 4 KB
    push   4
    push   1000h
    push   1000h
    push   0
    call   VirtualAlloc
    or     eax, eax
    jz     ps_done
    mov    [snippets_tbl], eax
    mov    esi, [snippets_buf]            ; cursor
    mov    edi, esi
    add    edi, [snippets_size]           ; end-of-buffer
    xor    ebx, ebx                        ; current record pointer
ps_line:
    cmp    esi, edi
    jae    ps_eof
    mov    eax, esi                        ; eax = line start
ps_seek_lf:
    cmp    esi, edi
    jae    ps_have_line
    cmp    byte ptr [esi], 0Ah
    je     ps_have_line
    inc    esi
    jmp    ps_seek_lf
ps_have_line:
    mov    ecx, esi                        ; ecx = line_end (exclusive)
    cmp    ecx, eax
    je     ps_after                        ; empty line
    mov    dl, byte ptr [ecx-1]
    cmp    dl, 0Dh
    jne    @f
    dec    ecx
@@:
    cmp    ecx, eax
    je     ps_after
    cmp    byte ptr [eax], '#'
    je     ps_after
    mov    edx, ecx
    sub    edx, eax
    cmp    edx, 2
    jl     ps_after
    cmp    word ptr [eax], 03A3Ah          ; "::"
    jne    ps_after
    ; --- ::skip <classname> directive ---
    cmp    edx, 7
    jl     ps_not_skip
    cmp    dword ptr [eax+2], 'piks'        ; 's','k','i','p'
    jne    ps_not_skip
    cmp    byte ptr [eax+6], 20h
    je     ps_skip_have_ws
    cmp    byte ptr [eax+6], 09h
    je     ps_skip_have_ws
    jmp    ps_not_skip
ps_skip_have_ws:
    lea    edx, [eax+6]
ps_skip_ws_loop:
    cmp    edx, ecx
    jae    ps_after
    cmp    byte ptr [edx], 20h
    je     ps_skip_ws_inc
    cmp    byte ptr [edx], 09h
    je     ps_skip_ws_inc
    jmp    ps_skip_have_value
ps_skip_ws_inc:
    inc    edx
    jmp    ps_skip_ws_loop
ps_skip_have_value:
    push   eax
    push   ecx
    push   edx
    mov    eax, ecx
    sub    eax, edx
    mov    ecx, eax
    pop    eax                             ; eax = value start
    call   append_skip_class_n
    pop    ecx
    pop    eax
    jmp    ps_after
ps_not_skip:
    ; detect ":::" script marker
    mov    dword ptr [ps_script_pending], 0
    cmp    edx, 3
    jl     @f
    cmp    byte ptr [eax+2], ':'
    jne    @f
    mov    dword ptr [ps_script_pending], 1
@@:
    ; close previous record's body (trim trailing whitespace)
    or     ebx, ebx
    jz     @f
    mov    edx, eax                        ; edx = past-end (exclusive)
ps_trim:
    cmp    edx, [ebx+8]
    jbe    ps_trim_done
    cmp    byte ptr [edx-1], 20h
    je     ps_trim_dec
    cmp    byte ptr [edx-1], 09h
    je     ps_trim_dec
    cmp    byte ptr [edx-1], 0Dh
    je     ps_trim_dec
    cmp    byte ptr [edx-1], 0Ah
    je     ps_trim_dec
    jmp    ps_trim_done
ps_trim_dec:
    dec    edx
    jmp    ps_trim
ps_trim_done:
    sub    edx, [ebx+8]
    mov    [ebx+12], edx
@@:
    add    eax, 2                          ; skip "::"
    cmp    dword ptr [ps_script_pending], 0
    je     ps_skip_ws
    inc    eax                             ; skip the 3rd ':' for ":::"
ps_skip_ws:
    cmp    eax, ecx
    jae    ps_short_ready
    cmp    byte ptr [eax], 20h
    je     ps_ws_inc
    cmp    byte ptr [eax], 09h
    je     ps_ws_inc
    jmp    ps_short_ready
ps_ws_inc:
    inc    eax
    jmp    ps_skip_ws
ps_short_ready:
    ; scan for `!` separating short from optional hotkey spec
    push   eax                             ; save short_start
    mov    edx, eax
ps_find_bang:
    cmp    edx, ecx
    jae    ps_no_hotkey
    cmp    byte ptr [edx], '!'
    je     ps_have_bang
    inc    edx
    jmp    ps_find_bang
ps_have_bang:
    push   ecx                             ; save line_end
    mov    ecx, edx
ps_trim_short_end:
    cmp    ecx, eax
    jbe    @f
    mov    bl, byte ptr [ecx-1]
    cmp    bl, 20h
    je     ps_short_dec
    cmp    bl, 09h
    je     ps_short_dec
    jmp    @f
ps_short_dec:
    dec    ecx
    jmp    ps_trim_short_end
@@:
    pop    ebx                             ; ebx = line_end
    inc    edx                             ; skip '!'
ps_hk_skip_ws:
    cmp    edx, ebx
    jae    ps_call_hk
    cmp    byte ptr [edx], 20h
    je     ps_hk_ws_inc
    cmp    byte ptr [edx], 09h
    je     ps_hk_ws_inc
    jmp    ps_call_hk
ps_hk_ws_inc:
    inc    edx
    jmp    ps_hk_skip_ws
ps_call_hk:
    push   ecx                             ; save short_end
    mov    eax, edx                        ; hk_start
    mov    ecx, ebx                        ; hk_end (line_end)
    call   parse_hotkey                    ; -> eax = packed, 0 = invalid
    pop    ecx                             ; restore short_end
    or     eax, eax
    jz     ps_no_hotkey
    mov    edx, [snippets_cnt]
    mov    [hotkey_tbl + edx*4], eax
ps_no_hotkey:
    pop    eax                             ; restore short_start
    ; allocate next slot in record table
    mov    edx, [snippets_cnt]
    cmp    edx, 256
    jae    ps_after
    mov    ebx, [snippets_tbl]
    shl    edx, 4
    add    ebx, edx
    mov    [ebx+0], eax                    ; short_ptr
    mov    edx, ecx
    sub    edx, eax
    mov    [ebx+4], edx                    ; short_len
    mov    edx, esi                        ; body starts after LF
    cmp    edx, edi
    jae    @f
    inc    edx
@@:
    mov    [ebx+8], edx                    ; body_ptr
    mov    dword ptr [ebx+12], 0           ; body_len (set later)
    mov    edx, [snippets_cnt]
    mov    eax, [ps_script_pending]
    mov    [is_script_tbl + edx*4], eax
    mov    dword ptr [ps_script_pending], 0
    inc    dword ptr [snippets_cnt]
ps_after:
    cmp    esi, edi
    jae    ps_eof
    inc    esi                             ; skip LF
    jmp    ps_line
ps_eof:
    ; close final record (body extends to EOF)
    or     ebx, ebx
    jz     ps_done
    mov    edx, esi
ps_eof_trim:
    cmp    edx, [ebx+8]
    jbe    ps_eof_trim_done
    cmp    byte ptr [edx-1], 20h
    je     ps_eof_trim_dec
    cmp    byte ptr [edx-1], 09h
    je     ps_eof_trim_dec
    cmp    byte ptr [edx-1], 0Dh
    je     ps_eof_trim_dec
    cmp    byte ptr [edx-1], 0Ah
    je     ps_eof_trim_dec
    jmp    ps_eof_trim_done
ps_eof_trim_dec:
    dec    edx
    jmp    ps_eof_trim
ps_eof_trim_done:
    sub    edx, [ebx+8]
    mov    [ebx+12], edx
    jmp    ps_done
ps_close:
    push   [snippets_handle]
    call   CloseHandle
ps_done:
    popad
    ret

; scratch for parse_snippets_txt (in .code is fine — but keep writable in .data)
.data
ps_script_pending  dd  0
.code

; ---------------------------------------------------------------------------
;  parse_cmdline — if launched with an argument, use it as the snippets-file
;    path (overriding the default snippets.txt). cf22's -kernel/-tray/-ctrace
;    flag scanning and dbg logging are dropped.
; ---------------------------------------------------------------------------
parse_cmdline:
    pushad
    call   GetCommandLineA
    or     eax, eax
    jz     pcl_done
    mov    esi, eax
    ; --- skip program name (quoted or not) ---
    cmp    byte ptr [esi], '"'
    jne    pcl_skip_unquoted
    inc    esi
pcl_skip_quoted:
    mov    al, [esi]
    test   al, al
    jz     pcl_done
    cmp    al, '"'
    je     pcl_past_quote
    inc    esi
    jmp    pcl_skip_quoted
pcl_past_quote:
    inc    esi
    jmp    pcl_skip_ws
pcl_skip_unquoted:
    mov    al, [esi]
    test   al, al
    jz     pcl_done
    cmp    al, 20h
    je     pcl_skip_ws
    cmp    al, 09h
    je     pcl_skip_ws
    inc    esi
    jmp    pcl_skip_unquoted
pcl_skip_ws:
    mov    al, [esi]
    test   al, al
    jz     pcl_done
    cmp    al, 20h
    je     pcl_ws_inc
    cmp    al, 09h
    je     pcl_ws_inc
    jmp    pcl_have_arg
pcl_ws_inc:
    inc    esi
    jmp    pcl_skip_ws
pcl_have_arg:
    cmp    byte ptr [esi], '"'
    jne    @f
    inc    esi
@@:
    mov    edi, offset cmdline_snippets_path
    mov    ecx, 511
pcl_copy:
    test   ecx, ecx
    jz     pcl_copy_done
    mov    al, [esi]
    test   al, al
    jz     pcl_copy_done
    cmp    al, '"'
    je     pcl_copy_done
    cmp    al, 0Dh
    je     pcl_copy_done
    cmp    al, 0Ah
    je     pcl_copy_done
    mov    [edi], al
    inc    esi
    inc    edi
    dec    ecx
    jmp    pcl_copy
pcl_copy_done:
pcl_trim:
    cmp    edi, offset cmdline_snippets_path
    jbe    pcl_trim_done
    mov    al, [edi-1]
    cmp    al, 20h
    je     pcl_trim_dec
    cmp    al, 09h
    je     pcl_trim_dec
    jmp    pcl_trim_done
pcl_trim_dec:
    dec    edi
    jmp    pcl_trim
pcl_trim_done:
    mov    byte ptr [edi], 0
    cmp    edi, offset cmdline_snippets_path
    jbe    pcl_done
    mov    dword ptr [effective_snippets_path], offset cmdline_snippets_path
pcl_done:
    popad
    ret

; ---------------------------------------------------------------------------
;  parse_hotkey (eax = start, ecx = end) — parse "ctrl+shift+p" / "f5" etc.
;    Returns eax = (mods<<16)|vk, or 0 if invalid / no modifier.
; ---------------------------------------------------------------------------
parse_hotkey:
phk_rtrim:
    cmp    ecx, eax
    jbe    phk_bad
    mov    dl, byte ptr [ecx-1]
    cmp    dl, 20h
    je     phk_rtrim_dec
    cmp    dl, 09h
    je     phk_rtrim_dec
    jmp    phk_rtrim_done
phk_rtrim_dec:
    dec    ecx
    jmp    phk_rtrim
phk_rtrim_done:
    xor    ebx, ebx                          ; ebx = mods accumulator
phk_next:
    cmp    eax, ecx
    jae    phk_bad
    mov    dl, byte ptr [eax]
    cmp    dl, 'A'
    jb     phk_disp
    cmp    dl, 'Z'
    ja     phk_disp
    add    dl, 20h
phk_disp:
    cmp    dl, 'c'
    je     phk_try_ctrl
    cmp    dl, 's'
    je     phk_try_shift
    cmp    dl, 'a'
    je     phk_try_alt
    cmp    dl, 'w'
    je     phk_try_win
    jmp    phk_final_vk
phk_try_ctrl:
    mov    edx, ecx
    sub    edx, eax
    cmp    edx, 5
    jb     phk_final_vk
    cmp    word ptr [eax+1], 7274h            ; 'tr'
    je     @f
    cmp    word ptr [eax+1], 5452h            ; 'TR'
    jne    phk_chk_mixed_ctrl
@@: mov    dl, byte ptr [eax+3]
    or     dl, 20h
    cmp    dl, 'l'
    jne    phk_chk_mixed_ctrl
    cmp    byte ptr [eax+4], '+'
    jne    phk_final_vk
    or     ebx, 0002h                         ; MOD_CONTROL
    add    eax, 5
    jmp    phk_next
phk_chk_mixed_ctrl:
    mov    edx, dword ptr [eax]
    or     edx, 20202020h
    cmp    edx, 6c727463h                     ; 'ctrl'
    jne    phk_final_vk
    cmp    byte ptr [eax+4], '+'
    jne    phk_final_vk
    or     ebx, 0002h
    add    eax, 5
    jmp    phk_next
phk_try_shift:
    mov    edx, ecx
    sub    edx, eax
    cmp    edx, 6
    jb     phk_final_vk
    mov    edx, dword ptr [eax]
    or     edx, 20202020h
    cmp    edx, 66696873h                     ; 'shif'
    jne    phk_final_vk
    mov    dl, byte ptr [eax+4]
    or     dl, 20h
    cmp    dl, 't'
    jne    phk_final_vk
    cmp    byte ptr [eax+5], '+'
    jne    phk_final_vk
    or     ebx, 0004h                         ; MOD_SHIFT
    add    eax, 6
    jmp    phk_next
phk_try_alt:
    mov    edx, ecx
    sub    edx, eax
    cmp    edx, 4
    jb     phk_final_vk
    mov    edx, dword ptr [eax]
    or     edx, 20202020h
    cmp    edx, 2b746c61h                     ; 'alt+'
    jne    phk_final_vk
    or     ebx, 0001h                         ; MOD_ALT
    add    eax, 4
    jmp    phk_next
phk_try_win:
    mov    edx, ecx
    sub    edx, eax
    cmp    edx, 4
    jb     phk_final_vk
    mov    edx, dword ptr [eax]
    or     edx, 20202020h
    cmp    edx, 2b6e6977h                     ; 'win+'
    jne    phk_final_vk
    or     ebx, 0008h                         ; MOD_WIN
    add    eax, 4
    jmp    phk_next
phk_final_vk:
    mov    edx, ecx
    sub    edx, eax                       ; edx = remaining length
    cmp    edx, 1
    je     phk_one_char
    cmp    edx, 2
    je     phk_try_fkey
    cmp    edx, 3
    je     phk_try_fkey
    jmp    phk_bad
phk_one_char:
    mov    dl, byte ptr [eax]
    cmp    dl, '0'
    jb     phk_bad
    cmp    dl, '9'
    jbe    phk_pack
    cmp    dl, 'A'
    jb     phk_bad
    cmp    dl, 'Z'
    jbe    phk_pack
    cmp    dl, 'a'
    jb     phk_bad
    cmp    dl, 'z'
    ja     phk_bad
    sub    dl, 20h
    jmp    phk_pack
phk_try_fkey:
    cmp    byte ptr [eax], 'F'
    je     phk_fkey_have_f
    cmp    byte ptr [eax], 'f'
    jne    phk_bad
phk_fkey_have_f:
    cmp    edx, 2
    je     phk_fkey_1d
    cmp    byte ptr [eax+1], '1'
    jne    phk_bad
    mov    dl, byte ptr [eax+2]
    cmp    dl, '0'
    jb     phk_bad
    cmp    dl, '2'
    ja     phk_bad
    sub    dl, '0'
    add    dl, 79h                       ; VK_F10 = 0x79
    jmp    phk_pack
phk_fkey_1d:
    mov    dl, byte ptr [eax+1]
    cmp    dl, '1'
    jb     phk_bad
    cmp    dl, '9'
    ja     phk_bad
    sub    dl, '0'
    add    dl, 6Fh                       ; VK_F1 = 0x70
    jmp    phk_pack
phk_pack:
    movzx  eax, dl
    shl    ebx, 16
    or     eax, ebx
    test   eax, 000F0000h                ; refuse if no modifier
    jz     phk_bad
    ret
phk_bad:
    xor    eax, eax
    ret

; ---------------------------------------------------------------------------
;  register_hotkeys / unregister_hotkeys — snippet index doubles as the
;    WM_HOTKEY id, so wParam in WM_HOTKEY equals the index for expand_paste.
;    Retargeted to [hwndmsg] (lal4s hidden window). dbg logging dropped.
; ---------------------------------------------------------------------------
register_hotkeys:
    pushad
    xor    ebx, ebx                           ; ebx = snippet index
rh_loop:
    cmp    ebx, [snippets_cnt]
    jae    rh_done
    mov    eax, dword ptr [hotkey_tbl + ebx*4]
    or     eax, eax
    jz     rh_next
    mov    [rh_packed], eax                   ; save packed mods|vk for the log
    movzx  edx, ax                            ; edx = vk
    shr    eax, 16                            ; eax = mods
    push   edx                                ; vk
    push   eax                                ; mods
    push   ebx                                ; id = snippet index
    push   [hwndmsg]
    call   RegisterHotKey                     ; eax = 1 ok, 0 fail (conflict)
    ; --- log "hotkey id=NN packed=XXXX RegisterHotKey=R" ---
    push   eax                                ; preserve ret across the log
    mov    edx, offset dbg_msg_rh_pre
    call   dbg_writez
    mov    eax, ebx
    call   dbg_writehex8
    mov    edx, offset dbg_msg_rh_pk
    call   dbg_writez
    mov    eax, [rh_packed]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_rh_ret
    call   dbg_writez
    pop    eax                                ; RegisterHotKey return
    call   dbg_writehex8
    call   dbg_writecrlf
rh_next:
    inc    ebx
    jmp    rh_loop
rh_done:
    popad
    ret

unregister_hotkeys:
    pushad
    xor    ebx, ebx
urh_loop:
    cmp    ebx, [snippets_cnt]
    jae    urh_done
    cmp    dword ptr [hotkey_tbl + ebx*4], 0
    je     urh_next
    push   ebx
    push   [hwndmsg]
    call   UnregisterHotKey
urh_next:
    inc    ebx
    jmp    urh_loop
urh_done:
    popad
    ret

; ---------------------------------------------------------------------------
;  hotstring helpers + LL keyboard hook
; ---------------------------------------------------------------------------
; hs_append (eax = char) — append low byte to hotstring_buf (sliding window)
hs_append:
    mov    ebx, [hotstring_len]
    cmp    ebx, 63
    jae    hs_a_reset
    mov    byte ptr [hotstring_buf + ebx], al
    inc    ebx
    mov    [hotstring_len], ebx
    ret
hs_a_reset:
    mov    dword ptr [hotstring_len], 0
    ret

; hs_match_and_paste — first snippet short matching the END of hotstring_buf
;   wins; invoke expand_paste(index).
hs_match_and_paste:
    xor    edx, edx                          ; record index
hs_m_loop:
    cmp    edx, [snippets_cnt]
    jae    hs_m_done
    mov    eax, [snippets_tbl]
    mov    ebx, edx
    shl    ebx, 4
    add    eax, ebx                          ; eax = record ptr
    mov    ebx, [eax+4]                      ; short_len
    mov    ecx, [hotstring_len]
    cmp    ecx, ebx
    jb     hs_m_next                         ; hotstring shorter than this short
    sub    ecx, ebx                          ; ecx = start offset in buf
    lea    esi, [hotstring_buf + ecx]
    mov    edi, [eax+0]                      ; short_ptr
    mov    ecx, ebx                          ; count
    push   edx
    repe   cmpsb
    pop    edx
    jne    hs_m_next
    mov    ecx, edx
    call   expand_paste
    ret                                       ; first match wins
hs_m_next:
    inc    edx
    jmp    hs_m_loop
hs_m_done:
    ret

; ---------------------------------------------------------------------------
;  hook_proc — WH_KEYBOARD_LL callback. Trimmed vs cf22: no picker / consent /
;    UIA-dump triggers, no dbg logging. Skips injected keys, honors the
;    terminal skip-list, and feeds the hotstring matcher.
; ---------------------------------------------------------------------------
hook_proc proc nCode :DWORD, wParam :DWORD, lParam :DWORD
    pushad                                    ; Win32 stdcall callee-save
    mov    eax, nCode
    test   eax, eax
    js     hp_pass                            ; nCode < 0 → pass through
    ; skip our own synthetic (injected) keys
    mov    ebx, lParam
    test   dword ptr [ebx+8], 10h             ; KBDLLHOOKSTRUCT.flags & LLKHF_INJECTED
    jnz    hp_pass
    ; --- picker triggers (checked BEFORE the skip-list so CapsLock/Esc/Enter
    ;     work in any foreground app, including terminals) ---
    mov    eax, wParam
    cmp    eax, 100h                          ; WM_KEYDOWN
    je     hp_pick
    cmp    eax, 104h                          ; WM_SYSKEYDOWN
    jne    hp_skip_list_check
hp_pick:
    mov    ebx, lParam
    mov    eax, [ebx+0]                       ; vkCode
    cmp    eax, 14h                           ; VK_CAPITAL → open picker
    jne    hp_chk_space
    cmp    dword ptr [picker_visible], 0
    jne    hp_swallow                         ; already open — eat the repeat
    call   GetForegroundWindow
    mov    [picker_target], eax
    mov    dword ptr [picker_mode], 0
    push   0
    push   0
    push   WM_SHOW_PICKER
    push   [hwndmsg]
    call   PostMessageA
    jmp    hp_swallow                         ; swallow so CapsLock doesn't toggle
hp_chk_space:
    cmp    eax, 20h                           ; VK_SPACE — Ctrl+Shift+Space → tabnav
    jne    hp_chk_ctrlaltr
    cmp    dword ptr [picker_visible], 0
    jne    hp_chk_esc                         ; picker already open → Space filters
    push   11h                                ; require Ctrl held
    call   GetAsyncKeyState
    test   ax, 8000h
    jz     hp_chk_esc
    push   10h                                ; require Shift held
    call   GetAsyncKeyState
    test   ax, 8000h
    jz     hp_chk_esc
    call   GetForegroundWindow
    mov    [picker_target], eax
    mov    dword ptr [picker_mode], 1         ; tabnav (browser tabs) mode
    push   0
    push   0
    push   WM_SHOW_PICKER
    push   [hwndmsg]
    call   PostMessageA
    jmp    hp_swallow
hp_chk_ctrlaltr:
    cmp    eax, 52h                           ; VK_R — Ctrl+Alt+R → ConsentRejectAll
    jne    hp_chk_esc
    cmp    dword ptr [consent_reject_fn], 0
    je     hp_chk_esc                         ; DLL export missing
    push   11h                                ; require Ctrl
    call   GetAsyncKeyState
    test   ax, 8000h
    jz     hp_chk_esc
    push   12h                                ; require Alt (VK_MENU)
    call   GetAsyncKeyState
    test   ax, 8000h
    jz     hp_chk_esc
    push   10h                                ; Shift must NOT be held
    call   GetAsyncKeyState
    test   ax, 8000h
    jnz    hp_chk_esc
    cmp    dword ptr [consent_busy], 0        ; debounce: a run already in flight
    jne    hp_swallow
    mov    dword ptr [consent_busy], 1
    call   GetForegroundWindow
    push   0
    push   eax                                ; wParam = target hwnd
    push   WM_CONSENT_REJECT
    push   [hwndmsg]
    call   PostMessageA
    jmp    hp_swallow
hp_chk_esc:
    cmp    eax, 1Bh                           ; VK_ESCAPE
    jne    hp_chk_enter
    cmp    dword ptr [picker_visible], 0
    je     hp_skip_list_check                 ; not open — let Esc through
    push   0
    push   0
    push   WM_CLOSE_PICKER
    push   [picker_hwnd]
    call   PostMessageA
    jmp    hp_swallow
hp_chk_enter:
    cmp    eax, 0Dh                           ; VK_RETURN
    jne    hp_skip_list_check
    cmp    dword ptr [picker_visible], 0
    je     hp_skip_list_check                 ; not open — normal Enter
    push   10h                                ; Shift held → Part2, else Part1
    call   GetAsyncKeyState
    test   ax, 8000h
    jz     hp_ins_p1
    push   0
    push   0
    push   WM_PICKER_INS_P2
    push   [picker_hwnd]
    call   PostMessageA
    jmp    hp_swallow
hp_ins_p1:
    push   0
    push   0
    push   WM_PICKER_INS_P1
    push   [picker_hwnd]
    call   PostMessageA
    jmp    hp_swallow
hp_skip_list_check:
    ; skip-list: pass through if foreground window class is listed
    call   GetForegroundWindow
    test   eax, eax
    jz     hp_skip_done
    push   128
    push   offset fg_class_buf
    push   eax
    call   GetClassNameA
    test   eax, eax
    jz     hp_skip_done
    mov    esi, offset skip_class_buf
hp_skip_loop:
    cmp    byte ptr [esi], 0
    je     hp_skip_done                      ; end of list
    mov    edi, offset fg_class_buf
hp_skip_cmp:
    mov    al, [esi]
    cmp    al, [edi]
    jne    hp_skip_next
    test   al, al
    jz     hp_pass                           ; both NUL → class matched → pass
    inc    esi
    inc    edi
    jmp    hp_skip_cmp
hp_skip_next:
hp_skip_adv:
    cmp    byte ptr [esi], 0
    je     hp_skip_at_nul
    inc    esi
    jmp    hp_skip_adv
hp_skip_at_nul:
    inc    esi
    jmp    hp_skip_loop
hp_skip_done:
    mov    eax, wParam
    cmp    eax, 100h                          ; WM_KEYDOWN
    je     hp_keydown
    cmp    eax, 104h                          ; WM_SYSKEYDOWN
    je     hp_keydown
    jmp    hp_pass
hp_keydown:
    mov    ebx, lParam
    mov    eax, [ebx+0]                       ; vkCode
    cmp    eax, 41h                           ; 'A'
    jb     hp_check_digit
    cmp    eax, 5Ah                           ; 'Z'
    ja     hp_check_digit
    add    eax, 20h                           ; → 'a'..'z'
    call   hs_append
    jmp    hp_pass
hp_check_digit:
    cmp    eax, 30h
    jb     hp_check_end
    cmp    eax, 39h
    ja     hp_check_end
    call   hs_append
    jmp    hp_pass
hp_check_end:
    cmp    eax, 20h                           ; space
    je     hp_end_char
    cmp    eax, 09h                           ; tab
    je     hp_end_char
    cmp    eax, 0Dh                           ; enter
    je     hp_end_char
    cmp    eax, 0BEh                          ; VK_OEM_PERIOD
    je     hp_end_char
    cmp    eax, 0BCh                          ; VK_OEM_COMMA
    je     hp_end_char
    cmp    eax, 0BAh                          ; VK_OEM_1 (;)
    je     hp_end_char
    cmp    eax, 0BFh                          ; VK_OEM_2 (/?)
    je     hp_end_char
    mov    dword ptr [hotstring_len], 0       ; any other VK → reset buffer
    jmp    hp_pass
hp_end_char:
    call   hs_match_and_paste
    mov    dword ptr [hotstring_len], 0
hp_pass:
    popad
    push   lParam
    push   wParam
    push   nCode
    push   [hhook]
    call   CallNextHookEx
    ret
; hp_swallow — return 1 to suppress the key (CapsLock/Esc/Enter picker gestures
; never reach the OS). Reached only via explicit jmp, after hp_pass so the
; hotstring end-chars fall through to passthrough, not here.
hp_swallow:
    popad
    mov    eax, 1
    ret
hook_proc endp

; ---------------------------------------------------------------------------
;  install_hook — register the LL keyboard hook (handle → [hhook]).
; ---------------------------------------------------------------------------
install_hook:
    push   0                                  ; lpModuleName = NULL → exe
    call   GetModuleHandleA
    push   0                                  ; dwThreadId = 0 (global)
    push   eax                                ; hMod = our exe instance
    push   offset hook_proc
    push   13                                 ; WH_KEYBOARD_LL
    call   SetWindowsHookExA
    mov    [hhook], eax
    ret

; ---------------------------------------------------------------------------
;  Tray icon (default). lal4s is a hidden message-only app, so the tray icon is
;  its visible presence + the way to quit. Right-click / double-click -> a menu
;  with "Exit". Uses the classic 88-byte NOTIFYICONDATAA (offsets inline).
;    +0 cbSize  +4 hWnd  +8 uID  +12 uFlags  +16 uCallbackMessage
;    +20 hIcon  +24 szTip[64]
; ---------------------------------------------------------------------------
install_tray:
    pushad
    ; load the app icon (resource id 1) for the tray
    push   1
    push   [hinst]
    call   LoadIconA
    mov    [hiconlal], eax
    mov    dword ptr [tray_nid+0],  88          ; cbSize (classic form)
    mov    eax, [hwndmsg]
    mov    dword ptr [tray_nid+4], eax           ; hWnd (our message window)
    mov    dword ptr [tray_nid+8],  1            ; uID
    mov    dword ptr [tray_nid+12], 7            ; NIF_MESSAGE|NIF_ICON|NIF_TIP
    mov    dword ptr [tray_nid+16], WM_TRAYCB    ; uCallbackMessage
    mov    eax, [hiconlal]
    mov    dword ptr [tray_nid+20], eax          ; hIcon
    ; copy tooltip into szTip (+24), NUL-terminated, max 63
    mov    esi, offset tray_tip
    lea    edi, [tray_nid+24]
    mov    ecx, 63
it_tip_copy:
    test   ecx, ecx
    jz     it_tip_done
    mov    al, [esi]
    mov    [edi], al
    test   al, al
    jz     it_tip_done
    inc    esi
    inc    edi
    dec    ecx
    jmp    it_tip_copy
it_tip_done:
    mov    byte ptr [edi], 0
    push   offset tray_nid
    push   0                                     ; NIM_ADD
    call   Shell_NotifyIconA
    popad
    ret

; remove_tray — NIM_DELETE (called before ExitProcess)
remove_tray:
    pushad
    push   offset tray_nid
    push   2                                     ; NIM_DELETE
    call   Shell_NotifyIconA
    popad
    ret

; tray_show_menu — build a small popup ("Exit") and track it at the cursor.
; Menu selections arrive as WM_COMMAND to lal4s_wnd_proc (id = TRAY_MENU_EXIT).
tray_show_menu:
    pushad
    call   CreatePopupMenu
    test   eax, eax
    jz     tsm_done
    mov    ebx, eax
    mov    [tray_menu], ebx
    push   offset tray_label_exit
    push   TRAY_MENU_EXIT
    push   0                                     ; MF_STRING
    push   ebx
    call   AppendMenuA
    ; MS docs: foreground the owner so the menu dismisses on outside click
    push   [hwndmsg]
    call   SetForegroundWindow
    push   offset tray_menu_pt
    call   GetCursorPos
    push   0                                     ; prcRect
    push   [hwndmsg]                             ; hWnd owner
    push   0                                     ; reserved
    push   dword ptr [tray_menu_pt+4]            ; y
    push   dword ptr [tray_menu_pt+0]            ; x
    push   0                                     ; uFlags (TPM_LEFTALIGN)
    push   ebx                                   ; hMenu
    call   TrackPopupMenu
    push   ebx
    call   DestroyMenu
    mov    dword ptr [tray_menu], 0
tsm_done:
    popad
    ret

.data
hiconlal        dd  0
tray_nid        db  88 dup (0)     ; NOTIFYICONDATAA (classic 88-byte form)
tray_tip        db  'lal4s - snippet / automation runner', 0
tray_menu       dd  0
tray_menu_pt    dd  0, 0           ; POINT for cursor at right-click
tray_label_exit db  'Exit lal4s', 0
.code

; ===========================================================================
;  IMAGE / PIXEL primitives (cf22 Phase 3C).  pixelcolor / pixelwait / pix3eq
;  + the imgfind/imgclick/imgwait family (full-screen, rect-bound `in`, and the
;  DLL-free inline `c`/`inc` variants). load_image_dll trimmed to the single
;  ImageSearch export; all dbg logging removed.
; ===========================================================================
.data
; --- pixel scratch ---
ep_tol              dd  0
p3eq_p1x            dd  0
p3eq_p1y            dd  0
p3eq_col1           dd  0
p3eq_p2x            dd  0
p3eq_p2y            dd  0
p3eq_col2           dd  0
p3eq_p3x            dd  0
p3eq_p3y            dd  0
p3eq_col3           dd  0
; --- helpers.dll (ImageSearch export) ---
img_dll_name1       db  'helpers.dll', 0
img_dll_name2       db  'lib_cf22_h\Release\helpers.dll', 0
img_proc_name       db  'ImageSearch', 0
h_image_dll         dd  0
image_search_fn     dd  0
; --- ImageSearch arg + parsed result ---
img_arg_buf         db  512 dup (0)
img_found           dd  0
img_x               dd  0
img_y               dd  0
img_w               dd  0
img_h               dd  0
img_left            dd  0
img_top             dd  0
img_right           dd  0
img_bottom          dd  0
; --- inline (DLL-free) BMP engine: target cache ---
cached_target_fname db  512 dup (0)
cached_target_valid dd  0
bmp_fname_save      dd  0
img_bmp_ptr         dd  0                 ; current VirtualAlloc'd buffer (0 = none)
img_bmp_cap         dd  0
img_bmp_bytes_read  dd  0
img_bmp_handle      dd  0
img_target_w        dd  0
img_target_h        dd  0
img_target_pix      dd  0
img_target_bpp      dd  0                 ; 24 or 32
img_target_stride   dd  0                 ; signed (neg = bottom-up source)
img_screen_dc       dd  0
img_screen_cdc      dd  0
img_screen_hbm      dd  0
img_screen_oldhbm   dd  0
img_screen_pix      dd  0
img_screen_w        dd  0
img_screen_h        dd  0
img_inline_tol      dd  0
; BITMAPINFO for CreateDIBSection — 32bpp top-down BI_RGB
img_bmi             dd  40                ; biSize
                    dd  0                 ; biWidth (runtime)
                    dd  0                 ; biHeight — negative = top-down
                    dw  1                 ; biPlanes
                    dw  32                ; biBitCount
                    dd  0                 ; biCompression = BI_RGB
                    dd  0                 ; biSizeImage
                    dd  0                 ; biXPelsPerMeter
                    dd  0                 ; biYPelsPerMeter
                    dd  0                 ; biClrUsed
                    dd  0                 ; biClrImportant
img_inline_result   db  64 dup (0)        ; "0" or "1|x|y|w|h\0"
; inline_match loop state (globals to free registers)
ic_max_sy           dd  0
ic_max_sx           dd  0
ic_screen_stride    dd  0
ic_target_pix_bytes dd  0
ic_sx               dd  0
ic_sy               dd  0
ic_tx               dd  0
ic_ty               dd  0

.code
; ---------------------------------------------------------------------------
;  load_image_dll — LoadLibrary helpers.dll, GetProcAddress("ImageSearch").
;    Best-effort: if the DLL or export is missing, image_search_fn stays 0 and
;    the DLL-based img* primitives no-op (the inline `c`/`inc` ones still work).
; ---------------------------------------------------------------------------
load_image_dll:
    pushad
    push   offset img_dll_name1
    call   LoadLibraryA
    or     eax, eax
    jnz    lid_got_hmod
    push   offset img_dll_name2
    call   LoadLibraryA
    or     eax, eax
    jz     lid_fail
lid_got_hmod:
    mov    [h_image_dll], eax
    push   offset img_proc_name
    push   eax
    call   GetProcAddress
    mov    [image_search_fn], eax           ; 0 if missing — img_search no-ops
    ; additional helpers.dll exports (0 if missing — the primitive no-ops)
    push   offset winshot_proc_name
    push   [h_image_dll]
    call   GetProcAddress
    mov    [winshot_fn], eax                ; sc_winshot
    push   offset debug_box_proc_name
    push   [h_image_dll]
    call   GetProcAddress
    mov    [debug_box_fn], eax              ; sc_debug_box
    ; --- UIA exports: tab picker (Ctrl+Shift+Space) + consent (Ctrl+Alt+R) ---
    push   offset tabnav_count_name
    push   [h_image_dll]
    call   GetProcAddress
    mov    [tabnav_count_fn], eax
    push   offset tabnav_get_title_name
    push   [h_image_dll]
    call   GetProcAddress
    mov    [tabnav_get_title_fn], eax
    push   offset tabnav_switch_name
    push   [h_image_dll]
    call   GetProcAddress
    mov    [tabnav_switch_fn], eax
    push   offset tabnav_snapshot_name
    push   [h_image_dll]
    call   GetProcAddress
    mov    [tabnav_snapshot_fn], eax
    push   offset consent_reject_name
    push   [h_image_dll]
    call   GetProcAddress
    mov    [consent_reject_fn], eax
    ; --- Phase 4: CDP web-automation exports (0 if missing → web* no-op) ---
    push   offset cdp_launch_name
    push   [h_image_dll]
    call   GetProcAddress
    mov    [cdp_launch_fn], eax
    push   offset cdp_connect_name
    push   [h_image_dll]
    call   GetProcAddress
    mov    [cdp_connect_fn], eax
    push   offset cdp_eval_name
    push   [h_image_dll]
    call   GetProcAddress
    mov    [cdp_eval_fn], eax
    push   offset cdp_getcon_name
    push   [h_image_dll]
    call   GetProcAddress
    mov    [cdp_getcon_fn], eax
    push   offset cdp_getnet_name
    push   [h_image_dll]
    call   GetProcAddress
    mov    [cdp_getnet_fn], eax
    push   offset cdp_clearlog_name
    push   [h_image_dll]
    call   GetProcAddress
    mov    [cdp_clearlog_fn], eax
    push   offset cdp_disconnect_name
    push   [h_image_dll]
    call   GetProcAddress
    mov    [cdp_disconnect_fn], eax
    push   offset cdp_health_name
    push   [h_image_dll]
    call   GetProcAddress
    mov    [cdp_health_fn], eax
lid_fail:
    popad
    ret

; ---------------------------------------------------------------------------
;  Pixel primitives
; ---------------------------------------------------------------------------
; pixelcolor ( x y -- bgr ) — GetPixel; pushes COLORREF (0xFFFFFFFF on fail)
sc_pixelcolor:
    pushad
    call   scr_pop                           ; y
    mov    edi, eax
    call   scr_pop                           ; x
    mov    esi, eax
    push   0
    call   GetDC
    or     eax, eax
    jz     sc_pixelcolor_fail
    mov    ebx, eax                          ; ebx = hdc
    push   edi
    push   esi
    push   ebx
    call   GetPixel
    mov    edi, eax                          ; save color
    push   ebx
    push   0
    call   ReleaseDC
    mov    eax, edi
    call   scr_push
    popad
    ret
sc_pixelcolor_fail:
    mov    eax, 0FFFFFFFFh                    ; CLR_INVALID
    call   scr_push
    popad
    ret

; pixelwait ( x y bgr ms -- ) — poll GetPixel every 50ms until == bgr / timeout
sc_pixelwait:
    pushad
    call   scr_pop                           ; ms
    mov    ebp, eax
    call   scr_pop                           ; bgr
    mov    edi, eax
    call   scr_pop                           ; y
    mov    ebx, eax
    call   scr_pop                           ; x
    mov    esi, eax
sc_pixelwait_loop:
    push   0
    call   GetDC
    or     eax, eax
    jz     sc_pixelwait_done
    mov    edx, eax
    push   ebx
    push   esi
    push   edx
    call   GetPixel
    push   eax
    push   edx
    push   0
    call   ReleaseDC
    pop    eax
    cmp    eax, edi
    je     sc_pixelwait_done
    sub    ebp, 50
    jbe    sc_pixelwait_done
    push   50
    call   Sleep
    jmp    sc_pixelwait_loop
sc_pixelwait_done:
    popad
    ret

; pix3eq ( p1x p1y col1 p2x p2y col2 p3x p3y col3 tol -- 0|1 )
sc_pix3eq:
    pushad
    call   scr_pop
    mov    [ep_tol], eax
    call   scr_pop
    mov    [p3eq_col3], eax
    call   scr_pop
    mov    [p3eq_p3y], eax
    call   scr_pop
    mov    [p3eq_p3x], eax
    call   scr_pop
    mov    [p3eq_col2], eax
    call   scr_pop
    mov    [p3eq_p2y], eax
    call   scr_pop
    mov    [p3eq_p2x], eax
    call   scr_pop
    mov    [p3eq_col1], eax
    call   scr_pop
    mov    [p3eq_p1y], eax
    call   scr_pop
    mov    [p3eq_p1x], eax
    push   0
    call   GetDC
    test   eax, eax
    jz     p3eq_fail_no_dc
    mov    ebx, eax                             ; ebx = hdc
    push   [p3eq_p1y]
    push   [p3eq_p1x]
    push   ebx
    call   GetPixel
    mov    edx, [p3eq_col1]
    call   pixel_within_tol
    test   eax, eax
    jz     p3eq_miss
    push   [p3eq_p2y]
    push   [p3eq_p2x]
    push   ebx
    call   GetPixel
    mov    edx, [p3eq_col2]
    call   pixel_within_tol
    test   eax, eax
    jz     p3eq_miss
    push   [p3eq_p3y]
    push   [p3eq_p3x]
    push   ebx
    call   GetPixel
    mov    edx, [p3eq_col3]
    call   pixel_within_tol
    test   eax, eax
    jz     p3eq_miss
    push   ebx
    push   0
    call   ReleaseDC
    mov    eax, 1
    jmp    p3eq_emit
p3eq_miss:
    push   ebx
    push   0
    call   ReleaseDC
    xor    eax, eax
    jmp    p3eq_emit
p3eq_fail_no_dc:
    xor    eax, eax
p3eq_emit:
    call   scr_push
    popad
    ret

; pixel_within_tol — eax=got COLORREF, edx=want; eax=1 if B/G/R all within [ep_tol]
pixel_within_tol:
    push   ebx
    push   ecx
    mov    ecx, [ep_tol]
    mov    bl, al
    mov    bh, dl
    sub    bl, bh
    jnc    @f
    neg    bl
@@: cmp    bl, cl
    ja     pwt_no
    shr    eax, 8
    shr    edx, 8
    mov    bl, al
    mov    bh, dl
    sub    bl, bh
    jnc    @f
    neg    bl
@@: cmp    bl, cl
    ja     pwt_no
    shr    eax, 8
    shr    edx, 8
    mov    bl, al
    mov    bh, dl
    sub    bl, bh
    jnc    @f
    neg    bl
@@: cmp    bl, cl
    ja     pwt_no
    pop    ecx
    pop    ebx
    mov    eax, 1
    ret
pwt_no:
    pop    ecx
    pop    ebx
    xor    eax, eax
    ret

; ---------------------------------------------------------------------------
;  Image search — shared helpers (DLL path)
; ---------------------------------------------------------------------------
; img_fmt_arg (eax=tol, ebx=fname ptr, ecx=fname len) — build "*<tol> <fname>\0"
img_fmt_arg:
    pushad
    mov    esi, ebx                  ; esi = src fname ptr
    cmp    ecx, 480
    jbe    @f
    mov    ecx, 480                  ; cap fname length
@@: push   ecx
    mov    edi, offset img_arg_buf
    mov    byte ptr [edi], '*'
    inc    edi
    or     eax, eax
    jnz    ifa_nz
    mov    byte ptr [edi], '0'
    inc    edi
    jmp    ifa_after
ifa_nz:
    xor    ecx, ecx
    mov    ebx, 10
ifa_div:
    xor    edx, edx
    div    ebx
    push   edx
    inc    ecx
    or     eax, eax
    jnz    ifa_div
ifa_emit:
    pop    edx
    add    dl, '0'
    mov    [edi], dl
    inc    edi
    dec    ecx
    jnz    ifa_emit
ifa_after:
    mov    byte ptr [edi], ' '
    inc    edi
    pop    ecx                       ; restore fname len
ifa_copy:
    or     ecx, ecx
    jz     ifa_done
    mov    al, [esi]
    mov    [edi], al
    inc    esi
    inc    edi
    dec    ecx
    jmp    ifa_copy
ifa_done:
    mov    byte ptr [edi], 0
    popad
    ret

; img_rect_fullscreen — set img_left/top/right/bottom to the primary monitor
img_rect_fullscreen:
    pushad
    mov    dword ptr [img_left], 0
    mov    dword ptr [img_top],  0
    push   0                          ; SM_CXSCREEN
    call   GetSystemMetrics
    mov    [img_right], eax
    push   1                          ; SM_CYSCREEN
    call   GetSystemMetrics
    mov    [img_bottom], eax
    popad
    ret

; img_rect_from_stack — pop (x1 y1 x2 y2) into img_left/top/right/bottom
img_rect_from_stack:
    call   scr_pop                    ; y2
    mov    [img_bottom], eax
    call   scr_pop                    ; x2
    mov    [img_right], eax
    call   scr_pop                    ; y1
    mov    [img_top], eax
    call   scr_pop                    ; x1
    mov    [img_left], eax
    ret

; img_search — call helpers.dll ImageSearch(left,top,right,bottom,arg); eax=result ptr
img_search:
    cmp    dword ptr [image_search_fn], 0
    je     is_no_fn
    push   offset img_arg_buf
    push   [img_bottom]
    push   [img_right]
    push   [img_top]
    push   [img_left]
    call   dword ptr [image_search_fn]
    ret
is_no_fn:
    xor    eax, eax
    ret

; img_parse (eax=result ptr) — "1|x|y|w|h" → img_x/y/w/h + img_found=1
img_parse:
    pushad
    mov    dword ptr [img_found], 0
    or     eax, eax
    jz     ip_ret
    cmp    byte ptr [eax], '1'
    jne    ip_ret
    inc    eax
    cmp    byte ptr [eax], '|'
    jne    ip_ret
    inc    eax
    mov    edi, offset img_x
    call   ip_int
    mov    edi, offset img_y
    call   ip_int
    mov    edi, offset img_w
    call   ip_int
    mov    edi, offset img_h
    call   ip_int
    mov    dword ptr [img_found], 1
ip_ret:
    popad
    ret

; ip_int — read decimal at [eax] → [edi]; skip one trailing '|'
ip_int:
    xor    ecx, ecx
ipi_l:
    mov    bl, [eax]
    cmp    bl, '0'
    jb     ipi_e
    cmp    bl, '9'
    ja     ipi_e
    sub    bl, '0'
    mov    edx, ecx
    shl    ecx, 1
    shl    edx, 3
    add    ecx, edx
    movzx  edx, bl
    add    ecx, edx
    inc    eax
    jmp    ipi_l
ipi_e:
    mov    [edi], ecx
    cmp    bl, '|'
    jne    @f
    inc    eax
@@: ret

; ---------------------------------------------------------------------------
;  Inline (DLL-free) BMP search engine
; ---------------------------------------------------------------------------
; img_parse_tol_inline — read "*<tol> " prefix; eax = fname ptr (0 on fail)
img_parse_tol_inline:
    mov    esi, offset img_arg_buf
    cmp    byte ptr [esi], '*'
    jne    ipti_fail
    inc    esi
    xor    eax, eax
ipti_dig:
    movzx  ecx, byte ptr [esi]
    cmp    cl, '0'
    jb     ipti_after_dig
    cmp    cl, '9'
    ja     ipti_after_dig
    sub    cl, '0'
    mov    edx, eax
    shl    eax, 1
    shl    edx, 3
    add    eax, edx
    add    eax, ecx
    inc    esi
    jmp    ipti_dig
ipti_after_dig:
    mov    [img_inline_tol], eax
    cmp    byte ptr [esi], ' '
    jne    ipti_fail
    inc    esi
    mov    eax, esi
    ret
ipti_fail:
    xor    eax, eax
    ret

; bmp_load_target(eax = fname ptr) → eax = 1 ok, 0 fail
bmp_load_target:
    pushad
    mov    dword ptr [esp+28], 0                    ; eax slot = 0 (fail)
    mov    ebx, eax                       ; ebx = fname ptr
    cmp    dword ptr [cached_target_valid], 0
    je     blt_no_cache
    mov    esi, ebx
    mov    edi, offset cached_target_fname
blt_cache_cmp:
    mov    al, [esi]
    cmp    al, [edi]
    jne    blt_no_cache
    test   al, al
    jz     blt_cache_hit
    inc    esi
    inc    edi
    jmp    blt_cache_cmp
blt_cache_hit:
    mov    dword ptr [esp+28], 1
    popad
    ret
blt_no_cache:
    mov    [bmp_fname_save], ebx
    mov    dword ptr [cached_target_valid], 0
    cmp    dword ptr [img_bmp_ptr], 0
    je     blt_no_prev_free
    push   8000h                          ; MEM_RELEASE
    push   0
    push   [img_bmp_ptr]
    call   VirtualFree
    mov    dword ptr [img_bmp_ptr], 0
    mov    dword ptr [img_bmp_cap], 0
blt_no_prev_free:
    push   0
    push   80h
    push   3                              ; OPEN_EXISTING
    push   0
    push   1                              ; FILE_SHARE_READ
    push   80000000h                      ; GENERIC_READ
    push   ebx
    call   CreateFileA
    cmp    eax, -1
    je     blt_done
    mov    [img_bmp_handle], eax
    push   0
    push   eax
    call   GetFileSize
    cmp    eax, -1
    je     blt_fail_close
    cmp    eax, 54
    jb     blt_fail_close
    cmp    eax, 4000000h                  ; 64 MB ceiling
    ja     blt_fail_close
    mov    [img_bmp_cap], eax
    push   4                              ; PAGE_READWRITE
    push   1000h                          ; MEM_COMMIT
    push   eax
    push   0
    call   VirtualAlloc
    test   eax, eax
    jz     blt_fail_close
    mov    [img_bmp_ptr], eax
    push   0
    push   offset img_bmp_bytes_read
    push   [img_bmp_cap]
    push   [img_bmp_ptr]
    push   [img_bmp_handle]
    call   ReadFile
    push   [img_bmp_handle]
    call   CloseHandle
    cmp    dword ptr [img_bmp_bytes_read], 54
    jb     blt_done
    mov    esi, [img_bmp_ptr]
    cmp    word ptr [esi], 4D42h          ; 'BM'
    jne    blt_done
    cmp    word ptr [esi+26], 1           ; biPlanes
    jne    blt_done
    cmp    dword ptr [esi+30], 0          ; biCompression = BI_RGB
    jne    blt_done
    movzx  eax, word ptr [esi+28]         ; biBitCount
    cmp    eax, 24
    je     blt_bpp_ok
    cmp    eax, 32
    je     blt_bpp_ok
    jmp    blt_done
blt_bpp_ok:
    mov    [img_target_bpp], eax
    mov    eax, [esi+18]                  ; biWidth
    test   eax, eax
    jle    blt_done
    mov    [img_target_w], eax
    mov    ebx, eax                       ; ebx = width
    mov    ecx, [esi+22]                  ; signed biHeight
    test   ecx, ecx
    jz     blt_done
    jns    blt_bottom_up
    neg    ecx
    mov    [img_target_h], ecx
    mov    edx, 1                         ; topdown flag
    jmp    blt_compute_stride
blt_bottom_up:
    mov    [img_target_h], ecx
    xor    edx, edx
blt_compute_stride:
    push   eax
    push   ecx
    push   edx
    mov    eax, ebx
    mul    ecx                            ; eax = w * h
    mov    ecx, [img_target_bpp]
    shr    ecx, 3
    mul    ecx                            ; eax = w * h * (bpp/8)
    add    eax, 1024
    cmp    eax, [img_bmp_bytes_read]
    ja     blt_oversize_unwind
    pop    edx
    pop    ecx
    pop    eax
    jmp    blt_stride_compute_real
blt_oversize_unwind:
    pop    edx
    pop    ecx
    pop    eax
    jmp    blt_done
blt_stride_compute_real:
    push   edx
    push   ecx
    mov    eax, ebx
    mov    ecx, [img_target_bpp]
    mul    ecx
    add    eax, 31
    shr    eax, 5
    shl    eax, 2
    mov    edi, eax                       ; edi = phys_stride
    pop    ecx
    pop    edx
    mov    esi, [img_bmp_ptr]
    mov    eax, [esi+10]                  ; bfOffBits
    add    esi, eax
    test   edx, edx
    jnz    blt_topdown_ptr
    mov    eax, ecx
    dec    eax
    mul    edi
    add    esi, eax
    mov    [img_target_pix], esi
    neg    edi
    mov    [img_target_stride], edi
    jmp    blt_ok
blt_topdown_ptr:
    mov    [img_target_pix], esi
    mov    [img_target_stride], edi
blt_ok:
    mov    esi, [bmp_fname_save]
    mov    edi, offset cached_target_fname
    mov    ecx, 511
blt_cache_store:
    mov    al, [esi]
    mov    [edi], al
    test   al, al
    jz     blt_cache_stored
    inc    esi
    inc    edi
    dec    ecx
    jnz    blt_cache_store
    mov    byte ptr [edi], 0
blt_cache_stored:
    mov    dword ptr [cached_target_valid], 1
    mov    dword ptr [esp+28], 1                    ; eax slot = 1 (success)
blt_fail_close:
    push   [img_bmp_handle]
    call   CloseHandle
    jmp    blt_done
blt_done:
    popad
    ret

; screen_capture() → eax = 1 ok, 0 fail. 32bpp top-down DIB of the img rect.
screen_capture:
    pushad
    mov    dword ptr [esp+28], 0
    mov    dword ptr [img_screen_dc], 0
    mov    dword ptr [img_screen_cdc], 0
    mov    dword ptr [img_screen_hbm], 0
    mov    dword ptr [img_screen_oldhbm], 0
    mov    dword ptr [img_screen_pix], 0
    mov    eax, [img_right]
    sub    eax, [img_left]
    test   eax, eax
    jle    sc2_fail
    mov    [img_screen_w], eax
    mov    [img_bmi+4], eax               ; biWidth
    mov    eax, [img_bottom]
    sub    eax, [img_top]
    test   eax, eax
    jle    sc2_fail
    mov    [img_screen_h], eax
    neg    eax
    mov    [img_bmi+8], eax               ; biHeight = -h (top-down)
    push   0
    call   GetDC
    or     eax, eax
    jz     sc2_fail
    mov    [img_screen_dc], eax
    push   eax
    call   CreateCompatibleDC
    or     eax, eax
    jz     sc2_fail
    mov    [img_screen_cdc], eax
    push   0
    push   0
    push   offset img_screen_pix
    push   0                              ; DIB_RGB_COLORS
    push   offset img_bmi
    push   eax
    call   CreateDIBSection
    or     eax, eax
    jz     sc2_fail
    mov    [img_screen_hbm], eax
    push   eax
    push   [img_screen_cdc]
    call   SelectObject
    mov    [img_screen_oldhbm], eax
    push   0CC0020h                       ; SRCCOPY
    push   [img_top]
    push   [img_left]
    push   [img_screen_dc]
    push   [img_screen_h]
    push   [img_screen_w]
    push   0
    push   0
    push   [img_screen_cdc]
    call   BitBlt
    mov    dword ptr [esp+28], 1
    popad
    ret
sc2_fail:
    popad
    call   screen_release
    xor    eax, eax
    ret

; screen_release() — idempotent teardown of screen_capture state
screen_release:
    pushad
    cmp    dword ptr [img_screen_oldhbm], 0
    je     sr_skip_select
    cmp    dword ptr [img_screen_cdc], 0
    je     sr_skip_select
    push   [img_screen_oldhbm]
    push   [img_screen_cdc]
    call   SelectObject
    mov    dword ptr [img_screen_oldhbm], 0
sr_skip_select:
    cmp    dword ptr [img_screen_hbm], 0
    je     sr_skip_hbm
    push   [img_screen_hbm]
    call   DeleteObject
    mov    dword ptr [img_screen_hbm], 0
sr_skip_hbm:
    cmp    dword ptr [img_screen_cdc], 0
    je     sr_skip_cdc
    push   [img_screen_cdc]
    call   DeleteDC
    mov    dword ptr [img_screen_cdc], 0
sr_skip_cdc:
    cmp    dword ptr [img_screen_dc], 0
    je     sr_skip_dc
    push   [img_screen_dc]
    push   0
    call   ReleaseDC
    mov    dword ptr [img_screen_dc], 0
sr_skip_dc:
    popad
    ret

; compare_pixel(esi=screen ptr, edi=target ptr) → eax=1 match; B/G/R within tol
compare_pixel:
    push   ecx
    push   edx
    mov    ecx, [img_inline_tol]
    movzx  eax, byte ptr [esi]
    movzx  edx, byte ptr [edi]
    sub    eax, edx
    jns    @f
    neg    eax
@@: cmp    eax, ecx
    ja     cp_mismatch
    movzx  eax, byte ptr [esi+1]
    movzx  edx, byte ptr [edi+1]
    sub    eax, edx
    jns    @f
    neg    eax
@@: cmp    eax, ecx
    ja     cp_mismatch
    movzx  eax, byte ptr [esi+2]
    movzx  edx, byte ptr [edi+2]
    sub    eax, edx
    jns    @f
    neg    eax
@@: cmp    eax, ecx
    ja     cp_mismatch
    mov    eax, 1
    pop    edx
    pop    ecx
    ret
cp_mismatch:
    xor    eax, eax
    pop    edx
    pop    ecx
    ret

; inline_match() — scan; sets img_found/x/y/w/h + img_inline_result
inline_match:
    pushad
    mov    dword ptr [img_found], 0
    mov    edi, offset img_inline_result
    mov    byte ptr [edi], '0'
    mov    byte ptr [edi+1], 0
    mov    eax, [img_screen_w]
    test   eax, eax
    jle    im_done
    mov    eax, [img_screen_h]
    test   eax, eax
    jle    im_done
    mov    eax, [img_target_w]
    test   eax, eax
    jle    im_done
    mov    eax, [img_target_h]
    test   eax, eax
    jle    im_done
    mov    eax, [img_screen_h]
    sub    eax, [img_target_h]
    js     im_done
    mov    [ic_max_sy], eax
    mov    eax, [img_screen_w]
    sub    eax, [img_target_w]
    js     im_done
    mov    [ic_max_sx], eax
    mov    eax, [img_screen_w]
    shl    eax, 2
    mov    [ic_screen_stride], eax
    mov    eax, [img_target_bpp]
    shr    eax, 3
    mov    [ic_target_pix_bytes], eax
    mov    dword ptr [ic_sy], 0
im_sy_loop:
    mov    eax, [ic_sy]
    cmp    eax, [ic_max_sy]
    jg     im_done
    mov    dword ptr [ic_sx], 0
im_sx_loop:
    mov    eax, [ic_sx]
    cmp    eax, [ic_max_sx]
    jg     im_sx_end
    mov    eax, [ic_sy]
    imul   eax, [ic_screen_stride]
    add    eax, [img_screen_pix]
    mov    edx, [ic_sx]
    shl    edx, 2
    add    eax, edx
    mov    esi, eax
    mov    edi, [img_target_pix]
    call   compare_pixel
    or     eax, eax
    jz     im_sx_next
    mov    dword ptr [ic_ty], 0
im_ty_loop:
    mov    eax, [ic_ty]
    cmp    eax, [img_target_h]
    jge    im_match_found
    mov    dword ptr [ic_tx], 0
im_tx_loop:
    mov    eax, [ic_tx]
    cmp    eax, [img_target_w]
    jge    im_tx_end
    mov    eax, [ic_sy]
    add    eax, [ic_ty]
    imul   eax, [ic_screen_stride]
    add    eax, [img_screen_pix]
    mov    edx, [ic_sx]
    add    edx, [ic_tx]
    shl    edx, 2
    add    eax, edx
    mov    esi, eax
    mov    eax, [ic_ty]
    imul   eax, [img_target_stride]       ; signed
    add    eax, [img_target_pix]
    mov    edx, [ic_tx]
    imul   edx, [ic_target_pix_bytes]
    add    eax, edx
    mov    edi, eax
    call   compare_pixel
    or     eax, eax
    jz     im_sx_next
    inc    dword ptr [ic_tx]
    jmp    im_tx_loop
im_tx_end:
    inc    dword ptr [ic_ty]
    jmp    im_ty_loop
im_sx_next:
    inc    dword ptr [ic_sx]
    jmp    im_sx_loop
im_sx_end:
    inc    dword ptr [ic_sy]
    jmp    im_sy_loop
im_match_found:
    mov    eax, [img_left]
    add    eax, [ic_sx]
    mov    [img_x], eax
    mov    eax, [img_top]
    add    eax, [ic_sy]
    mov    [img_y], eax
    mov    eax, [img_target_w]
    mov    [img_w], eax
    mov    eax, [img_target_h]
    mov    [img_h], eax
    mov    dword ptr [img_found], 1
    call   format_inline_result
im_done:
    popad
    ret

; format_inline_result — write "1|x|y|w|h\0" from img_x/y/w/h
format_inline_result:
    push   eax
    push   edi
    mov    edi, offset img_inline_result
    mov    byte ptr [edi], '1'
    inc    edi
    mov    byte ptr [edi], '|'
    inc    edi
    mov    eax, [img_x]
    call   write_decimal
    mov    byte ptr [edi], '|'
    inc    edi
    mov    eax, [img_y]
    call   write_decimal
    mov    byte ptr [edi], '|'
    inc    edi
    mov    eax, [img_w]
    call   write_decimal
    mov    byte ptr [edi], '|'
    inc    edi
    mov    eax, [img_h]
    call   write_decimal
    mov    byte ptr [edi], 0
    pop    edi
    pop    eax
    ret

; write_decimal(eax=value, edi=dest) — advances edi past digits
write_decimal:
    push   ebx
    push   ecx
    push   edx
    or     eax, eax
    jnz    wd_nz
    mov    byte ptr [edi], '0'
    inc    edi
    jmp    wd_done
wd_nz:
    xor    ecx, ecx
    mov    ebx, 10
wd_div:
    xor    edx, edx
    div    ebx
    push   edx
    inc    ecx
    or     eax, eax
    jnz    wd_div
wd_emit:
    pop    edx
    add    dl, '0'
    mov    [edi], dl
    inc    edi
    dec    ecx
    jnz    wd_emit
wd_done:
    pop    edx
    pop    ecx
    pop    ebx
    ret

; img_search_inline — Stage C top-level; eax = ptr to result string
img_search_inline:
    pushad
    call   img_parse_tol_inline
    or     eax, eax
    jz     isi_fail
    call   bmp_load_target
    or     eax, eax
    jz     isi_fail
    call   screen_capture
    or     eax, eax
    jz     isi_fail
    call   inline_match
    call   screen_release
    jmp    isi_done
isi_fail:
    call   screen_release
    mov    edi, offset img_inline_result
    mov    byte ptr [edi], '0'
    mov    byte ptr [edi+1], 0
isi_done:
    popad
    mov    eax, offset img_inline_result
    ret

; ---------------------------------------------------------------------------
;  Image primitives — DLL path (full screen + rect-bound `in`)
;    imgfind  ( str tol -- cx cy found )
;    imgclick ( str tol -- )
;    imgwait  ( str tol ms -- )
;    *in variants take x1 y1 x2 y2 str tol [ms].
; ---------------------------------------------------------------------------
sc_imgfind:
    pushad
    call   scr_pop                    ; tol
    mov    edi, eax
    call   scr_pop                    ; len
    mov    ecx, eax
    call   scr_pop                    ; ptr
    mov    ebx, eax
    mov    eax, edi
    call   img_fmt_arg
    call   img_rect_fullscreen
    call   img_search
    call   img_parse
    cmp    dword ptr [img_found], 0
    je     sif_notfound
    mov    eax, [img_w]
    shr    eax, 1
    add    eax, [img_x]
    call   scr_push                   ; cx
    mov    eax, [img_h]
    shr    eax, 1
    add    eax, [img_y]
    call   scr_push                   ; cy
    mov    eax, 1
    call   scr_push                   ; found
    popad
    ret
sif_notfound:
    xor    eax, eax
    call   scr_push
    call   scr_push
    call   scr_push
    popad
    ret

sc_imgclick:
    pushad
    call   scr_pop
    mov    edi, eax
    call   scr_pop
    mov    ecx, eax
    call   scr_pop
    mov    ebx, eax
    mov    eax, edi
    call   img_fmt_arg
    call   img_rect_fullscreen
    call   img_search
    call   img_parse
    cmp    dword ptr [img_found], 0
    je     sic_done
    mov    eax, [img_w]
    shr    eax, 1
    add    eax, [img_x]
    mov    ebx, eax
    mov    eax, [img_h]
    shr    eax, 1
    add    eax, [img_y]
    push   eax
    push   ebx
    call   SetCursorPos
    call   sc_click
sic_done:
    popad
    ret

sc_imgwait:
    pushad
    call   scr_pop                    ; ms
    mov    ebp, eax
    call   scr_pop                    ; tol
    mov    edi, eax
    call   scr_pop                    ; len
    mov    ecx, eax
    call   scr_pop                    ; ptr
    mov    ebx, eax
    mov    eax, edi
    call   img_fmt_arg
    call   img_rect_fullscreen
siw_loop:
    call   img_search
    call   img_parse
    cmp    dword ptr [img_found], 0
    jne    siw_found
    sub    ebp, 50
    jbe    siw_done
    push   50
    call   Sleep
    jmp    siw_loop
siw_found:
    mov    eax, [img_w]
    shr    eax, 1
    add    eax, [img_x]
    mov    ebx, eax
    mov    eax, [img_h]
    shr    eax, 1
    add    eax, [img_y]
    push   eax
    push   ebx
    call   SetCursorPos
    call   sc_click
siw_done:
    popad
    ret

sc_imgfindin:
    pushad
    call   scr_pop
    mov    edi, eax
    call   scr_pop
    mov    ecx, eax
    call   scr_pop
    mov    ebx, eax
    mov    eax, edi
    call   img_fmt_arg
    call   img_rect_from_stack
    call   img_search
    call   img_parse
    cmp    dword ptr [img_found], 0
    je     sifi_notfound
    mov    eax, [img_w]
    shr    eax, 1
    add    eax, [img_x]
    call   scr_push
    mov    eax, [img_h]
    shr    eax, 1
    add    eax, [img_y]
    call   scr_push
    mov    eax, 1
    call   scr_push
    popad
    ret
sifi_notfound:
    xor    eax, eax
    call   scr_push
    call   scr_push
    call   scr_push
    popad
    ret

sc_imgclickin:
    pushad
    call   scr_pop
    mov    edi, eax
    call   scr_pop
    mov    ecx, eax
    call   scr_pop
    mov    ebx, eax
    mov    eax, edi
    call   img_fmt_arg
    call   img_rect_from_stack
    call   img_search
    call   img_parse
    cmp    dword ptr [img_found], 0
    je     sici_done
    mov    eax, [img_w]
    shr    eax, 1
    add    eax, [img_x]
    mov    ebx, eax
    mov    eax, [img_h]
    shr    eax, 1
    add    eax, [img_y]
    push   eax
    push   ebx
    call   SetCursorPos
    call   sc_click
sici_done:
    popad
    ret

sc_imgwaitin:
    pushad
    call   scr_pop                    ; ms
    mov    ebp, eax
    call   scr_pop
    mov    edi, eax
    call   scr_pop
    mov    ecx, eax
    call   scr_pop
    mov    ebx, eax
    mov    eax, edi
    call   img_fmt_arg
    call   img_rect_from_stack
siwi_loop:
    call   img_search
    call   img_parse
    cmp    dword ptr [img_found], 0
    jne    siwi_found
    sub    ebp, 50
    jbe    siwi_done
    push   50
    call   Sleep
    jmp    siwi_loop
siwi_found:
    mov    eax, [img_w]
    shr    eax, 1
    add    eax, [img_x]
    mov    ebx, eax
    mov    eax, [img_h]
    shr    eax, 1
    add    eax, [img_y]
    push   eax
    push   ebx
    call   SetCursorPos
    call   sc_click
siwi_done:
    popad
    ret

; ---------------------------------------------------------------------------
;  Image primitives — inline (DLL-free) `c` / `inc` variants
; ---------------------------------------------------------------------------
sc_imgfindc:
    pushad
    call   scr_pop
    mov    edi, eax
    call   scr_pop
    mov    ecx, eax
    call   scr_pop
    mov    ebx, eax
    mov    eax, edi
    call   img_fmt_arg
    call   img_rect_fullscreen
    call   img_search_inline
    call   img_parse
    cmp    dword ptr [img_found], 0
    je     sifc_notfound
    mov    eax, [img_w]
    shr    eax, 1
    add    eax, [img_x]
    call   scr_push
    mov    eax, [img_h]
    shr    eax, 1
    add    eax, [img_y]
    call   scr_push
    mov    eax, 1
    call   scr_push
    popad
    ret
sifc_notfound:
    xor    eax, eax
    call   scr_push
    call   scr_push
    call   scr_push
    popad
    ret

sc_imgclickc:
    pushad
    call   scr_pop
    mov    edi, eax
    call   scr_pop
    mov    ecx, eax
    call   scr_pop
    mov    ebx, eax
    mov    eax, edi
    call   img_fmt_arg
    call   img_rect_fullscreen
    call   img_search_inline
    call   img_parse
    cmp    dword ptr [img_found], 0
    je     sicc_done
    mov    eax, [img_w]
    shr    eax, 1
    add    eax, [img_x]
    mov    ebx, eax
    mov    eax, [img_h]
    shr    eax, 1
    add    eax, [img_y]
    push   eax
    push   ebx
    call   SetCursorPos
    call   sc_click
sicc_done:
    popad
    ret

sc_imgwaitc:
    pushad
    call   scr_pop                        ; ms
    mov    ebp, eax
    call   scr_pop                        ; tol
    mov    edi, eax
    call   scr_pop                        ; len
    mov    ecx, eax
    call   scr_pop                        ; ptr
    mov    ebx, eax
    mov    eax, edi
    call   img_fmt_arg
    call   img_rect_fullscreen
    call   img_parse_tol_inline
    test   eax, eax
    jz     siwc_done
    call   bmp_load_target
    test   eax, eax
    jz     siwc_done
    call   screen_capture
    test   eax, eax
    jz     siwc_done
siwc_loop:
    call   inline_match
    mov    eax, offset img_inline_result
    call   img_parse
    cmp    dword ptr [img_found], 0
    jne    siwc_found
    sub    ebp, 50
    jbe    siwc_release
    push   50
    call   Sleep
    jmp    siwc_loop
siwc_found:
    call   screen_release
    mov    eax, [img_w]
    shr    eax, 1
    add    eax, [img_x]
    mov    ebx, eax
    mov    eax, [img_h]
    shr    eax, 1
    add    eax, [img_y]
    push   eax
    push   ebx
    call   SetCursorPos
    call   sc_click
    jmp    siwc_done
siwc_release:
    call   screen_release
siwc_done:
    popad
    ret

sc_imgfindinc:
    pushad
    call   scr_pop
    mov    edi, eax
    call   scr_pop
    mov    ecx, eax
    call   scr_pop
    mov    ebx, eax
    mov    eax, edi
    call   img_fmt_arg
    call   img_rect_from_stack
    call   img_search_inline
    call   img_parse
    cmp    dword ptr [img_found], 0
    je     sific_notfound
    mov    eax, [img_w]
    shr    eax, 1
    add    eax, [img_x]
    call   scr_push
    mov    eax, [img_h]
    shr    eax, 1
    add    eax, [img_y]
    call   scr_push
    mov    eax, 1
    call   scr_push
    popad
    ret
sific_notfound:
    xor    eax, eax
    call   scr_push
    call   scr_push
    call   scr_push
    popad
    ret

sc_imgclickinc:
    pushad
    call   scr_pop
    mov    edi, eax
    call   scr_pop
    mov    ecx, eax
    call   scr_pop
    mov    ebx, eax
    mov    eax, edi
    call   img_fmt_arg
    call   img_rect_from_stack
    call   img_search_inline
    call   img_parse
    cmp    dword ptr [img_found], 0
    je     sicic_done
    mov    eax, [img_w]
    shr    eax, 1
    add    eax, [img_x]
    mov    ebx, eax
    mov    eax, [img_h]
    shr    eax, 1
    add    eax, [img_y]
    push   eax
    push   ebx
    call   SetCursorPos
    call   sc_click
sicic_done:
    popad
    ret

sc_imgwaitinc:
    pushad
    call   scr_pop
    mov    ebp, eax
    call   scr_pop
    mov    edi, eax
    call   scr_pop
    mov    ecx, eax
    call   scr_pop
    mov    ebx, eax
    mov    eax, edi
    call   img_fmt_arg
    call   img_rect_from_stack
    call   img_parse_tol_inline
    test   eax, eax
    jz     siwic_done
    call   bmp_load_target
    test   eax, eax
    jz     siwic_done
    call   screen_capture
    test   eax, eax
    jz     siwic_done
siwic_loop:
    call   inline_match
    mov    eax, offset img_inline_result
    call   img_parse
    cmp    dword ptr [img_found], 0
    jne    siwic_found
    sub    ebp, 50
    jbe    siwic_release
    push   50
    call   Sleep
    jmp    siwic_loop
siwic_found:
    call   screen_release
    mov    eax, [img_w]
    shr    eax, 1
    add    eax, [img_x]
    mov    ebx, eax
    mov    eax, [img_h]
    shr    eax, 1
    add    eax, [img_y]
    push   eax
    push   ebx
    call   SetCursorPos
    call   sc_click
    jmp    siwic_done
siwic_release:
    call   screen_release
siwic_done:
    popad
    ret

; ===========================================================================
;  WINDOW-NAV / PROCESS-LAUNCH primitives (cf22 Phase 3B, DLL-free)
;    winactivate ( str -- )       FindWindowA + SetForegroundWindow
;    winwait     ( str ms -- )    poll FindWindowA until found/timeout, activate
;    run         ( str -- )       CreateProcessA (detached), close handles
; ===========================================================================
.data
; script strings aren't NUL-terminated; sc_copy_str stages them here + '\0'
sc_str_buf         db  256 dup (0)
sc_si              dd  44 dup (0)     ; STARTUPINFO (oversized, harmless)
sc_pi              dd  4  dup (0)     ; PROCESS_INFORMATION

.code
; sc_copy_str (eax=src ptr, ecx=src len) — copy into sc_str_buf + NUL, cap 255
sc_copy_str:
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    esi, eax
    mov    edi, offset sc_str_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    ret

; winactivate ( str -- )
sc_winact:
    pushad
    call   scr_pop                           ; len
    mov    ecx, eax
    call   scr_pop                           ; ptr
    or     ecx, ecx
    jz     sc_winact_done
    call   sc_copy_str
    push   offset sc_str_buf
    push   0
    call   FindWindowA
    or     eax, eax
    jz     sc_winact_done
    push   eax
    call   SetForegroundWindow
sc_winact_done:
    popad
    ret

; winwait ( str ms -- )
sc_winwait:
    pushad
    call   scr_pop                           ; ms
    mov    ebx, eax
    call   scr_pop                           ; len
    mov    ecx, eax
    call   scr_pop                           ; ptr
    or     ecx, ecx
    jz     sc_winwait_done
    call   sc_copy_str
sc_winwait_loop:
    push   offset sc_str_buf
    push   0
    call   FindWindowA
    or     eax, eax
    jnz    sc_winwait_found
    sub    ebx, 50
    jbe    sc_winwait_done                   ; timeout
    push   50
    call   Sleep
    jmp    sc_winwait_loop
sc_winwait_found:
    push   eax
    call   SetForegroundWindow
sc_winwait_done:
    popad
    ret

; run ( str -- ) — CreateProcessA, detached, no handle inheritance
sc_run:
    pushad
    call   scr_pop                           ; len
    mov    ecx, eax
    call   scr_pop                           ; ptr
    or     ecx, ecx
    jz     sc_run_done
    call   sc_copy_str
    mov    edi, offset sc_si
    mov    ecx, 44
    xor    eax, eax
    rep    stosd
    mov    dword ptr [sc_si+0], 68            ; STARTUPINFO.cb
    push   offset sc_pi
    push   offset sc_si
    push   0                                  ; lpCurrentDirectory
    push   0                                  ; lpEnvironment
    push   0                                  ; dwCreationFlags
    push   0                                  ; bInheritHandles = FALSE
    push   0                                  ; lpThreadAttributes
    push   0                                  ; lpProcessAttributes
    push   offset sc_str_buf                  ; lpCommandLine
    push   0                                  ; lpApplicationName
    call   CreateProcessA
    or     eax, eax
    jz     sc_run_done
    push   dword ptr [sc_pi+0]                ; hProcess
    call   CloseHandle
    push   dword ptr [sc_pi+4]                ; hThread
    call   CloseHandle
sc_run_done:
    popad
    ret

; ===========================================================================
;  DEBUG LOG + TEST-FRAMEWORK primitives (cf22 Direction B).
;    open_dbg_log opens lal4s_debug.log (CREATE_ALWAYS). dbg_* helpers no-op
;    until it succeeds. The test framework (tname/tpass/tfail/tsummary) and the
;    expect_* assertions write PASS/FAIL lines a runner can grep. These are the
;    only primitives whose sole effect is log output — hence the log lift.
; ===========================================================================
.data
dbg_handle          dd  0FFFFFFFFh         ; INVALID_HANDLE_VALUE until opened
dbg_buf             db  16 dup (0)         ; hex8 scratch
dbg_written         dd  0                  ; WriteFile lpBytesWritten
dbg_hex_tab         db  '0123456789ABCDEF'
dbg_crlf            db  0Dh, 0Ah, 0
dbg_file            db  'lal4s_debug.log', 0
dbg_msg_open        db  '=== lal4s debug log opened ===', 0Dh, 0Ah
dbg_msg_open_len    equ $ - dbg_msg_open

; --- test framework state ---
current_test_name   db  64 dup (0)
current_test_failed dd  0                  ; reset by tname, raised by tfail/expect_*
current_test_active dd  0                  ; 1 between tname and tpass/tfail/tsummary
tests_pass_count    dd  0
tests_fail_count    dd  0
test_str_buf        db  256 dup (0)
ep_x                dd  0                  ; expect_pixel scratch (ep_tol reused from above)
ep_y                dd  0
ep_want             dd  0
ep_got              dd  0
; --- test framework log strings ---
dbg_msg_test_open    db  '[TEST ', 0
dbg_msg_test_mid     db  '] ', 0
dbg_msg_test_begin_w db  'BEGIN', 0
dbg_msg_test_pass_w  db  'PASS', 0
dbg_msg_test_fail_w  db  'FAIL: ', 0
dbg_msg_test_run     db  0Dh, 0Ah, '[TEST RUN] ', 0
dbg_msg_test_p       db  ' pass, ', 0
dbg_msg_test_f       db  ' fail', 0Dh, 0Ah, 0
dbg_msg_eipx_miss    db  'expect_pixel mismatch x=', 0
dbg_msg_eipx_y       db  ' y=', 0
dbg_msg_eipx_got     db  ' got=', 0
dbg_msg_eipx_want    db  ' want=', 0
dbg_msg_eipx_tol     db  ' tol=', 0
dbg_msg_eimg_miss    db  'expect_img not found: ', 0
dbg_msg_ewin_miss    db  'expect_window not found: ', 0
dbg_msg_enimg_found  db  'expect_no_img found (should be absent): ', 0
dbg_msg_enwin_found  db  'expect_no_window found (should be absent): ', 0

.code
; ---------------------------------------------------------------------------
;  dbg log helpers — all preserve every register; no-op while dbg_handle = -1
; ---------------------------------------------------------------------------
open_dbg_log:
    push   0
    push   80h                 ; FILE_ATTRIBUTE_NORMAL
    push   2                   ; CREATE_ALWAYS
    push   0
    push   3                   ; FILE_SHARE_READ | FILE_SHARE_WRITE
    push   40000000h           ; GENERIC_WRITE
    push   offset dbg_file
    call   CreateFileA
    inc    eax
    jz     odl_fail            ; INVALID_HANDLE_VALUE (-1) → +1 = 0
    dec    eax
    mov    [dbg_handle], eax
    push   0
    push   offset dbg_written
    push   dbg_msg_open_len
    push   offset dbg_msg_open
    push   [dbg_handle]
    call   WriteFile
    push   [dbg_handle]
    call   FlushFileBuffers
odl_fail:
    ret

; dbg_writez — write ASCIIZ at edx; preserves all registers
dbg_writez:
    cmp    dword ptr [dbg_handle], 0FFFFFFFFh
    je     dwz_ret
    pushad
    mov    esi, edx
    xor    ecx, ecx
@@: cmp    byte ptr [esi+ecx], 0
    je     @f
    inc    ecx
    jmp    @b
@@: push   0
    push   offset dbg_written
    push   ecx
    push   edx
    push   [dbg_handle]
    call   WriteFile
    popad
dwz_ret:
    ret

; dbg_writehex8 — write eax as 8 hex digits; preserves all registers
dbg_writehex8:
    cmp    dword ptr [dbg_handle], 0FFFFFFFFh
    je     dwh_ret
    pushad
    mov    ebx, eax
    mov    edi, offset dbg_buf
    mov    ecx, 8
@@: rol    ebx, 4
    mov    edx, ebx
    and    edx, 0Fh
    mov    al, byte ptr [edx + dbg_hex_tab]
    mov    [edi], al
    inc    edi
    dec    ecx
    jnz    @b
    push   0
    push   offset dbg_written
    push   8
    push   offset dbg_buf
    push   [dbg_handle]
    call   WriteFile
    popad
dwh_ret:
    ret

; dbg_writecrlf — write CR LF; preserves all registers (esp. edx)
dbg_writecrlf:
    push   edx
    mov    edx, offset dbg_crlf
    call   dbg_writez
    pop    edx
    ; flush after each complete line so a reader tailing the log sees it live
    ; (without this, buffered writes + a stale on-disk file size hide everything
    ; after the boot banner while lal4s keeps the handle open).
    cmp    dword ptr [dbg_handle], 0FFFFFFFFh
    je     dwcrlf_ret
    pushad
    push   [dbg_handle]
    call   FlushFileBuffers
    popad
dwcrlf_ret:
    ret

; dbg_writeN — write ecx bytes at edx; preserves all registers
dbg_writeN:
    cmp    dword ptr [dbg_handle], 0FFFFFFFFh
    je     dw_n_ret
    or     ecx, ecx
    jz     dw_n_ret
    pushad
    push   0
    push   offset dbg_written
    push   ecx
    push   edx
    push   [dbg_handle]
    call   WriteFile
    popad
dw_n_ret:
    ret

; ---------------------------------------------------------------------------
;  Test framework
; ---------------------------------------------------------------------------
; test_log_prefix — write "[TEST <name>] "
test_log_prefix:
    pushad
    mov    edx, offset dbg_msg_test_open
    call   dbg_writez
    mov    edx, offset current_test_name
    call   dbg_writez
    mov    edx, offset dbg_msg_test_mid
    call   dbg_writez
    popad
    ret

; tname ( str -- ) — begin a test; implicit PASS for a prior still-active test
sc_tname:
    pushad
    cmp    dword ptr [current_test_active], 0
    je     sct_no_prev
    cmp    dword ptr [current_test_failed], 0
    jne    sct_prev_done
    inc    dword ptr [tests_pass_count]
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_pass_w
    call   dbg_writez
    call   dbg_writecrlf
sct_prev_done:
    mov    dword ptr [current_test_active], 0
sct_no_prev:
    call   scr_pop                              ; len
    mov    ecx, eax
    call   scr_pop                              ; ptr
    or     ecx, ecx
    jz     sct_done
    cmp    ecx, 63
    jbe    @f
    mov    ecx, 63
@@:
    mov    esi, eax
    mov    edi, offset current_test_name
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    mov    dword ptr [current_test_failed], 0
    mov    dword ptr [current_test_active], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_begin_w
    call   dbg_writez
    call   dbg_writecrlf
sct_done:
    popad
    ret

; tpass ( -- ) — explicit success (noop if already failed / no active test)
sc_tpass:
    cmp    dword ptr [current_test_active], 0
    je     sctp_noop
    cmp    dword ptr [current_test_failed], 0
    jne    sctp_close
    pushad
    inc    dword ptr [tests_pass_count]
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_pass_w
    call   dbg_writez
    call   dbg_writecrlf
    popad
sctp_close:
    mov    dword ptr [current_test_active], 0
sctp_noop:
    ret

; tfail ( str -- ) — mark current test failed with a reason
sc_tfail:
    pushad
    call   scr_pop                              ; len
    mov    ecx, eax
    call   scr_pop                              ; ptr
    mov    ebx, eax                             ; ebx = reason ptr
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    mov    dword ptr [current_test_active], 0
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    or     ecx, ecx
    jz     stf_log_done
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@:
    mov    esi, ebx
    mov    edi, offset test_str_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    mov    edx, offset test_str_buf
    call   dbg_writez
stf_log_done:
    call   dbg_writecrlf
    popad
    ret

; tsummary ( -- ) — close any active test, then log "[TEST RUN] N pass, M fail"
sc_tsummary:
    pushad
    cmp    dword ptr [current_test_active], 0
    je     scts_log
    cmp    dword ptr [current_test_failed], 0
    jne    scts_close
    inc    dword ptr [tests_pass_count]
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_pass_w
    call   dbg_writez
    call   dbg_writecrlf
scts_close:
    mov    dword ptr [current_test_active], 0
scts_log:
    mov    edx, offset dbg_msg_test_run
    call   dbg_writez
    mov    eax, [tests_pass_count]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_test_p
    call   dbg_writez
    mov    eax, [tests_fail_count]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_test_f
    call   dbg_writez
    popad
    ret

; ---------------------------------------------------------------------------
;  expect_* assertions
; ---------------------------------------------------------------------------
; expect_pixel ( x y color tol -- )
sc_expect_pixel:
    pushad
    call   scr_pop                              ; tol
    mov    [ep_tol], eax
    call   scr_pop                              ; want color (BGR)
    mov    [ep_want], eax
    call   scr_pop                              ; y
    mov    [ep_y], eax
    call   scr_pop                              ; x
    mov    [ep_x], eax
    push   0
    call   GetDC
    or     eax, eax
    jz     sxp_fail
    mov    ebx, eax                             ; hdc
    push   [ep_y]
    push   [ep_x]
    push   ebx
    call   GetPixel
    mov    [ep_got], eax
    push   ebx
    push   0
    call   ReleaseDC
    mov    eax, [ep_got]
    mov    edx, [ep_want]
    call   pixel_within_tol                     ; eax=1 OK, 0 miss
    or     eax, eax
    jnz    sxp_pass
sxp_fail:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_eipx_miss
    call   dbg_writez
    mov    eax, [ep_x]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eipx_y
    call   dbg_writez
    mov    eax, [ep_y]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eipx_got
    call   dbg_writez
    mov    eax, [ep_got]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eipx_want
    call   dbg_writez
    mov    eax, [ep_want]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eipx_tol
    call   dbg_writez
    mov    eax, [ep_tol]
    call   dbg_writehex8
    call   dbg_writecrlf
sxp_pass:
    popad
    ret

; expect_img ( "fname" tol -- ) — inline BMP search; FAIL if not on screen
sc_expect_img:
    pushad
    call   scr_pop                              ; tol
    mov    edi, eax
    call   scr_pop                              ; len
    mov    ecx, eax
    call   scr_pop                              ; ptr
    mov    ebx, eax
    mov    eax, edi
    call   img_fmt_arg
    call   img_rect_fullscreen
    call   img_search_inline
    call   img_parse
    cmp    dword ptr [img_found], 0
    jne    seim_pass
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_eimg_miss
    call   dbg_writez
    mov    edx, offset img_arg_buf
    call   dbg_writez
    call   dbg_writecrlf
seim_pass:
    popad
    ret

; expect_window ( "title" -- ) — FAIL if FindWindowA(title) misses
sc_expect_window:
    pushad
    call   scr_pop                              ; len
    mov    ecx, eax
    call   scr_pop                              ; ptr
    or     ecx, ecx
    jz     sew_fail
    call   sc_copy_str                          ; into sc_str_buf
    push   offset sc_str_buf
    push   0
    call   FindWindowA
    or     eax, eax
    jnz    sew_pass
sew_fail:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_ewin_miss
    call   dbg_writez
    mov    edx, offset sc_str_buf
    call   dbg_writez
    call   dbg_writecrlf
sew_pass:
    popad
    ret

; expect_no_img ( "fname" tol -- ) — inverse; PASS when image absent, FAIL if found
sc_expect_no_img:
    pushad
    call   scr_pop                              ; tol
    mov    edi, eax
    call   scr_pop                              ; len
    mov    ecx, eax
    call   scr_pop                              ; ptr
    mov    ebx, eax
    mov    eax, edi
    call   img_fmt_arg
    call   img_rect_fullscreen
    call   img_search_inline
    call   img_parse
    cmp    dword ptr [img_found], 0
    je     senim_pass                           ; not found → pass
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_enimg_found
    call   dbg_writez
    mov    edx, offset img_arg_buf
    call   dbg_writez
    call   dbg_writecrlf
senim_pass:
    popad
    ret

; expect_no_window ( "title" -- ) — inverse; PASS when absent, FAIL if found
sc_expect_no_window:
    pushad
    call   scr_pop                              ; len
    mov    ecx, eax
    call   scr_pop                              ; ptr
    or     ecx, ecx
    jz     senw_pass                            ; empty title → degenerate pass
    call   sc_copy_str                          ; into sc_str_buf
    push   offset sc_str_buf
    push   0
    call   FindWindowA
    or     eax, eax
    jz     senw_pass                            ; not found → pass
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_enwin_found
    call   dbg_writez
    mov    edx, offset sc_str_buf
    call   dbg_writez
    call   dbg_writecrlf
senw_pass:
    popad
    ret

; ===========================================================================
;  EnumWindows / findwin_substr group (cf22).
;    findwin_substr ( "substr" -- hwnd )  — first top-level window whose title
;      CONTAINS substr (0 if none). The _in inverse assertions restrict an image
;      search to a substring-matched window's rect. enumwins/enumwinsh dump the
;      window list to the log.
; ===========================================================================
.data
ews_include_all     dd  0                 ; 0 = visible+titled only; 1 = all
ews_count           dd  0
fws_substr_buf      db  256 dup (0)
fws_substr_len      dd  0
fws_title_buf       db  512 dup (0)       ; GetWindowTextA scratch (writes [+511])
fws_match_hwnd      dd  0
nii_rect            dd  4 dup (0)          ; GetWindowRect L,T,R,B
nii_fname_buf       db  128 dup (0)
nii_fname_len       dd  0
winctrls_class_buf  db  128 dup (0)       ; GetClassNameA scratch (enum_wins_proc)
dbg_msg_nii_found   db  'expect_no_img_in: image PRESENT in matched window: ', 0
dbg_msg_nii_in_win  db  ' (in window="', 0
dbg_msg_nwi_found   db  'expect_no_window_in: matching window EXISTS for substring: ', 0
dbg_msg_nwi_title   db  ' (actual title="', 0
dbg_msg_ect_textend db  '"', 0
dbg_msg_ews_start   db  '[WINS] start', 0
dbg_msg_ews_e_hwnd  db  '  hwnd=', 0
dbg_msg_ews_e_class db  '  class="', 0
dbg_msg_ews_e_title db  '"  title="', 0
dbg_msg_ews_e_end   db  '"', 0
dbg_msg_ews_end_pre db  '[WINS] end - count=', 0
dbg_msg_ews_end_post db ' visible top-level windows', 0

.code
; enum_win_proc — EnumWindows callback: first title CONTAINING fws_substr_buf
; sets fws_match_hwnd and stops (returns FALSE). Naive case-sensitive substring.
enum_win_proc PROC hwndTop :DWORD, lParam :DWORD
    pushad
    push   511
    push   offset fws_title_buf
    push   [hwndTop]
    call   GetWindowTextA
    mov    byte ptr [fws_title_buf + 511], 0
    cmp    byte ptr [fws_title_buf], 0
    je     ewp_continue                         ; skip empty titles
    mov    ecx, [fws_substr_len]
    or     ecx, ecx
    jz     ewp_continue                         ; empty needle = nothing
    mov    esi, offset fws_title_buf
ewp_scan:
    cmp    byte ptr [esi], 0
    je     ewp_continue                         ; haystack exhausted
    push   ecx
    mov    eax, esi
    mov    ebx, offset fws_substr_buf
ewp_cmp:
    mov    dl, byte ptr [eax]
    cmp    dl, byte ptr [ebx]
    jne    ewp_pop_no
    or     dl, dl
    je     ewp_pop_no
    inc    eax
    inc    ebx
    dec    ecx
    jnz    ewp_cmp
    pop    ecx                                  ; full match
    mov    eax, [hwndTop]
    mov    [fws_match_hwnd], eax
    popad
    xor    eax, eax                             ; FALSE — stop enumeration
    ret
ewp_pop_no:
    pop    ecx
    inc    esi
    jmp    ewp_scan
ewp_continue:
    popad
    mov    eax, 1                               ; TRUE — keep enumerating
    ret
enum_win_proc ENDP

; findwin_substr ( "substr" -- hwnd ) — 0 if no title contains substr
sc_findwin_substr:
    pushad
    mov    dword ptr [fws_match_hwnd], 0
    call   scr_pop                              ; len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [fws_substr_len], ecx
    call   scr_pop                              ; ptr
    mov    esi, eax
    mov    edi, offset fws_substr_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    push   0
    push   offset enum_win_proc
    call   EnumWindows
    mov    eax, [fws_match_hwnd]
    call   scr_push                             ; result hwnd
    popad
    ret

; expect_no_img_in ( "title_substr" "fname" tol -- )
;   PASS when the image is NOT visible within the bounds of a window whose title
;   contains title_substr. Vacuous PASS if no window matches.
sc_expect_no_img_in:
    pushad
    mov    dword ptr [fws_match_hwnd], 0
    call   scr_pop                              ; tol
    mov    [ep_tol], eax
    call   scr_pop                              ; fname len
    mov    ecx, eax
    cmp    ecx, 127
    jbe    @f
    mov    ecx, 127
@@: mov    [nii_fname_len], ecx
    call   scr_pop                              ; fname ptr
    mov    esi, eax
    mov    edi, offset nii_fname_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    call   scr_pop                              ; substr len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [fws_substr_len], ecx
    call   scr_pop                              ; substr ptr
    or     ecx, ecx
    jz     snii_pass                            ; empty substr → vacuous PASS
    mov    esi, eax
    mov    edi, offset fws_substr_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    ; stage substr into sc_str_buf for the FAIL diagnostic
    mov    esi, offset fws_substr_buf
    mov    edi, offset sc_str_buf
    mov    ecx, [fws_substr_len]
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    push   0
    push   offset enum_win_proc
    call   EnumWindows
    mov    eax, [fws_match_hwnd]
    or     eax, eax
    jz     snii_pass                            ; no window match → vacuous PASS
    push   offset nii_rect
    push   eax
    call   GetWindowRect
    mov    eax, [nii_rect + 0]
    mov    [img_left], eax
    mov    eax, [nii_rect + 4]
    mov    [img_top], eax
    mov    eax, [nii_rect + 8]
    mov    [img_right], eax
    mov    eax, [nii_rect + 12]
    mov    [img_bottom], eax
    mov    eax, [ep_tol]
    mov    ebx, offset nii_fname_buf
    mov    ecx, [nii_fname_len]
    call   img_fmt_arg
    call   img_search_inline
    call   img_parse
    cmp    dword ptr [img_found], 0
    je     snii_pass                            ; not found → PASS
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_nii_found
    call   dbg_writez
    mov    edx, offset img_arg_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_nii_in_win
    call   dbg_writez
    mov    edx, offset sc_str_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_ect_textend
    call   dbg_writez
    call   dbg_writecrlf
snii_pass:
    popad
    ret

; expect_no_window_in ( "title_substr" -- )
;   PASS when NO top-level window title contains substr; FAIL if one does.
sc_expect_no_window_in:
    pushad
    mov    dword ptr [fws_match_hwnd], 0
    call   scr_pop                              ; len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [fws_substr_len], ecx
    call   scr_pop                              ; ptr
    or     ecx, ecx
    jz     senwi_pass                           ; empty substr → degenerate PASS
    mov    esi, eax
    mov    edi, offset fws_substr_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    mov    esi, offset fws_substr_buf
    mov    edi, offset sc_str_buf
    mov    ecx, [fws_substr_len]
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    push   0
    push   offset enum_win_proc
    call   EnumWindows
    mov    eax, [fws_match_hwnd]
    or     eax, eax
    jz     senwi_pass                           ; no match → PASS (target absent)
    push   eax                                  ; save match hwnd
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_nwi_found
    call   dbg_writez
    mov    edx, offset fws_substr_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_nwi_title
    call   dbg_writez
    pop    eax
    push   255
    push   offset sc_str_buf
    push   eax
    call   GetWindowTextA
    mov    byte ptr [sc_str_buf + 255], 0
    mov    edx, offset sc_str_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_ect_textend
    call   dbg_writez
    call   dbg_writecrlf
senwi_pass:
    popad
    ret

; enum_wins_proc — EnumWindows callback for enumwins/enumwinsh: log one line per
; window (hwnd/class/title). enumwinsh sets ews_include_all=1 to skip filters.
enum_wins_proc PROC hwndTop :DWORD, lParam :DWORD
    pushad
    cmp    dword ptr [ews_include_all], 0
    jne    ewsp_skip_visible
    push   [hwndTop]
    call   IsWindowVisible
    test   eax, eax
    jz     ewsp_continue
ewsp_skip_visible:
    push   511
    push   offset fws_title_buf
    push   [hwndTop]
    call   GetWindowTextA
    mov    byte ptr [fws_title_buf + 511], 0
    cmp    dword ptr [ews_include_all], 0
    jne    ewsp_skip_title_check
    cmp    byte ptr [fws_title_buf], 0
    je     ewsp_continue                        ; skip nameless windows
ewsp_skip_title_check:
    push   128
    push   offset winctrls_class_buf
    push   [hwndTop]
    call   GetClassNameA
    mov    byte ptr [winctrls_class_buf + 127], 0
    mov    edx, offset dbg_msg_ews_e_hwnd
    call   dbg_writez
    mov    eax, [hwndTop]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_ews_e_class
    call   dbg_writez
    mov    edx, offset winctrls_class_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_ews_e_title
    call   dbg_writez
    mov    edx, offset fws_title_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_ews_e_end
    call   dbg_writez
    call   dbg_writecrlf
    inc    dword ptr [ews_count]
ewsp_continue:
    popad
    mov    eax, 1                               ; TRUE — keep enumerating
    ret
enum_wins_proc ENDP

; enumwins ( -- ) — dump visible titled top-level windows to the log
sc_enumwins:
    pushad
    mov    dword ptr [ews_include_all], 0
    jmp    ews_run
; enumwinsh ( -- ) — like enumwins but includes hidden/nameless windows
sc_enumwinsh:
    pushad
    mov    dword ptr [ews_include_all], 1
ews_run:
    mov    dword ptr [ews_count], 0
    mov    edx, offset dbg_msg_ews_start
    call   dbg_writez
    call   dbg_writecrlf
    push   0
    push   offset enum_wins_proc
    call   EnumWindows
    mov    edx, offset dbg_msg_ews_end_pre
    call   dbg_writez
    mov    eax, [ews_count]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_ews_end_post
    call   dbg_writez
    call   dbg_writecrlf
    popad
    ret

; ===========================================================================
;  CHILD-CONTROL TEXT / STATUS BAR / WINCTRLS group (cf22, verbatim).
;    expect_ctrl_text[_in], expect_no_ctrl_text_in, expect_any_ctrl_text[_in],
;    expect_statusbar[_in], expect_no_statusbar_in, winctrls[_in].
;    Reads native Win32 controls via FindWindowExA / EnumChildWindows +
;    WM_GETTEXT / SB_GETTEXTA (SendMessageTimeout). Keeps the [ECT]/[EAC]/
;    [ESB]/[CTRLS] trace logging (the log channel exists). Shares enum_win_proc
;    (title-substring finder) already lifted above.
; ===========================================================================
.data
ctrl_class_buf   db  128 dup (0)
ctrl_exp_buf     db  256 dup (0)
ctrl_exp_len     dd  0
ctrl_text_buf    db  2048 dup (0)
ctrl_save_byte       db  0
ect_parent           dd  0
ect_child            dd  0
eac_count            dd  0
eac_last_match       dd  0
statusbar_class_buf db 'msctls_statusbar32', 0
statusbar_part      dd  0
winctrls_text_buf    db  512 dup (0)
winctrls_smto_result dd  0
esb_sb_ret           dd  0          ; SMTO lpdwResult — output ignored, non-NULL required
esb_wm_ret           dd  0          ; SMTO lpdwResult — output ignored, non-NULL required
dbg_msg_ect_pre      db  '[ECT] title="', 0
dbg_msg_ect_p1       db  '" parent=', 0
dbg_msg_ect_p2       db  ' class="', 0
dbg_msg_ect_p3       db  '" child=', 0
dbg_msg_ect_p4       db  ' got="', 0
dbg_msg_ect_p5       db  '" want="', 0
dbg_msg_ect_p6       db  '" ', 0
dbg_msg_ect_pass     db  'PASS', 0
dbg_msg_ect_fail_w   db  'FAIL=win', 0
dbg_msg_ect_fail_c   db  'FAIL=ctl', 0
dbg_msg_ect_fail_t   db  'FAIL=text', 0
dbg_msg_ect_winmiss  db  'expect_ctrl_text: window not found: ', 0
dbg_msg_ect_ctlmiss  db  'expect_ctrl_text: control class not found: ', 0
dbg_msg_ect_textmiss db  'expect_ctrl_text: text not found, got="', 0
dbg_msg_nct_t_found  db  'expect_no_ctrl_text_in: needle PRESENT in matched control, got="', 0
dbg_msg_eac_hdr      db  '[EAC] title="', 0
dbg_msg_eac_class    db  '" class="', 0
dbg_msg_eac_want     db  '" want="', 0
dbg_msg_eac_parent   db  '" parent=', 0
dbg_msg_eac_child    db  '  child=', 0
dbg_msg_eac_got      db  '  got="', 0
dbg_msg_eac_match    db  '"  MATCH', 0
dbg_msg_eac_nomatch  db  '"  no-match', 0
dbg_msg_eac_pass     db  '[EAC] PASS — matched at child=', 0
dbg_msg_eac_pass2    db  ' (after scanning ', 0
dbg_msg_eac_pass3    db  ' children)', 0
dbg_msg_eac_t_winmiss db 'expect_any_ctrl_text: window not found: ', 0
dbg_msg_eac_t_ctlmiss db 'expect_any_ctrl_text: no child of class: ', 0
dbg_msg_eac_t_textmiss db 'expect_any_ctrl_text: needle not found in ', 0
dbg_msg_eac_t_txt2    db ' children', 0
dbg_msg_eac_failwin  db  '[EAC] FAIL=win', 0
dbg_msg_eac_failctl  db  '[EAC] FAIL=ctl — no child of class', 0
dbg_msg_eac_failtxt  db  '[EAC] FAIL=text — scanned ', 0
dbg_msg_eac_failtxt2 db  ' children, none matched', 0
dbg_msg_esb_hdr      db  '[ESB] title="', 0
dbg_msg_esb_part     db  '" part=', 0
dbg_msg_esb_parent   db  ' parent=', 0
dbg_msg_esb_sbar     db  ' sbar=', 0
dbg_msg_esb_got      db  ' got="', 0
dbg_msg_esb_want     db  '" want="', 0
dbg_msg_esb_tail     db  '" ', 0
dbg_msg_esb_fail_s   db  'FAIL=sbar', 0
dbg_msg_esb_fail_t   db  'FAIL=text', 0
dbg_msg_esb_t_winmiss db 'expect_statusbar: window not found: ', 0
dbg_msg_esb_t_sbarmiss db 'expect_statusbar: no msctls_statusbar32 child of: ', 0
dbg_msg_esb_t_textmiss db 'expect_statusbar: text not found in part, got="', 0
dbg_msg_nsb_t_found    db 'expect_no_statusbar_in: needle PRESENT in matched status bar, got="', 0
dbg_msg_wc_pre       db  '[CTRLS] title="', 0
dbg_msg_wc_parent    db  '" parent=', 0
dbg_msg_wc_child     db  '  child=', 0
dbg_msg_wc_class     db  '  class="', 0
dbg_msg_wc_text      db  '"  text="', 0
dbg_msg_wc_end       db  '"', 0
dbg_msg_wc_winmiss   db  '" (window not found)', 0

.code
; Per-call diagnostic line — invoked from every exit path.
; edx = pointer to outcome ASCIIZ (PASS / FAIL=win / FAIL=ctl / FAIL=text).
; Logs: title, parent hwnd, class, child hwnd, got text, want text, outcome.
ect_trace:
    pushad
    mov    ebp, edx                             ; stash outcome ptr (in-frame)
    mov    edx, offset dbg_msg_ect_pre
    call   dbg_writez
    mov    edx, offset sc_str_buf               ; title
    call   dbg_writez
    mov    edx, offset dbg_msg_ect_p1
    call   dbg_writez
    mov    eax, [ect_parent]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_ect_p2
    call   dbg_writez
    mov    edx, offset ctrl_class_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_ect_p3
    call   dbg_writez
    mov    eax, [ect_child]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_ect_p4
    call   dbg_writez
    mov    edx, offset ctrl_text_buf            ; WM_GETTEXT result
    call   dbg_writez
    mov    edx, offset dbg_msg_ect_p5
    call   dbg_writez
    mov    edx, offset ctrl_exp_buf             ; needle
    call   dbg_writez
    mov    edx, offset dbg_msg_ect_p6
    call   dbg_writez
    mov    edx, ebp                             ; outcome
    call   dbg_writez
    call   dbg_writecrlf
    popad
    ret

; expect_ctrl_text ( "title" "class" "expected" -- )
; FindWindowA(title) -> FindWindowExA(hwnd, class) -> WM_GETTEXT.
; Substring-matches "expected" in the returned text. Reads native
; Win32 controls without OCR. Three FAIL paths report which step
; failed (window / class / text content). Every exit path also
; emits a [ECT] trace line with hwnds + all 3 strings + outcome.
; expect_ctrl_text_in ( "title_substr" "class" "expected" -- )
; Substring-match variant of expect_ctrl_text. Locates the parent
; window via EnumWindows + GetWindowTextA instead of exact
; FindWindowA. Use when the window's title fluctuates per tab /
; locale / version, but its class is stable.
; Shares the FindWindowExA + WM_GETTEXT + substring-match body
; with expect_ctrl_text via sct_have_parent.
; expect_no_ctrl_text_in ( "title_substr" "class" "expected" -- )
; Inverse of expect_ctrl_text_in: PASS when the needle is NOT
; present in the matched control's text. Vacuously PASSes when
; the substring-matched window doesn't exist OR has no child of
; the named class (target absent = needle absent). FAILs only when
; the lookup succeeds AND the needle is found.
; Mirrors expect_no_window / expect_no_img semantics.
sc_expect_no_ctrl_text_in:
    pushad
    mov    dword ptr [ect_parent], 0
    mov    dword ptr [ect_child],  0
    mov    byte  ptr [ctrl_text_buf], 0
    mov    dword ptr [fws_match_hwnd], 0

    ; --- pop expected: copy to ctrl_exp_buf, cap at 255 ---
    call   scr_pop
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [ctrl_exp_len], ecx
    call   scr_pop
    mov    esi, eax
    mov    edi, offset ctrl_exp_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    ; --- pop class: copy to ctrl_class_buf, cap at 127 ---
    call   scr_pop
    mov    ecx, eax
    cmp    ecx, 127
    jbe    @f
    mov    ecx, 127
@@: call   scr_pop
    mov    esi, eax
    mov    edi, offset ctrl_class_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    ; --- pop substr: copy to fws_substr_buf, cap at 255 ---
    call   scr_pop
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [fws_substr_len], ecx
    call   scr_pop
    mov    esi, eax
    mov    edi, offset fws_substr_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    mov    esi, offset fws_substr_buf
    mov    edi, offset sc_str_buf
    mov    ecx, [fws_substr_len]
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    push   0
    push   offset enum_win_proc
    call   EnumWindows

    mov    eax, [fws_match_hwnd]
    or     eax, eax
    jz     snct_pass                        ; window absent → PASS (target absent)
    mov    [ect_parent], eax

    push   0
    push   offset ctrl_class_buf
    push   0
    push   eax
    call   FindWindowExA
    or     eax, eax
    jz     snct_pass                        ; no child of class → PASS
    mov    [ect_child], eax
    mov    ebx, eax

    push   offset ctrl_text_buf
    push   2047
    push   0Dh                              ; WM_GETTEXT
    push   ebx
    call   SendMessageA
    mov    byte ptr [ctrl_text_buf + 2047], 0

    mov    ecx, [ctrl_exp_len]
    call   ctrl_substr_match
    or     eax, eax
    jz     snct_pass                        ; needle absent → PASS
    ; needle was FOUND → FAIL (inverse semantics)
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_nct_t_found
    call   dbg_writez
    mov    edx, offset ctrl_text_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_ect_textend
    call   dbg_writez
    call   dbg_writecrlf
snct_pass:
    popad
    ret

; expect_ctrl_text_in ( "title_substr" "class" "expected" -- )
; Substring-match variant of expect_ctrl_text. Locates the parent
; window via EnumWindows + GetWindowTextA instead of exact
; FindWindowA. Use when the window's title fluctuates per tab /
; locale / version, but its class is stable.
; Shares the FindWindowExA + WM_GETTEXT + substring-match body
; with expect_ctrl_text via sct_have_parent.
sc_expect_ctrl_text_in:
    pushad
    mov    dword ptr [ect_parent], 0
    mov    dword ptr [ect_child],  0
    mov    byte  ptr [ctrl_text_buf], 0
    mov    dword ptr [fws_match_hwnd], 0

    ; --- pop expected: copy to ctrl_exp_buf, cap at 255 ---
    call   scr_pop                              ; len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [ctrl_exp_len], ecx
    call   scr_pop                              ; ptr
    mov    esi, eax
    mov    edi, offset ctrl_exp_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    ; --- pop class: copy to ctrl_class_buf, cap at 127 ---
    call   scr_pop                              ; len
    mov    ecx, eax
    cmp    ecx, 127
    jbe    @f
    mov    ecx, 127
@@: call   scr_pop                              ; ptr
    mov    esi, eax
    mov    edi, offset ctrl_class_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    ; --- pop substr: copy to fws_substr_buf, cap at 255 ---
    call   scr_pop                              ; len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [fws_substr_len], ecx
    call   scr_pop                              ; ptr
    mov    esi, eax
    mov    edi, offset fws_substr_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    ; pre-fill sc_str_buf with substr so FAIL=win path's log is sensible
    mov    esi, offset fws_substr_buf
    mov    edi, offset sc_str_buf
    mov    ecx, [fws_substr_len]
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    ; EnumWindows(enum_win_proc, 0) — populates fws_match_hwnd
    push   0
    push   offset enum_win_proc
    call   EnumWindows

    mov    eax, [fws_match_hwnd]
    or     eax, eax
    jz     sct_fail_win
    mov    [ect_parent], eax

    ; Re-fetch the matched window's full title into sc_str_buf so
    ; the [ECT] trace shows the actual title, not the substring.
    push   255
    push   offset sc_str_buf
    push   dword ptr [ect_parent]
    call   GetWindowTextA
    mov    byte ptr [sc_str_buf + 255], 0

    jmp    sct_have_parent

sc_expect_ctrl_text:
    pushad
    ; Reset per-call state so a previous call's hwnds/text don't
    ; leak into this trace when we fail early.
    mov    dword ptr [ect_parent], 0
    mov    dword ptr [ect_child],  0
    mov    byte ptr  [ctrl_text_buf], 0
    ; --- pop expected: copy to ctrl_exp_buf, cap at 255 ---
    call   scr_pop                              ; len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [ctrl_exp_len], ecx
    call   scr_pop                              ; ptr
    mov    esi, eax
    mov    edi, offset ctrl_exp_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    ; --- pop class: copy to ctrl_class_buf, cap at 127 ---
    call   scr_pop                              ; len
    mov    ecx, eax
    cmp    ecx, 127
    jbe    @f
    mov    ecx, 127
@@: call   scr_pop                              ; ptr
    mov    esi, eax
    mov    edi, offset ctrl_class_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    ; --- pop title: copy into sc_str_buf via sc_copy_str ---
    call   scr_pop                              ; len
    mov    ecx, eax
    call   scr_pop                              ; ptr
    call   sc_copy_str

    ; FindWindowA(NULL, sc_str_buf) -> parent hwnd
    push   offset sc_str_buf
    push   0
    call   FindWindowA
    or     eax, eax
    jz     sct_fail_win
    mov    [ect_parent], eax

sct_have_parent:
    ; Shared entry point: expect_ctrl_text_in jumps here after
    ; substring lookup. By that point ect_parent is set and
    ; sc_str_buf holds the actual matched title (for trace).
    ; FindWindowExA(parent, 0, ctrl_class_buf, 0) -> child hwnd
    push   0                                    ; lpszWindow (any)
    push   offset ctrl_class_buf                ; lpszClass
    push   0                                    ; hwndChildAfter
    push   dword ptr [ect_parent]               ; hWndParent
    call   FindWindowExA
    or     eax, eax
    jz     sct_fail_ctl
    mov    [ect_child], eax

    ; SendMessageA(hCtrl, WM_GETTEXT=0x0D, bufsize-1, &ctrl_text_buf)
    push   offset ctrl_text_buf
    push   2047
    push   0Dh                                  ; WM_GETTEXT
    push   eax
    call   SendMessageA
    mov    byte ptr [ctrl_text_buf + 2047], 0   ; defensive cap

    ; --- naive substring search: needle in ctrl_text_buf ---
    ;   esi = haystack scan ptr
    ;   ecx = needle length (cached for inner loop via push/pop)
    mov    esi, offset ctrl_text_buf
    mov    ecx, [ctrl_exp_len]
    or     ecx, ecx
    jz     sct_pass                             ; empty needle = trivial
sct_scan:
    cmp    byte ptr [esi], 0
    je     sct_fail_text                        ; haystack exhausted
    push   ecx                                  ; save needle length
    mov    eax, esi                             ; inner haystack ptr
    mov    ebx, offset ctrl_exp_buf             ; inner needle ptr
sct_cmp:
    mov    dl, byte ptr [eax]
    cmp    dl, byte ptr [ebx]
    jne    sct_pop_no_match
    or     dl, dl
    je     sct_pop_no_match                     ; haystack ran out mid-needle
    inc    eax
    inc    ebx
    dec    ecx
    jnz    sct_cmp
    pop    ecx                                  ; full match — restore & pass
    jmp    sct_pass
sct_pop_no_match:
    pop    ecx
    inc    esi
    jmp    sct_scan

sct_pass:
    mov    edx, offset dbg_msg_ect_pass
    call   ect_trace
    popad
    ret

sct_fail_win:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_ect_winmiss
    call   dbg_writez
    mov    edx, offset sc_str_buf
    call   dbg_writez
    call   dbg_writecrlf
    mov    edx, offset dbg_msg_ect_fail_w
    call   ect_trace
    popad
    ret

sct_fail_ctl:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_ect_ctlmiss
    call   dbg_writez
    mov    edx, offset ctrl_class_buf
    call   dbg_writez
    call   dbg_writecrlf
    mov    edx, offset dbg_msg_ect_fail_c
    call   ect_trace
    popad
    ret

sct_fail_text:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_ect_textmiss
    call   dbg_writez
    mov    edx, offset ctrl_text_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_ect_textend
    call   dbg_writez
    call   dbg_writecrlf
    mov    edx, offset dbg_msg_ect_fail_t
    call   ect_trace
    popad
    ret

; EnumChildWindows callback. Logs one child's hwnd + class + WM_GETTEXT
; result. Must preserve ebx/esi/edi/ebp (Win32 stdcall callee-save) and
; return non-zero to continue enumeration.
enum_ctrl_proc PROC hwndChild :DWORD, lParam :DWORD
    pushad
    ; GetClassNameA(hwnd, buf, 128)
    push   128
    push   offset winctrls_class_buf
    push   [hwndChild]
    call   GetClassNameA

    ; SendMessageTimeoutA(hwnd, WM_GETTEXT, 511, &buf,
    ;                     SMTO_ABORTIFHUNG=2, 200ms, &result)
    mov    byte ptr [winctrls_text_buf], 0
    push   offset winctrls_smto_result
    push   200
    push   2
    push   offset winctrls_text_buf
    push   511
    push   0Dh
    push   [hwndChild]
    call   SendMessageTimeoutA
    mov    byte ptr [winctrls_text_buf + 511], 0

    mov    edx, offset dbg_msg_wc_child
    call   dbg_writez
    mov    eax, [hwndChild]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_wc_class
    call   dbg_writez
    mov    edx, offset winctrls_class_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_wc_text
    call   dbg_writez
    mov    edx, offset winctrls_text_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_wc_end
    call   dbg_writez
    call   dbg_writecrlf
    popad
    mov    eax, 1                               ; TRUE — keep enumerating
    ret
enum_ctrl_proc ENDP
; Shared naive substring search used by expect_any_ctrl_text.
; In:  ecx = needle byte length
;      ctrl_exp_buf  (ASCIIZ, needle)
;      ctrl_text_buf (ASCIIZ, haystack)
; Out: eax = 1 if needle in haystack, 0 otherwise.
; Clobbers: eax, ebx, ecx, edx, esi.
ctrl_substr_match:
    or     ecx, ecx
    jz     csm_yes                              ; empty needle = trivial
    mov    esi, offset ctrl_text_buf
csm_scan:
    cmp    byte ptr [esi], 0
    je     csm_no
    push   ecx
    mov    eax, esi
    mov    ebx, offset ctrl_exp_buf
csm_cmp:
    mov    dl, byte ptr [eax]
    cmp    dl, byte ptr [ebx]
    jne    csm_pop_no
    or     dl, dl
    je     csm_pop_no
    inc    eax
    inc    ebx
    dec    ecx
    jnz    csm_cmp
    pop    ecx
csm_yes:
    mov    eax, 1
    ret
csm_pop_no:
    pop    ecx
    inc    esi
    jmp    csm_scan
csm_no:
    xor    eax, eax
    ret

; eac_per_child_trace — one log line per Scintilla (etc.) probed.
; In:  ect_child       = current child hwnd
;      ctrl_text_buf   = its WM_GETTEXT content
;      eac_last_match  = 0 (no-match) or 1 (match)
; Truncates the log of "got=" to first 40 chars by saving and
; nulling the byte at offset 40 across dbg_writez.
eac_per_child_trace:
    pushad
    mov    edx, offset dbg_msg_eac_child
    call   dbg_writez
    mov    eax, [ect_child]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eac_got
    call   dbg_writez
    mov    dl, byte ptr [ctrl_text_buf + 40]
    mov    [ctrl_save_byte], dl
    mov    byte ptr [ctrl_text_buf + 40], 0
    mov    edx, offset ctrl_text_buf
    call   dbg_writez
    mov    dl, [ctrl_save_byte]
    mov    byte ptr [ctrl_text_buf + 40], dl
    cmp    dword ptr [eac_last_match], 0
    je     eac_pct_nomatch
    mov    edx, offset dbg_msg_eac_match
    jmp    eac_pct_w
eac_pct_nomatch:
    mov    edx, offset dbg_msg_eac_nomatch
eac_pct_w:
    call   dbg_writez
    call   dbg_writecrlf
    popad
    ret

; expect_any_ctrl_text ( "title" "class" "expected" -- )
; Walks every child window of `class` via FindWindowExA chaining,
; runs WM_GETTEXT + substring match on each, PASSes the moment one
; matches. Tab-order-independent — ideal for "is file X open in
; Notepad++ with text Y?" where the editor of interest may not be
; the first Scintilla in z-order.
; expect_any_ctrl_text_in ( "title_substr" "class" "expected" -- )
; Substring window + scan-all classes — combines the substring window
; lookup with the scan-all-children-of-class behavior. Best primitive
; for "is file X open in any tab of Notepad++ (whatever its current
; title)" style assertions. Tab-order-independent AND title-fluctuation-
; independent.
sc_expect_any_ctrl_text_in:
    pushad
    mov    dword ptr [ect_parent], 0
    mov    dword ptr [ect_child],  0
    mov    dword ptr [eac_count],  0
    mov    dword ptr [eac_last_match], 0
    mov    dword ptr [fws_match_hwnd], 0
    mov    byte  ptr [ctrl_text_buf], 0

    ; --- pop expected: copy to ctrl_exp_buf, cap at 255 ---
    call   scr_pop                              ; len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [ctrl_exp_len], ecx
    call   scr_pop                              ; ptr
    mov    esi, eax
    mov    edi, offset ctrl_exp_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    ; --- pop class: copy to ctrl_class_buf, cap at 127 ---
    call   scr_pop                              ; len
    mov    ecx, eax
    cmp    ecx, 127
    jbe    @f
    mov    ecx, 127
@@: call   scr_pop                              ; ptr
    mov    esi, eax
    mov    edi, offset ctrl_class_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    ; --- pop substr: copy to fws_substr_buf, cap at 255 ---
    call   scr_pop                              ; len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [fws_substr_len], ecx
    call   scr_pop                              ; ptr
    mov    esi, eax
    mov    edi, offset fws_substr_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    ; pre-fill sc_str_buf with substr (used by FAIL=win path log)
    mov    esi, offset fws_substr_buf
    mov    edi, offset sc_str_buf
    mov    ecx, [fws_substr_len]
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    ; EnumWindows(enum_win_proc, 0) -> fws_match_hwnd
    push   0
    push   offset enum_win_proc
    call   EnumWindows

    mov    eax, [fws_match_hwnd]
    or     eax, eax
    jz     seac_fail_win
    mov    [ect_parent], eax

    ; Re-fetch the matched window's actual title for the trace header
    push   255
    push   offset sc_str_buf
    push   dword ptr [ect_parent]
    call   GetWindowTextA
    mov    byte ptr [sc_str_buf + 255], 0

    jmp    seac_have_parent

sc_expect_any_ctrl_text:
    pushad
    mov    dword ptr [ect_parent], 0
    mov    dword ptr [ect_child],  0
    mov    dword ptr [eac_count],  0
    mov    dword ptr [eac_last_match], 0
    mov    byte  ptr [ctrl_text_buf], 0

    ; --- pop expected: copy to ctrl_exp_buf, cap at 255 ---
    call   scr_pop                              ; len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [ctrl_exp_len], ecx
    call   scr_pop                              ; ptr
    mov    esi, eax
    mov    edi, offset ctrl_exp_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    ; --- pop class: copy to ctrl_class_buf, cap at 127 ---
    call   scr_pop                              ; len
    mov    ecx, eax
    cmp    ecx, 127
    jbe    @f
    mov    ecx, 127
@@: call   scr_pop                              ; ptr
    mov    esi, eax
    mov    edi, offset ctrl_class_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    ; --- pop title: copy into sc_str_buf via sc_copy_str ---
    call   scr_pop                              ; len
    mov    ecx, eax
    call   scr_pop                              ; ptr
    call   sc_copy_str

    ; FindWindowA(NULL, title)
    push   offset sc_str_buf
    push   0
    call   FindWindowA
    or     eax, eax
    jz     seac_fail_win
    mov    [ect_parent], eax

seac_have_parent:
    ; Shared entry: expect_any_ctrl_text_in jumps here after substring
    ; lookup. By then ect_parent + sc_str_buf are populated and the
    ; rest of the scan-all loop runs identically.
    ; --- header trace ---
    mov    edx, offset dbg_msg_eac_hdr
    call   dbg_writez
    mov    edx, offset sc_str_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_eac_class
    call   dbg_writez
    mov    edx, offset ctrl_class_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_eac_want
    call   dbg_writez
    mov    edx, offset ctrl_exp_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_eac_parent
    call   dbg_writez
    mov    eax, [ect_parent]
    call   dbg_writehex8
    call   dbg_writecrlf

    ; --- enumerate via FindWindowExA chain ---
    xor    edi, edi                             ; hwndChildAfter = NULL
seac_loop:
    push   0                                    ; lpszWindow
    push   offset ctrl_class_buf                ; lpszClass
    push   edi                                  ; hwndChildAfter
    push   dword ptr [ect_parent]               ; hwndParent
    call   FindWindowExA
    or     eax, eax
    jz     seac_loop_end
    mov    edi, eax                             ; advance for next iter
    mov    [ect_child], eax
    inc    dword ptr [eac_count]

    ; WM_GETTEXT into ctrl_text_buf
    mov    byte ptr [ctrl_text_buf], 0
    push   offset ctrl_text_buf
    push   2047
    push   0Dh                                  ; WM_GETTEXT
    push   eax
    call   SendMessageA
    mov    byte ptr [ctrl_text_buf + 2047], 0

    ; substring match
    mov    ecx, [ctrl_exp_len]
    call   ctrl_substr_match
    mov    [eac_last_match], eax

    ; per-child trace
    call   eac_per_child_trace

    cmp    dword ptr [eac_last_match], 0
    je     seac_loop                            ; not this one, try next
    jmp    seac_pass

seac_loop_end:
    ; ran out of children with this class
    cmp    dword ptr [eac_count], 0
    je     seac_fail_ctl                        ; never found ANY of class
    jmp    seac_fail_text                       ; found some, none matched

seac_pass:
    mov    edx, offset dbg_msg_eac_pass
    call   dbg_writez
    mov    eax, [ect_child]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eac_pass2
    call   dbg_writez
    mov    eax, [eac_count]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eac_pass3
    call   dbg_writez
    call   dbg_writecrlf
    popad
    ret

seac_fail_win:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_eac_t_winmiss
    call   dbg_writez
    mov    edx, offset sc_str_buf
    call   dbg_writez
    call   dbg_writecrlf
    mov    edx, offset dbg_msg_eac_failwin
    call   dbg_writez
    call   dbg_writecrlf
    popad
    ret

seac_fail_ctl:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_eac_t_ctlmiss
    call   dbg_writez
    mov    edx, offset ctrl_class_buf
    call   dbg_writez
    call   dbg_writecrlf
    mov    edx, offset dbg_msg_eac_failctl
    call   dbg_writez
    call   dbg_writecrlf
    popad
    ret

seac_fail_text:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_eac_t_textmiss
    call   dbg_writez
    mov    eax, [eac_count]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eac_t_txt2
    call   dbg_writez
    call   dbg_writecrlf
    mov    edx, offset dbg_msg_eac_failtxt
    call   dbg_writez
    mov    eax, [eac_count]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eac_failtxt2
    call   dbg_writez
    call   dbg_writecrlf
    popad
    ret

; Per-call diagnostic line for expect_statusbar — single line with
; title / part / parent hwnd / statusbar hwnd / got / want / outcome.
; In: edx = outcome string ptr (PASS / FAIL=win / FAIL=sbar / FAIL=text).
esb_trace:
    pushad
    mov    ebp, edx                             ; stash outcome ptr
    mov    edx, offset dbg_msg_esb_hdr
    call   dbg_writez
    mov    edx, offset sc_str_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_esb_part
    call   dbg_writez
    mov    eax, [statusbar_part]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_esb_parent
    call   dbg_writez
    mov    eax, [ect_parent]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_esb_sbar
    call   dbg_writez
    mov    eax, [ect_child]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_esb_got
    call   dbg_writez
    mov    edx, offset ctrl_text_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_esb_want
    call   dbg_writez
    mov    edx, offset ctrl_exp_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_esb_tail
    call   dbg_writez
    mov    edx, ebp
    call   dbg_writez
    call   dbg_writecrlf
    popad
    ret

; expect_statusbar_in ( "title_substr" partN "expected" -- )
; Like expect_statusbar but locates the target window via
; EnumWindows + substring title match instead of exact FindWindowA.
; Use when the window's title fluctuates (Notepad++ tab focus,
; locale-dependent strings, version numbers in title bars, etc.).
; After resolving the parent hwnd, the body is shared with
; expect_statusbar via the sesb_have_parent label, so the same
; SB_GETTEXTA→WM_GETTEXT fallback, substring match, and [ESB]
; trace fire here too.
; expect_no_statusbar_in ( "title_substr" partN "expected" -- )
; Inverse of expect_statusbar_in: PASS when the needle is NOT
; present in the matched window's status bar text. Vacuously
; PASSes when the window doesn't exist or has no
; msctls_statusbar32 child.
; For partN == 0, queries via WM_GETTEXT (safe — same path
; expect_statusbar uses to avoid the SB_GETTEXTA-kills-NPP
; gotcha, [[feedback_sb_gettext_crashes_notepadpp]]). For
; partN > 0, uses SB_GETTEXTA with the documented NPP crash
; risk on those parts.
sc_expect_no_statusbar_in:
    pushad
    mov    dword ptr [ect_parent], 0
    mov    dword ptr [ect_child],  0
    mov    byte  ptr [ctrl_text_buf], 0
    mov    dword ptr [fws_match_hwnd], 0

    ; --- pop expected: copy to ctrl_exp_buf, cap at 255 ---
    call   scr_pop
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [ctrl_exp_len], ecx
    call   scr_pop
    mov    esi, eax
    mov    edi, offset ctrl_exp_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    ; --- pop partN ---
    call   scr_pop
    mov    [statusbar_part], eax

    ; --- pop substr: copy to fws_substr_buf ---
    call   scr_pop
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [fws_substr_len], ecx
    call   scr_pop
    mov    esi, eax
    mov    edi, offset fws_substr_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    mov    esi, offset fws_substr_buf
    mov    edi, offset sc_str_buf
    mov    ecx, [fws_substr_len]
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    push   0
    push   offset enum_win_proc
    call   EnumWindows

    mov    eax, [fws_match_hwnd]
    or     eax, eax
    jz     snsb_pass                            ; window absent → PASS
    mov    [ect_parent], eax

    push   0
    push   offset statusbar_class_buf
    push   0
    push   eax
    call   FindWindowExA
    or     eax, eax
    jz     snsb_pass                            ; no status bar → PASS
    mov    [ect_child], eax
    mov    ebx, eax

    ; For part 0 use WM_GETTEXT (safe). For higher parts, SB_GETTEXTA.
    cmp    dword ptr [statusbar_part], 0
    jne    snsb_sb_path
    push   offset esb_wm_ret
    push   500
    push   0
    push   offset ctrl_text_buf
    push   511
    push   0Dh                                  ; WM_GETTEXT
    push   ebx
    call   SendMessageTimeoutA
    jmp    snsb_have_text
snsb_sb_path:
    push   offset esb_sb_ret
    push   500
    push   0
    push   offset ctrl_text_buf
    push   dword ptr [statusbar_part]
    push   402h                                 ; SB_GETTEXTA
    push   ebx
    call   SendMessageTimeoutA
snsb_have_text:
    mov    byte ptr [ctrl_text_buf + 511], 0

    mov    ecx, [ctrl_exp_len]
    call   ctrl_substr_match
    or     eax, eax
    jz     snsb_pass                            ; needle absent → PASS
    ; FAIL — needle FOUND (inverse semantics)
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_nsb_t_found
    call   dbg_writez
    mov    edx, offset ctrl_text_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_ect_textend
    call   dbg_writez
    call   dbg_writecrlf
snsb_pass:
    popad
    ret

sc_expect_statusbar_in:
    pushad
    mov    dword ptr [ect_parent], 0
    mov    dword ptr [ect_child],  0
    mov    byte  ptr [ctrl_text_buf], 0
    mov    dword ptr [fws_match_hwnd], 0

    ; --- pop expected: copy to ctrl_exp_buf, cap at 255 ---
    call   scr_pop                              ; len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [ctrl_exp_len], ecx
    call   scr_pop                              ; ptr
    mov    esi, eax
    mov    edi, offset ctrl_exp_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    ; --- pop partN (single int) ---
    call   scr_pop
    mov    [statusbar_part], eax

    ; --- pop substr: copy to fws_substr_buf, cap at 255 ---
    call   scr_pop                              ; len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [fws_substr_len], ecx
    call   scr_pop                              ; ptr
    mov    esi, eax
    mov    edi, offset fws_substr_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    ; pre-fill sc_str_buf with substr so the trace shows something
    ; sensible even on the FAIL=win path (no window matched).
    mov    esi, offset fws_substr_buf
    mov    edi, offset sc_str_buf
    mov    ecx, [fws_substr_len]
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    ; EnumWindows(enum_win_proc, 0) — populates fws_match_hwnd
    push   0
    push   offset enum_win_proc
    call   EnumWindows

    mov    eax, [fws_match_hwnd]
    or     eax, eax
    jz     sesb_fail_win
    mov    [ect_parent], eax

    ; Re-fetch the matched window's full title into sc_str_buf so
    ; the [ESB] trace shows the actual title, not the substring.
    push   255
    push   offset sc_str_buf
    push   dword ptr [ect_parent]
    call   GetWindowTextA
    mov    byte ptr [sc_str_buf + 255], 0

    jmp    sesb_have_parent

; expect_statusbar ( "title" partN "expected" -- )
; FindWindowA(title) -> FindWindowExA(msctls_statusbar32) ->
; SendMessageA(SB_GETTEXTA=0x0402, partN, &buf). Substring-matches
; "expected" in the returned text. partN is 0-based (Win32 convention).
; Use winctrls first to discover whether your target has the standard
; status-bar class. Use expect_statusbar_in instead when the title
; fluctuates per tab/file (Notepad++ etc.).
sc_expect_statusbar:
    pushad
    mov    dword ptr [ect_parent], 0
    mov    dword ptr [ect_child],  0
    mov    byte  ptr [ctrl_text_buf], 0

    ; --- pop expected: copy to ctrl_exp_buf, cap at 255 ---
    call   scr_pop                              ; len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [ctrl_exp_len], ecx
    call   scr_pop                              ; ptr
    mov    esi, eax
    mov    edi, offset ctrl_exp_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    ; --- pop partN (single int, not a string) ---
    call   scr_pop
    mov    [statusbar_part], eax

    ; --- pop title: copy into sc_str_buf via sc_copy_str ---
    call   scr_pop                              ; len
    mov    ecx, eax
    call   scr_pop                              ; ptr
    call   sc_copy_str

    ; FindWindowA(NULL, title)
    push   offset sc_str_buf
    push   0
    call   FindWindowA
    or     eax, eax
    jz     sesb_fail_win
    mov    [ect_parent], eax

sesb_have_parent:
    ; Shared entry point: expect_statusbar_in jumps here after
    ; finding parent via EnumWindows + substring match. By that
    ; point ect_parent and sc_str_buf are populated.
    ; FindWindowExA(parent, 0, "msctls_statusbar32", 0)
    push   0
    push   offset statusbar_class_buf
    push   0
    push   dword ptr [ect_parent]
    call   FindWindowExA
    or     eax, eax
    jz     sesb_fail_sbar
    mov    [ect_child], eax

    ; SendMessageA(sbar, SB_GETTEXTA=0x0402, partN, &ctrl_text_buf)
    ; SB_GETTEXTA only returns text set via SB_SETTEXTA. Apps that
    ; use SetWindowText or owner-draw on status bar parts (e.g.
    ; Notepad++ part 0 = "Normal text file") return empty here.
    ; If SB_GETTEXTA gives nothing for part 0, fall back to
    ; WM_GETTEXT which catches the SetWindowText path.
    mov    ebx, eax                             ; save sbar hwnd
    ; For part 0, skip SB_GETTEXTA entirely and use WM_GETTEXT
    ; directly. SB_GETTEXTA on Notepad++'s Unicode + owner-drawn
    ; status bar appears to crash/freeze its UI thread (timeout =
    ; ERROR_TIMEOUT, target window self-destructs). winctrls's
    ; WM_GETTEXT-only path doesn't trigger this.
    ; SB_GETTEXTA is still used for part > 0 because WM_GETTEXT
    ; only ever returns part 0 / SB_SIMPLE text.
    cmp    dword ptr [statusbar_part], 0
    je     sesb_skip_sb_getttext
    mov    byte ptr [ctrl_text_buf], 0
    push   offset esb_sb_ret                    ; lpdwResult
    push   500                                  ; uTimeout
    push   0                                    ; SMTO_NORMAL
    push   offset ctrl_text_buf                 ; lParam
    push   dword ptr [statusbar_part]           ; wParam
    push   402h                                 ; SB_GETTEXTA
    push   ebx                                  ; hWnd
    call   SendMessageTimeoutA
;   mov    [esb_sb_smto], eax                   ; probe: SMTO return
;   call   GetLastError                         ; preserves stdcall callee-saves
;   mov    [esb_sb_err], eax                    ; probe: Win32 error
    jmp    sesb_after_sb_getttext
sesb_skip_sb_getttext:
;   ; mark probe values so the log shows we skipped this call
;   mov    dword ptr [esb_sb_smto], 0FFFFFFFFh
;   mov    dword ptr [esb_sb_err], 0FFFFFFFFh
;   mov    dword ptr [esb_sb_ret], 0
    mov    byte ptr [ctrl_text_buf], 0
sesb_after_sb_getttext:
    mov    byte ptr [ctrl_text_buf + 511], 0    ; defensive cap

;   ; --- probe: log SB_GETTEXTA result before the cmp/fallback ---
;   mov    edx, offset dbg_msg_esb_p_sb_pre
;   call   dbg_writez
;   mov    eax, ebx
;   call   dbg_writehex8
;   mov    edx, offset dbg_msg_esb_p_sb_smto
;   call   dbg_writez
;   mov    eax, [esb_sb_smto]
;   call   dbg_writehex8
;   mov    edx, offset dbg_msg_esb_p_sb_err
;   call   dbg_writez
;   mov    eax, [esb_sb_err]
;   call   dbg_writehex8
;   mov    edx, offset dbg_msg_esb_p_sb_ret
;   call   dbg_writez
;   mov    eax, [esb_sb_ret]
;   call   dbg_writehex8
;   mov    edx, offset dbg_msg_esb_p_sb_buf
;   call   dbg_writez
;   mov    edx, offset ctrl_text_buf
;   call   dbg_writez
;   mov    edx, offset dbg_msg_esb_p_end
;   call   dbg_writez
;   call   dbg_writecrlf

    cmp    byte ptr [ctrl_text_buf], 0
    jne    sesb_have_text                       ; SB_GETTEXTA had content
    cmp    dword ptr [statusbar_part], 0
    jne    sesb_have_text                       ; can't fall back for part > 0
    mov    byte ptr [ctrl_text_buf], 0
    push   offset esb_wm_ret                    ; lpdwResult
    push   500                                  ; uTimeout
    push   0                                    ; SMTO_NORMAL
    push   offset ctrl_text_buf                 ; lParam
    push   511                                  ; wParam (buf size)
    push   0Dh                                  ; WM_GETTEXT
    push   ebx                                  ; hWnd
    call   SendMessageTimeoutA
;   mov    [esb_wm_smto], eax                   ; probe: SMTO return
;   call   GetLastError
;   mov    [esb_wm_err], eax                    ; probe: Win32 error
    mov    byte ptr [ctrl_text_buf + 511], 0

;   ; --- probe: log WM_GETTEXT fallback result ---
;   mov    edx, offset dbg_msg_esb_p_wm_pre
;   call   dbg_writez
;   mov    eax, ebx
;   call   dbg_writehex8
;   mov    edx, offset dbg_msg_esb_p_wm_smto
;   call   dbg_writez
;   mov    eax, [esb_wm_smto]
;   call   dbg_writehex8
;   mov    edx, offset dbg_msg_esb_p_wm_err
;   call   dbg_writez
;   mov    eax, [esb_wm_err]
;   call   dbg_writehex8
;   mov    edx, offset dbg_msg_esb_p_wm_ret
;   call   dbg_writez
;   mov    eax, [esb_wm_ret]
;   call   dbg_writehex8
;   mov    edx, offset dbg_msg_esb_p_wm_buf
;   call   dbg_writez
;   mov    edx, offset ctrl_text_buf
;   call   dbg_writez
;   mov    edx, offset dbg_msg_esb_p_end
;   call   dbg_writez
;   call   dbg_writecrlf
sesb_have_text:

    ; substring match
    mov    ecx, [ctrl_exp_len]
    call   ctrl_substr_match
    or     eax, eax
    jz     sesb_fail_text

sesb_pass:
    mov    edx, offset dbg_msg_ect_pass
    call   esb_trace
    popad
    ret

sesb_fail_win:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_esb_t_winmiss
    call   dbg_writez
    mov    edx, offset sc_str_buf
    call   dbg_writez
    call   dbg_writecrlf
    mov    edx, offset dbg_msg_ect_fail_w
    call   esb_trace
    popad
    ret

sesb_fail_sbar:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_esb_t_sbarmiss
    call   dbg_writez
    mov    edx, offset sc_str_buf
    call   dbg_writez
    call   dbg_writecrlf
    mov    edx, offset dbg_msg_esb_fail_s
    call   esb_trace
    popad
    ret

sesb_fail_text:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_esb_t_textmiss
    call   dbg_writez
    mov    edx, offset ctrl_text_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_ect_textend
    call   dbg_writez
    call   dbg_writecrlf
    mov    edx, offset dbg_msg_esb_fail_t
    call   esb_trace
    popad
    ret

; winctrls ( "title" -- )
; FindWindowA(title), then EnumChildWindows to dump every child's
; hwnd / class / WM_GETTEXT content. Run this to discover the class
; argument for expect_ctrl_text against a new app.
sc_winctrls:
    pushad
    call   scr_pop                              ; len
    mov    ecx, eax
    call   scr_pop                              ; ptr
    or     ecx, ecx
    jz     swc_done
    call   sc_copy_str                          ; into sc_str_buf

    push   offset sc_str_buf
    push   0
    call   FindWindowA
    or     eax, eax
    jz     swc_winmiss
    mov    ebx, eax                             ; save parent hwnd

swc_have_parent:
    ; Shared entry point: sc_winctrls_in jumps here after substring
    ; lookup. By that point ebx = parent hwnd, sc_str_buf = title.
    mov    edx, offset dbg_msg_wc_pre
    call   dbg_writez
    mov    edx, offset sc_str_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_wc_parent
    call   dbg_writez
    mov    eax, ebx
    call   dbg_writehex8
    call   dbg_writecrlf

    push   0
    push   offset enum_ctrl_proc
    push   ebx
    call   EnumChildWindows
swc_done:
    popad
    ret

swc_winmiss:
    mov    edx, offset dbg_msg_wc_pre
    call   dbg_writez
    mov    edx, offset sc_str_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_wc_winmiss
    call   dbg_writez
    call   dbg_writecrlf
    popad
    ret

; winctrls_in ( "title_substr" -- )
; Substring-match variant. EnumWindows finds first top-level window
; whose title contains substr; then sc_winctrls's shared body
; enumerates child controls. Use when the exact title is unstable
; (Notepad++ tab focus, locale, version strings, etc.).
sc_winctrls_in:
    pushad
    mov    dword ptr [fws_match_hwnd], 0

    ; pop substr → fws_substr_buf
    call   scr_pop                              ; len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [fws_substr_len], ecx
    call   scr_pop                              ; ptr
    mov    esi, eax
    mov    edi, offset fws_substr_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    ; pre-fill sc_str_buf with substr so the miss path's log is sensible
    mov    esi, offset fws_substr_buf
    mov    edi, offset sc_str_buf
    mov    ecx, [fws_substr_len]
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0

    push   0
    push   offset enum_win_proc
    call   EnumWindows

    mov    eax, [fws_match_hwnd]
    or     eax, eax
    jz     swc_winmiss
    mov    ebx, eax                             ; parent hwnd

    ; refetch the actual title for the [CTRLS] header
    push   255
    push   offset sc_str_buf
    push   ebx
    call   GetWindowTextA
    mov    byte ptr [sc_str_buf + 255], 0

    jmp    swc_have_parent

; EnumWindows callback for enumwins. Logs one line per visible top-
; level window with non-empty title. Skips invisible and unnamed
; windows (system tray icons, off-screen tooltips, shell internals).

; ===========================================================================
;  Extended pixel assertions (cf22, DLL-free). expect_pixel_avg (3x3 average),
;  expect_pixel_any (3x3 any-match), expect_pix3eq (test wrapper for pix3eq).
;  Reuse ep_*/p3eq_* + pixel_within_tol + the eipx dbg strings above.
; ===========================================================================
.data
ep_sum_c1           dd  0     ; expect_pixel_avg channel sums (low/mid/hi byte)
ep_sum_c2           dd  0
ep_sum_c3           dd  0
e3eq_slot           dd  0
dbg_msg_e3eq_miss   db  'expect_pix3eq mismatch slot=', 0
dbg_msg_e3eq_at     db  ' at x=', 0

.code
sc_expect_pixel_avg:
    pushad
    call   scr_pop                              ; tol
    mov    [ep_tol], eax
    call   scr_pop                              ; want color
    mov    [ep_want], eax
    call   scr_pop                              ; y
    mov    [ep_y], eax
    call   scr_pop                              ; x
    mov    [ep_x], eax

    mov    dword ptr [ep_sum_c1], 0
    mov    dword ptr [ep_sum_c2], 0
    mov    dword ptr [ep_sum_c3], 0

    push   0
    call   GetDC
    or     eax, eax
    jz     sxpa_fail
    mov    ebp, eax                             ; hdc (preserved across calls)

    mov    edi, -1                              ; dy
sxpa_y_loop:
    cmp    edi, 2
    jge    sxpa_y_done
    mov    esi, -1                              ; dx
sxpa_x_loop:
    cmp    esi, 2
    jge    sxpa_x_done

    mov    eax, [ep_y]
    add    eax, edi
    push   eax                                  ; y_sample
    mov    eax, [ep_x]
    add    eax, esi
    push   eax                                  ; x_sample
    push   ebp                                  ; hdc
    call   GetPixel
    ; eax = COLORREF — accumulate each channel independently
    movzx  ebx, al
    add    [ep_sum_c1], ebx
    shr    eax, 8
    movzx  ebx, al
    add    [ep_sum_c2], ebx
    shr    eax, 8
    movzx  ebx, al
    add    [ep_sum_c3], ebx

    inc    esi
    jmp    sxpa_x_loop
sxpa_x_done:
    inc    edi
    jmp    sxpa_y_loop
sxpa_y_done:

    push   ebp
    push   0
    call   ReleaseDC

    ; Divide each sum by 9 to get averages, reassemble as COLORREF
    mov    eax, [ep_sum_c1]
    xor    edx, edx
    mov    ecx, 9
    div    ecx
    movzx  ebx, al                              ; c1 avg → low 8 bits

    mov    eax, [ep_sum_c2]
    xor    edx, edx
    mov    ecx, 9
    div    ecx
    movzx  ecx, al
    shl    ecx, 8                               ; c2 avg → bits 8-15
    or     ebx, ecx

    mov    eax, [ep_sum_c3]
    xor    edx, edx
    mov    ecx, 9
    div    ecx
    movzx  ecx, al
    shl    ecx, 16                              ; c3 avg → bits 16-23
    or     ebx, ecx

    mov    [ep_got], ebx
    mov    eax, ebx
    mov    edx, [ep_want]
    call   pixel_within_tol
    or     eax, eax
    jnz    sxpa_pass

sxpa_fail:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_eipx_miss
    call   dbg_writez
    mov    eax, [ep_x]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eipx_y
    call   dbg_writez
    mov    eax, [ep_y]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eipx_got
    call   dbg_writez
    mov    eax, [ep_got]                        ; averaged color
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eipx_want
    call   dbg_writez
    mov    eax, [ep_want]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eipx_tol
    call   dbg_writez
    mov    eax, [ep_tol]
    call   dbg_writehex8
    call   dbg_writecrlf
sxpa_pass:
    popad
    ret

; expect_pix3eq ( p1x p1y c1 p2x p2y c2 p3x p3y c3 tol -- )
; Test-framework wrapper around pix3eq's 3-pixel fingerprint check.
; Same arg shape as pix3eq but drives PASS/FAIL via [tests_fail_count]
; instead of pushing a 0/1. On the first failing slot logs:
;   FAIL: expect_pix3eq mismatch slot=N at x= y= got= want= tol=
; (slot 1/2/3 = which pixel disagreed; slot 0 = GetDC returned NULL).
sc_expect_pix3eq:
    pushad
    call   scr_pop                              ; tol
    mov    [ep_tol], eax
    call   scr_pop                              ; col3
    mov    [p3eq_col3], eax
    call   scr_pop                              ; p3y
    mov    [p3eq_p3y], eax
    call   scr_pop                              ; p3x
    mov    [p3eq_p3x], eax
    call   scr_pop                              ; col2
    mov    [p3eq_col2], eax
    call   scr_pop                              ; p2y
    mov    [p3eq_p2y], eax
    call   scr_pop                              ; p2x
    mov    [p3eq_p2x], eax
    call   scr_pop                              ; col1
    mov    [p3eq_col1], eax
    call   scr_pop                              ; p1y
    mov    [p3eq_p1y], eax
    call   scr_pop                              ; p1x
    mov    [p3eq_p1x], eax
    push   0
    call   GetDC
    or     eax, eax
    jz     se3eq_no_dc
    mov    ebx, eax                             ; ebx = hdc

    ; ---- slot 1 ----
    push   [p3eq_p1y]
    push   [p3eq_p1x]
    push   ebx
    call   GetPixel
    mov    [ep_got], eax
    mov    edx, [p3eq_col1]
    call   pixel_within_tol
    or     eax, eax
    jnz    se3eq_s1_ok
    push   ebx
    push   0
    call   ReleaseDC
    mov    dword ptr [e3eq_slot], 1
    mov    eax, [p3eq_p1x]
    mov    [ep_x], eax
    mov    eax, [p3eq_p1y]
    mov    [ep_y], eax
    mov    eax, [p3eq_col1]
    mov    [ep_want], eax
    jmp    se3eq_log_fail
se3eq_s1_ok:

    ; ---- slot 2 ----
    push   [p3eq_p2y]
    push   [p3eq_p2x]
    push   ebx
    call   GetPixel
    mov    [ep_got], eax
    mov    edx, [p3eq_col2]
    call   pixel_within_tol
    or     eax, eax
    jnz    se3eq_s2_ok
    push   ebx
    push   0
    call   ReleaseDC
    mov    dword ptr [e3eq_slot], 2
    mov    eax, [p3eq_p2x]
    mov    [ep_x], eax
    mov    eax, [p3eq_p2y]
    mov    [ep_y], eax
    mov    eax, [p3eq_col2]
    mov    [ep_want], eax
    jmp    se3eq_log_fail
se3eq_s2_ok:

    ; ---- slot 3 ----
    push   [p3eq_p3y]
    push   [p3eq_p3x]
    push   ebx
    call   GetPixel
    mov    [ep_got], eax
    mov    edx, [p3eq_col3]
    call   pixel_within_tol
    or     eax, eax
    jnz    se3eq_s3_ok
    push   ebx
    push   0
    call   ReleaseDC
    mov    dword ptr [e3eq_slot], 3
    mov    eax, [p3eq_p3x]
    mov    [ep_x], eax
    mov    eax, [p3eq_p3y]
    mov    [ep_y], eax
    mov    eax, [p3eq_col3]
    mov    [ep_want], eax
    jmp    se3eq_log_fail
se3eq_s3_ok:
    push   ebx
    push   0
    call   ReleaseDC
    jmp    se3eq_pass

se3eq_no_dc:
    mov    dword ptr [e3eq_slot], 0             ; 0 = GetDC failed
    xor    eax, eax
    mov    [ep_x], eax
    mov    [ep_y], eax
    mov    [ep_got], eax
    mov    [ep_want], eax

se3eq_log_fail:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_e3eq_miss
    call   dbg_writez
    mov    eax, [e3eq_slot]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_e3eq_at
    call   dbg_writez
    mov    eax, [ep_x]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eipx_y
    call   dbg_writez
    mov    eax, [ep_y]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eipx_got
    call   dbg_writez
    mov    eax, [ep_got]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eipx_want
    call   dbg_writez
    mov    eax, [ep_want]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eipx_tol
    call   dbg_writez
    mov    eax, [ep_tol]
    call   dbg_writehex8
    call   dbg_writecrlf
se3eq_pass:
    popad
    ret

; expect_pixel_any ( x y color tol -- )
; Samples a 3×3 grid centered at (x,y); PASSes if ANY of the 9
; pixels is within `tol` per channel of `color`. Useful for text
; edges and gradient borders where the wanted color exists at the
; sampled region but not necessarily at the exact center pixel.
; Reuses pixel_within_tol's per-channel abs-diff comparison.
sc_expect_pixel_any:
    pushad
    call   scr_pop                              ; tol
    mov    [ep_tol], eax
    call   scr_pop                              ; want color
    mov    [ep_want], eax
    call   scr_pop                              ; y
    mov    [ep_y], eax
    call   scr_pop                              ; x
    mov    [ep_x], eax

    push   0
    call   GetDC
    or     eax, eax
    jz     sxpy_fail
    mov    ebp, eax                             ; hdc

    mov    edi, -1                              ; dy
sxpy_y_loop:
    cmp    edi, 2
    jge    sxpy_y_done
    mov    esi, -1                              ; dx
sxpy_x_loop:
    cmp    esi, 2
    jge    sxpy_x_done

    mov    eax, [ep_y]
    add    eax, edi
    push   eax
    mov    eax, [ep_x]
    add    eax, esi
    push   eax
    push   ebp
    call   GetPixel
    mov    [ep_got], eax                        ; latest sample (for log)

    mov    edx, [ep_want]
    call   pixel_within_tol
    or     eax, eax
    jnz    sxpy_match_release                   ; any match → PASS

    inc    esi
    jmp    sxpy_x_loop
sxpy_x_done:
    inc    edi
    jmp    sxpy_y_loop
sxpy_y_done:
    ; No match found across all 9 samples
    push   ebp
    push   0
    call   ReleaseDC
    jmp    sxpy_fail

sxpy_match_release:
    push   ebp
    push   0
    call   ReleaseDC
    popad
    ret

sxpy_fail:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_eipx_miss
    call   dbg_writez
    mov    eax, [ep_x]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eipx_y
    call   dbg_writez
    mov    eax, [ep_y]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eipx_got
    call   dbg_writez
    mov    eax, [ep_got]                        ; last sampled pixel
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eipx_want
    call   dbg_writez
    mov    eax, [ep_want]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eipx_tol
    call   dbg_writez
    mov    eax, [ep_tol]
    call   dbg_writehex8
    call   dbg_writecrlf
    popad
    ret

; ===========================================================================
;  ocr_digit + mouselog (cf22, DLL-free, GetPixel-based).
;    ocr_digit ( base_x base_y -- digit|-1 )  3-pixel-fingerprint OCR per glyph
;    mouselog  ( -- )                          log cursor x/y + pixel color
;  Reuse ep_tol + pixel_within_tol; ocr_digit_tol drives the tolerance.
; ===========================================================================
.data
ocr_table label dword
    dd  2,   1, 14, 00FFFFFFh,   8, 23, 0019191Ah,   1, 26, 00FFFFFFh,  18  ; '2' base (1680,22)
    dd  9,   6, 17, 001C1D1Dh,   8, 17, 00FEFEFEh,  12, 14, 00383B3Ah,  18  ; '9' base (1698,22)
    dd  4,   3, 23, 00FFFFFFh,  12, 26, 00FCFCFCh,   2, 19, 00303131h,  18  ; '4' base (1716,22)
    dd  0,   0, 21, 00FFFFFFh,   5, 21, 002F2F30h,  12, 21, 00FFFFFFh,  18  ; '0' base (1748,22)
    dd  5,   4, 14, 00FFFFFFh,  10, 17, 00181818h,   4, 25, 00B0B1B1h,  18  ; '5' base (1762,22)
    dd  7,   1, 18, 002F3030h,   5, 22, 00EAEAEAh,   2, 26, 002E2F2Fh,  18  ; '7' base (1775,22)
    dd  1,   2, 14, 00F6F5F4h,   2, 25, 00FFFFFFh,   5, 22, 00625E57h,  18  ; '1' base (1712,94)
    dd  3,   3, 14, 00FEFEFEh,   0, 18, 000D0D0Dh,   5, 26, 00FFFFFFh,  18  ; '3' base (1734,94)
    dd  8,   3, 16, 00FFFFFFh,   1, 19, 0041403Fh,   5, 26, 00FFFFFFh,  18  ; '8' base (1770,94)
    dd  6,   7, 24, 001C1D1Dh,   5, 24, 00FEFEFEh,   1, 27, 00383B3Ah,  18  ; '6' = '9' rotated 180
ocr_table_end label byte
ocr_bx              dd  0
ocr_by              dd  0
ocr_try_x           dd  0
ocr_hdc             dd  0
ocr_digit_tol       dd  15
dbg_msg_ocr_d       db  '[OCR] digit=', 0
mouse_pt            dd  0, 0                       ; POINT for GetCursorPos
dbg_msg_mouse_x     db  '[MOUSE] x=', 0
dbg_msg_mouse_y     db  ' y=', 0
dbg_msg_mouse_c     db  ' color=', 0

.code
sc_ocr_digit:
    pushad
    call   scr_pop                              ; base_y
    mov    [ocr_by], eax
    call   scr_pop                              ; base_x
    mov    [ocr_bx], eax
    mov    eax, [ocr_digit_tol]
    mov    [ep_tol], eax
    push   0
    call   GetDC
    test   eax, eax
    jz     ocrd_no_dc
    mov    [ocr_hdc], eax

    mov    esi, offset ocr_table
ocrd_loop_digit:
    cmp    esi, offset ocr_table_end
    jae    ocrd_done_miss

    ; --- try jitter -1 ---
    mov    eax, [ocr_bx]
    dec    eax
    mov    [ocr_try_x], eax
    call   ocrd_try_3px
    jnc    ocrd_done_match

    ; --- try jitter 0 ---
    mov    eax, [ocr_bx]
    mov    [ocr_try_x], eax
    call   ocrd_try_3px
    jnc    ocrd_done_match

    ; --- try jitter +1 ---
    mov    eax, [ocr_bx]
    inc    eax
    mov    [ocr_try_x], eax
    call   ocrd_try_3px
    jnc    ocrd_done_match

    add    esi, 44                              ; next entry (11 dwords)
    jmp    ocrd_loop_digit

ocrd_done_match:
    mov    eax, [esi]                           ; digit value
    jmp    ocrd_release

ocrd_done_miss:
    mov    eax, 0FFFFFFFFh

ocrd_release:
    push   eax
    push   [ocr_hdc]
    push   0
    call   ReleaseDC
    pop    eax
    jmp    ocrd_emit

ocrd_no_dc:
    mov    eax, 0FFFFFFFFh

ocrd_emit:
    push   eax
    mov    edx, offset dbg_msg_ocr_d
    call   dbg_writez
    mov    eax, [esp]
    call   dbg_writehex8
    call   dbg_writecrlf
    pop    eax
    call   scr_push
    popad
    ret

; ocrd_try_3px helper — esi points to a digit table entry, [ocr_try_x]
; holds candidate x, [ocr_by] holds y.  Returns carry CLEAR on match,
; carry SET on miss.  Preserves esi.
ocrd_try_3px:
    push   esi                                  ; preserve entry ptr
    push   ebx
    mov    ebx, [ocr_hdc]
    ; pixel 1: (try_x + dx1, by + dy1) vs c1
    mov    eax, [esi+8]
    add    eax, [ocr_by]
    push   eax
    mov    eax, [esi+4]
    add    eax, [ocr_try_x]
    push   eax
    push   ebx
    call   GetPixel
    mov    edx, [esi+12]
    call   pixel_within_tol
    test   eax, eax
    jz     ocrd_try_miss
    ; pixel 2
    mov    eax, [esi+20]
    add    eax, [ocr_by]
    push   eax
    mov    eax, [esi+16]
    add    eax, [ocr_try_x]
    push   eax
    push   ebx
    call   GetPixel
    mov    edx, [esi+24]
    call   pixel_within_tol
    test   eax, eax
    jz     ocrd_try_miss
    ; pixel 3
    mov    eax, [esi+32]
    add    eax, [ocr_by]
    push   eax
    mov    eax, [esi+28]
    add    eax, [ocr_try_x]
    push   eax
    push   ebx
    call   GetPixel
    mov    edx, [esi+36]
    call   pixel_within_tol
    test   eax, eax
    jz     ocrd_try_miss
    ; all 3 matched
    pop    ebx
    pop    esi
    clc
    ret
ocrd_try_miss:
    pop    ebx
    pop    esi
    stc
    ret

; mouselog ( -- )
; Calibration helper for pix3eq: reads the current cursor position via
; GetCursorPos and the COLORREF beneath it via GetPixel, logs both:
;   [MOUSE] x=NNNNNNNN y=NNNNNNNN color=00BBGGRR
; Bind to a hotkey, hover over a distinctive pixel of a glyph, fire,
; read the colors out of color_debug.log, plug into pix3eq.
sc_mouselog:
    pushad
    push   offset mouse_pt
    call   GetCursorPos
    push   0
    call   GetDC
    test   eax, eax
    jz     mlog_no_dc
    mov    ebx, eax                             ; ebx = hdc
    push   dword ptr [mouse_pt+4]               ; y
    push   dword ptr [mouse_pt]                 ; x
    push   ebx
    call   GetPixel
    mov    edi, eax                             ; edi = COLORREF
    push   ebx
    push   0
    call   ReleaseDC
    mov    edx, offset dbg_msg_mouse_x
    call   dbg_writez
    mov    eax, [mouse_pt]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_mouse_y
    call   dbg_writez
    mov    eax, [mouse_pt+4]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_mouse_c
    call   dbg_writez
    mov    eax, edi
    call   dbg_writehex8
    call   dbg_writecrlf
    popad
    ret
mlog_no_dc:
    mov    edx, offset dbg_msg_mouse_x
    call   dbg_writez
    mov    eax, [mouse_pt]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_mouse_y
    call   dbg_writez
    mov    eax, [mouse_pt+4]
    call   dbg_writehex8
    call   dbg_writecrlf
    popad
    ret

; ===========================================================================
;  winshot + debug_box (cf22, via helpers.dll exports loaded in load_image_dll).
;    winshot   ( "title" "outpath" -- )  PrintWindow capture -> .bmp (works on
;                                        minimized/covered windows)
;    debug_box ( L T R B ms -- )         flash an XOR rect outline on screen
;  No-op if the DLL did not export WinShot / DebugBox.
; ===========================================================================
.data
winshot_proc_name  db  'WinShot', 0
winshot_fn         dd  0
debug_box_proc_name db 'DebugBox', 0
debug_box_fn       dd  0
winshot_title_buf  db  256 dup (0)
winshot_path_buf   db  256 dup (0)
winshot_dbg_pre    db  'WinShot title="', 0
winshot_dbg_mid    db  '" out="', 0
winshot_dbg_post   db  '" result=', 0
winshot_dbg_hwnd   db  ' hwnd=', 0

.code
sc_winshot:
    pushad
    cmp    dword ptr [winshot_fn], 0
    je     scw_done
    ; pop outpath
    call   scr_pop                       ; outpath_len
    mov    ecx, eax
    call   scr_pop                       ; outpath_ptr
    or     ecx, ecx
    jz     scw_done
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@:
    mov    esi, eax
    mov    edi, offset winshot_path_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    ; pop title
    call   scr_pop                       ; title_len
    mov    ecx, eax
    call   scr_pop                       ; title_ptr
    or     ecx, ecx
    jz     scw_done
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@:
    mov    esi, eax
    mov    edi, offset winshot_title_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    ; FindWindowA(NULL, title) → hwnd
    push   offset winshot_title_buf
    push   0
    call   FindWindowA
    mov    ebx, eax                      ; save hwnd for log
    or     eax, eax
    jz     scw_log_zero
    ; WinShot(hwnd, outpath) → 1 on success, 0 on fail
    push   offset winshot_path_buf
    push   eax
    call   dword ptr [winshot_fn]
    jmp    scw_log
scw_log_zero:
    xor    eax, eax
scw_log:
    push   eax                           ; preserve result
    push   ebx                           ; preserve hwnd
    mov    edx, offset winshot_dbg_pre
    call   dbg_writez
    mov    edx, offset winshot_title_buf
    call   dbg_writez
    mov    edx, offset winshot_dbg_mid
    call   dbg_writez
    mov    edx, offset winshot_path_buf
    call   dbg_writez
    mov    edx, offset winshot_dbg_post
    call   dbg_writez
    pop    ebx
    pop    eax
    push   ebx
    call   dbg_writehex8                 ; result
    mov    edx, offset winshot_dbg_hwnd
    call   dbg_writez
    pop    eax
    call   dbg_writehex8                 ; hwnd
    call   dbg_writecrlf
scw_done:
    popad
    ret

; ===========================================================
; debug_box ( L T R B ms -- ) — visual rect overlay
;
; Calls helpers.dll!DebugBox which flashes an XOR-drawn outline of
; the rectangle (L,T)-(R,B) on screen for ms milliseconds, then
; erases it via a second XOR pass. No window registration; doesn't
; steal focus; exact pixel coordinates on the screen.
;
; Use for visually debugging imgfindin / pixelwait coordinates,
; expect_img search rects, mouse-relative positioning, etc.
;
; Silently no-ops if helpers.dll didn't export DebugBox.
; ===========================================================
sc_debug_box:
    pushad
    cmp    dword ptr [debug_box_fn], 0
    je     sdb_done
    ; pop in reverse-push order: ms, B, R, T, L
    call   scr_pop                          ; ms
    mov    edi, eax
    call   scr_pop                          ; bottom
    push   edi                              ; arg5 (ms) — DLL takes args L,T,R,B,ms
    push   eax                              ; arg4 (bottom)
    call   scr_pop                          ; right
    push   eax                              ; arg3
    call   scr_pop                          ; top
    push   eax                              ; arg2
    call   scr_pop                          ; left
    push   eax                              ; arg1
    call   dword ptr [debug_box_fn]
sdb_done:
    popad
    ret

; ===========================================================================
;  Phase 4 — CDP web automation (cf22). Drives Edge/Chrome over the DevTools
;  Protocol via helpers.dll CDP exports (loaded in load_image_dll). An implicit
;  "current port" is set by weburl; the rest operate on it. No-op if the DLL
;  lacks the export. Assertions feed the test framework.
; ===========================================================================
.data
; CdpXxx export name strings (GetProcAddress) + fn pointers
cdp_launch_name      db  'CdpLaunchEdge', 0
cdp_connect_name     db  'CdpConnect', 0
cdp_eval_name        db  'CdpEval', 0
cdp_getcon_name      db  'CdpGetConsoleErrors', 0
cdp_getnet_name      db  'CdpGetNetworkFailures', 0
cdp_clearlog_name    db  'CdpClearLog', 0
cdp_disconnect_name  db  'CdpDisconnect', 0
cdp_health_name      db  'CdpCheckHealth', 0
cdp_launch_fn        dd  0
cdp_connect_fn       dd  0
cdp_eval_fn          dd  0
cdp_getcon_fn        dd  0
cdp_getnet_fn        dd  0
cdp_clearlog_fn      dd  0
cdp_disconnect_fn    dd  0
cdp_health_fn        dd  0
cdp_cur_port         dd  9222             ; set by weburl; used by the rest
cdp_profile_prefix   db  'C:\cf22_cdp_', 0
cdp_str_true         db  'true', 0
cdp_js_qs_prefix     db  '!!document.querySelector("', 0
cdp_js_qs_suffix     db  '")', 0
cdp_profile_buf      db  128 dup (0)
cdp_result_buf       db  1024 dup (0)
cdp_js_buf           db  1024 dup (0)
cdp_log_buf          db  8192 dup (0)
dbg_msg_edom_miss    db  'expect_dom not present: ', 0
dbg_msg_ejs_false    db  'expect_js false: ', 0
dbg_msg_econ_err     db  'console errors present: ', 0
dbg_msg_enet_err     db  'network failures present: ', 0
dbg_msg_webwatch     db  '[webwatch] ', 0
dbg_msg_webwatch_broke db  'webwatch page broke: ', 0

.code
cdp_strcat0:
    mov    al, [esi]
    mov    [edi], al
    or     al, al
    jz     cdp_sc0_done
    inc    esi
    inc    edi
    jmp    cdp_strcat0
cdp_sc0_done:
    ret

; cdp_streq — compare ASCIIZ [esi] vs [edi]; ZF=1 if equal.
; Clobbers esi/edi/al (callers are inside pushad).
cdp_streq:
    mov    al, [esi]
    cmp    al, [edi]
    jne    cdp_streq_done                    ; mismatch → ZF=0
    test   al, al
    jz     cdp_streq_done                    ; both hit NUL → ZF=1
    inc    esi
    inc    edi
    jmp    cdp_streq
cdp_streq_done:
    ret

; cdp_build_profile — cdp_profile_buf = "C:\cf22_cdp_" + dec(cdp_cur_port)
cdp_build_profile:
    mov    esi, offset cdp_profile_prefix
    mov    edi, offset cdp_profile_buf
    call   cdp_strcat0                       ; edi → NUL after prefix
    mov    eax, [cdp_cur_port]
    mov    ebx, 10
    xor    ecx, ecx                          ; digit count
cbp_div:
    xor    edx, edx
    div    ebx                               ; eax/=10, edx=remainder
    push   edx
    inc    ecx
    or     eax, eax
    jnz    cbp_div
cbp_emit:
    pop    eax
    add    al, '0'
    mov    [edi], al
    inc    edi
    loop   cbp_emit
    mov    byte ptr [edi], 0
    ret

; weburl ( strptr strlen port -- ) — launch Edge on `port` with its
; own debug profile + connect.  Sets cdp_cur_port for later words.
sc_weburl:
    pushad
    call   scr_pop                           ; port
    mov    [cdp_cur_port], eax
    call   scr_pop                           ; len
    mov    ecx, eax
    call   scr_pop                           ; ptr
    or     ecx, ecx
    jz     cdp_weburl_done
    call   sc_copy_str                       ; url → sc_str_buf
    cmp    dword ptr [cdp_launch_fn], 0
    je     cdp_weburl_done
    call   cdp_build_profile                 ; → cdp_profile_buf
    push   offset cdp_profile_buf
    push   [cdp_cur_port]
    push   offset sc_str_buf
    call   [cdp_launch_fn]                    ; CdpLaunchEdge(url,port,profile)
    cmp    dword ptr [cdp_connect_fn], 0
    je     cdp_weburl_done
    push   [cdp_cur_port]
    call   [cdp_connect_fn]                   ; CdpConnect(port) — polls ~10s
cdp_weburl_done:
    popad
    ret

; webeval ( strptr strlen -- ) — run JS on the current port (result
; stashed in cdp_result_buf; side-effect oriented).
sc_webeval:
    pushad
    call   scr_pop                           ; len
    mov    ecx, eax
    call   scr_pop                           ; ptr
    or     ecx, ecx
    jz     cdp_webeval_done
    call   sc_copy_str                       ; JS → sc_str_buf
    cmp    dword ptr [cdp_eval_fn], 0
    je     cdp_webeval_done
    push   1024
    push   offset cdp_result_buf
    push   offset sc_str_buf
    push   [cdp_cur_port]
    call   [cdp_eval_fn]                      ; CdpEval(port,js,out,len)
cdp_webeval_done:
    popad
    ret

; expect_js ( strptr strlen -- ) — eval a JS boolean; PASS iff "true".
sc_expect_js:
    pushad
    call   scr_pop                           ; len
    mov    ecx, eax
    call   scr_pop                           ; ptr
    or     ecx, ecx
    jz     sejs_fail
    call   sc_copy_str                       ; JS → sc_str_buf
    cmp    dword ptr [cdp_eval_fn], 0
    je     sejs_fail
    push   1024
    push   offset cdp_result_buf
    push   offset sc_str_buf
    push   [cdp_cur_port]
    call   [cdp_eval_fn]
    mov    esi, offset cdp_result_buf
    mov    edi, offset cdp_str_true
    call   cdp_streq
    je     sejs_pass
sejs_fail:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_ejs_false
    call   dbg_writez
    mov    edx, offset sc_str_buf
    call   dbg_writez
    call   dbg_writecrlf
sejs_pass:
    popad
    ret

; expect_dom ( strptr strlen -- ) — PASS iff querySelector(sel) exists.
sc_expect_dom:
    pushad
    call   scr_pop                           ; len
    mov    ecx, eax
    call   scr_pop                           ; ptr
    or     ecx, ecx
    jz     sed_fail
    call   sc_copy_str                       ; selector → sc_str_buf
    cmp    dword ptr [cdp_eval_fn], 0
    je     sed_fail
    ; build  !!document.querySelector("<sel>")
    mov    edi, offset cdp_js_buf
    mov    esi, offset cdp_js_qs_prefix
    call   cdp_strcat0
    mov    esi, offset sc_str_buf
    call   cdp_strcat0
    mov    esi, offset cdp_js_qs_suffix
    call   cdp_strcat0
    push   1024
    push   offset cdp_result_buf
    push   offset cdp_js_buf
    push   [cdp_cur_port]
    call   [cdp_eval_fn]
    mov    esi, offset cdp_result_buf
    mov    edi, offset cdp_str_true
    call   cdp_streq
    je     sed_pass
sed_fail:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_edom_miss
    call   dbg_writez
    mov    edx, offset sc_str_buf
    call   dbg_writez
    call   dbg_writecrlf
sed_pass:
    popad
    ret

; expect_no_console_errors ( -- ) — PASS iff 0 console errors captured.
sc_expect_no_console_errors:
    pushad
    cmp    dword ptr [cdp_getcon_fn], 0
    je     sence_pass                        ; no DLL → can't assert
    push   8192
    push   offset cdp_log_buf
    push   [cdp_cur_port]
    call   [cdp_getcon_fn]                    ; eax = count
    or     eax, eax
    jz     sence_pass
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_econ_err
    call   dbg_writez
    mov    edx, offset cdp_log_buf
    call   dbg_writez
    call   dbg_writecrlf
sence_pass:
    popad
    ret

; expect_no_net_failures ( -- ) — PASS iff 0 network failures captured.
sc_expect_no_net_failures:
    pushad
    cmp    dword ptr [cdp_getnet_fn], 0
    je     senf_pass
    push   8192
    push   offset cdp_log_buf
    push   [cdp_cur_port]
    call   [cdp_getnet_fn]
    or     eax, eax
    jz     senf_pass
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_enet_err
    call   dbg_writez
    mov    edx, offset cdp_log_buf
    call   dbg_writez
    call   dbg_writecrlf
senf_pass:
    popad
    ret

; webclear ( -- ) — reset captured console/network logs (between tests).
sc_webclear:
    pushad
    cmp    dword ptr [cdp_clearlog_fn], 0
    je     cdp_webclear_done
    push   [cdp_cur_port]
    call   [cdp_clearlog_fn]
cdp_webclear_done:
    popad
    ret

; webclose ( -- ) — disconnect the current port (joins reader thread).
sc_webclose:
    pushad
    cmp    dword ptr [cdp_disconnect_fn], 0
    je     cdp_webclose_done
    push   [cdp_cur_port]
    call   [cdp_disconnect_fn]
cdp_webclose_done:
    popad
    ret

; webwatch ( strptr strlen interval_ms count -- )
;   Supervise the current page: call CdpCheckHealth `count` times,
;   `interval_ms` apart, logging each verdict to color_debug.log.
;   healthJS empty (len 0) -> default health (loaded + has a body).
;   FAILS the current test and stops on the first BROKEN/DEAD tick.
;   ebp=remaining count, ebx=interval, esi=healthJS ptr (or NULL),
;   edi=last verdict — all survive the stdcall + pushad-wrapped calls.
sc_webwatch:
    pushad
    call   scr_pop                           ; count
    mov    ebp, eax
    call   scr_pop                           ; interval ms
    mov    ebx, eax
    call   scr_pop                           ; len
    mov    ecx, eax
    call   scr_pop                           ; ptr
    or     ecx, ecx
    jz     cdp_ww_default
    call   sc_copy_str                        ; healthJS -> sc_str_buf
    mov    esi, offset sc_str_buf
    jmp    cdp_ww_have
cdp_ww_default:
    xor    esi, esi                           ; NULL -> default health
cdp_ww_have:
    cmp    dword ptr [cdp_health_fn], 0
    je     cdp_ww_done
cdp_ww_loop:
    or     ebp, ebp
    jz     cdp_ww_done
    dec    ebp
    push   1024
    push   offset cdp_result_buf
    push   esi
    push   [cdp_cur_port]
    call   [cdp_health_fn]                    ; eax = 1 OK / 0 BROKEN / -1 DEAD
    mov    edi, eax
    pushad                                    ; log the verdict line
    mov    edx, offset dbg_msg_webwatch
    call   dbg_writez
    mov    edx, offset cdp_result_buf
    call   dbg_writez
    call   dbg_writecrlf
    popad
    cmp    edi, 1
    jne    cdp_ww_broke
    or     ebp, ebp                           ; more ticks? sleep then loop
    jz     cdp_ww_done
    push   ebx
    call   Sleep
    jmp    cdp_ww_loop
cdp_ww_broke:
    inc    dword ptr [tests_fail_count]
    mov    dword ptr [current_test_failed], 1
    call   test_log_prefix
    mov    edx, offset dbg_msg_test_fail_w
    call   dbg_writez
    mov    edx, offset dbg_msg_webwatch_broke
    call   dbg_writez
    mov    edx, offset cdp_result_buf
    call   dbg_writez
    call   dbg_writecrlf
cdp_ww_done:
    popad
    ret

; ===========================================================================
;  CapsLock snippet picker (cf22 task #52, snippets-only — tabnav/UIA dropped).
;    CapsLock -> a filterable listbox of snippets (short / hotkey / part1 /
;    part2). Type to filter; Up/Down to move; Enter pastes Part1, Shift+Enter
;    Part2, Esc cancels. The LL hook posts WM_SHOW_PICKER / _CLOSE_PICKER /
;    _INS_P1 / _INS_P2; this window's picker_wnd_proc handles the rest.
; ===========================================================================
LB_ADDSTRING    equ  180h
LB_RESETCONTENT equ  184h
LB_SETCURSEL    equ  186h
LB_GETCURSEL    equ  188h
WS_CHILD        equ  40000000h
WS_VISIBLE      equ  10000000h
WS_VSCROLL      equ  00200000h
LBS_NOTIFY      equ  00000001h
LBS_HASSTRINGS  equ  00000040h
TABNAV_MAX      equ  256
TABNAV_STRIDE   equ  256

.data
; --- tabnav (browser tabs, Ctrl+Shift+Space) + consent (Ctrl+Alt+R) via UIA ---
tabnav_count_name      db  'TabNavCount', 0
tabnav_get_title_name  db  'TabNavGetTitle', 0
tabnav_switch_name     db  'TabNavSwitchTo', 0
tabnav_snapshot_name   db  'TabNavSnapshot', 0
consent_reject_name    db  'ConsentRejectAll', 0
tabnav_count_fn        dd  0
tabnav_get_title_fn    dd  0
tabnav_switch_fn       dd  0
tabnav_snapshot_fn     dd  0
consent_reject_fn      dd  0
consent_reject_hwnd    dd  0
consent_busy           dd  0      ; 1 while ConsentRejectAll in flight (hook debounce)
tabnav_titles_cache    db  TABNAV_MAX * TABNAV_STRIDE dup (0)
tabnav_cache_count     dd  0
wcpicker            WNDCLASSEX <>
picker_class        db  'lal4sPicker', 0
picker_title        db  'Snippets - type to filter, Enter=Part1, Shift+Enter=Part2, Esc=cancel', 0
listbox_class       db  'LISTBOX', 0
edit_class          db  'EDIT', 0
picker_hwnd         dd  0
picker_listbox      dd  0
picker_edit         dd  0
picker_target       dd  0      ; foreground HWND captured on CapsLock
picker_visible      dd  0
picker_mode         dd  0      ; always 0 (snippets); tabnav not lifted
picker_tabs         dd  44, 120, 280
picker_tabs_cnt     dd  3
picker_idx_map      dd  256 dup (0)   ; display row -> snippet index
picker_idx_count    dd  0
picker_edit_oldproc dd  0
old_fg_lock         dd  0             ; saved SPI_*FOREGROUNDLOCKTIMEOUT
picker_name_buf     db  256 dup (0)
picker_filter_buf   db  128 dup (0)
pp_filter_len       dd  0
psp_save_ptr        dd  0
psp_save_len        dd  0
psp_save_idx        dd  0
hk_ctrl_str         db  'Ctrl+', 0
hk_shift_str        db  'Shift+', 0
hk_alt_str          db  'Alt+', 0
hk_win_str          db  'Win+', 0
fsl_rec             dd  0
fsl_body_end        dd  0
fsl_pipe_pos        dd  0

.code
; register_picker_class — register the picker window class (adapted: lal4s
; WNDCLASSEX field names, hinst, tray icon, IDC_ARROW cursor).
register_picker_class:
    pushad
    mov    [wcpicker.wc_cbSize], sizeof WNDCLASSEX
    mov    dword ptr [wcpicker.wc_style], 3          ; CS_HREDRAW|CS_VREDRAW
    mov    [wcpicker.wc_lpfnWndProc], offset picker_wnd_proc
    mov    dword ptr [wcpicker.wc_cbClsExtra], 0
    mov    dword ptr [wcpicker.wc_cbWndExtra], 0
    mov    eax, [hinst]
    mov    [wcpicker.wc_hInstance], eax
    mov    eax, [hiconlal]
    mov    [wcpicker.wc_hIcon], eax
    mov    [wcpicker.wc_hIconSm], eax
    push   32512                                     ; IDC_ARROW
    push   0
    call   LoadCursorA
    mov    [wcpicker.wc_hCursor], eax
    mov    dword ptr [wcpicker.wc_hbrBackground], 6  ; COLOR_WINDOW+1
    mov    dword ptr [wcpicker.wc_lpszMenuName], 0
    mov    [wcpicker.wc_lpszClassName], offset picker_class
    push   offset wcpicker
    call   RegisterClassExA
    popad
    ret

; populate_picker — (re)fill the listbox, honoring picker_filter_buf.
populate_picker:
    pushad
    cmp    dword ptr [picker_listbox], 0
    je     pp_done
    ; mode 1 = tabnav: fill from the browser-tab snapshot cache instead
    cmp    dword ptr [picker_mode], 1
    jne    pp_snippets_mode
    call   populate_picker_tabnav
    jmp    pp_done
pp_snippets_mode:
    push   0
    push   0
    push   LB_RESETCONTENT
    push   [picker_listbox]
    call   SendMessageA
    mov    dword ptr [picker_idx_count], 0
    lea    eax, picker_filter_buf
    xor    ecx, ecx
@@: cmp    byte ptr [eax+ecx], 0
    je     @f
    inc    ecx
    cmp    ecx, 127
    jb     @b
@@: mov    [pp_filter_len], ecx
    xor    ebx, ebx                     ; snippet index
pp_loop:
    cmp    ebx, [snippets_cnt]
    jae    pp_setcursel
    cmp    dword ptr [pp_filter_len], 0
    je     pp_pass_filter
    ; filter on the short (col 1) first
    mov    eax, [snippets_tbl]
    mov    ecx, ebx
    shl    ecx, 4
    add    eax, ecx
    mov    esi, [eax+0]
    mov    ecx, [eax+4]
    mov    edi, offset picker_filter_buf
    mov    edx, [pp_filter_len]
    call   pci_substr_match
    test   eax, eax
    jnz    pp_pass_filter
    ; fall back to the body
    mov    eax, [snippets_tbl]
    mov    ecx, ebx
    shl    ecx, 4
    add    eax, ecx
    mov    esi, [eax+8]
    mov    ecx, [eax+12]
    mov    edi, offset picker_filter_buf
    mov    edx, [pp_filter_len]
    call   pci_substr_match
    test   eax, eax
    jz     pp_skip
pp_pass_filter:
    call   fmt_snippet_line
    push   offset picker_name_buf
    push   0
    push   LB_ADDSTRING
    push   [picker_listbox]
    call   SendMessageA
    mov    ecx, [picker_idx_count]
    mov    [picker_idx_map + ecx*4], ebx
    inc    dword ptr [picker_idx_count]
pp_skip:
    inc    ebx
    jmp    pp_loop
pp_setcursel:
    push   0
    push   0
    push   LB_SETCURSEL
    push   [picker_listbox]
    call   SendMessageA
pp_done:
    popad
    ret

; populate_picker_tabnav — fill the listbox from tabnav_titles_cache (populated
; once per tabnav open by show_picker via helpers.dll TabNavSnapshot).
populate_picker_tabnav:
    pushad
    push   0
    push   0
    push   LB_RESETCONTENT
    push   [picker_listbox]
    call   SendMessageA
    mov    dword ptr [picker_idx_count], 0
    lea    eax, picker_filter_buf
    xor    ecx, ecx
@@: cmp    byte ptr [eax+ecx], 0
    je     @f
    inc    ecx
    cmp    ecx, 127
    jb     @b
@@: mov    [pp_filter_len], ecx
    xor    ebx, ebx                     ; tab index
ppt_loop:
    cmp    ebx, [tabnav_cache_count]
    jae    ppt_setcursel
    mov    esi, ebx
    imul   esi, TABNAV_STRIDE
    add    esi, offset tabnav_titles_cache
    cmp    dword ptr [pp_filter_len], 0
    je     ppt_pass
    mov    edi, esi
    xor    ecx, ecx
@@: cmp    byte ptr [edi+ecx], 0
    je     @f
    inc    ecx
    cmp    ecx, TABNAV_STRIDE - 1
    jb     @b
@@: mov    edi, offset picker_filter_buf
    mov    edx, [pp_filter_len]
    call   pci_substr_match
    test   eax, eax
    jz     ppt_skip
    mov    esi, ebx
    imul   esi, TABNAV_STRIDE
    add    esi, offset tabnav_titles_cache
ppt_pass:
    push   esi
    push   0
    push   LB_ADDSTRING
    push   [picker_listbox]
    call   SendMessageA
    mov    ecx, [picker_idx_count]
    mov    [picker_idx_map + ecx*4], ebx
    inc    dword ptr [picker_idx_count]
ppt_skip:
    inc    ebx
    jmp    ppt_loop
ppt_setcursel:
    push   0
    push   0
    push   LB_SETCURSEL
    push   [picker_listbox]
    call   SendMessageA
    popad
    ret
create_picker:
    pushad
    call   register_picker_class

    ; CreateWindowExA(0, "CocPicker", title, WS_OVERLAPPEDWINDOW,
    ;                 CW_USEDEFAULT, CW_USEDEFAULT, 480, 600,
    ;                 NULL, NULL, hInstance, NULL)
    push   0
    push   [hinst]
    push   0
    push   0
    push   600                      ; height
    push   800                      ; width — wider for 4-column display
    push   80000000h                ; y = CW_USEDEFAULT
    push   80000000h                ; x = CW_USEDEFAULT
    push   00CF0000h                ; WS_OVERLAPPED|CAPTION|SYSMENU|THICKFRAME
    push   offset picker_title
    push   offset picker_class
    push   0
    call   CreateWindowExA
    mov    [picker_hwnd], eax
    test   eax, eax
    jz     cp_done

    ; EDIT control at top — filter input.  WS_BORDER for visibility.
    ;   id = 101
    push   0
    push   [hinst]
    push   101                      ; child ID
    push   [picker_hwnd]
    push   24                       ; height
    push   792                      ; width
    push   2                        ; y
    push   2                        ; x
    push   WS_CHILD or WS_VISIBLE or 800000h  ; WS_BORDER
    push   0                        ; lpWindowName
    push   offset edit_class
    push   0
    call   CreateWindowExA
    mov    [picker_edit], eax

    ; LISTBOX child fills the rest.  LBS_USETABSTOPS = 80h.
    push   0
    push   [hinst]
    push   100                      ; child ID
    push   [picker_hwnd]
    push   532
    push   792                      ; width
    push   30                       ; y — below EDIT
    push   0                        ; x
    push   WS_CHILD or WS_VISIBLE or WS_VSCROLL or LBS_NOTIFY or LBS_HASSTRINGS or 80h
    push   0
    push   offset listbox_class
    push   0
    call   CreateWindowExA
    mov    [picker_listbox], eax

    ; Tab stops on the listbox (idempotent).
    push   offset picker_tabs
    push   [picker_tabs_cnt]
    push   192h                     ; LB_SETTABSTOPS
    push   [picker_listbox]
    call   SendMessageA

    ; Subclass the EDIT control so arrow keys can move the listbox
    ; selection while EDIT retains focus.  Save the original wndproc
    ; into picker_edit_oldproc, install our picker_edit_proc.
    push   offset picker_edit_proc
    push   -4                       ; GWL_WNDPROC
    push   [picker_edit]
    call   SetWindowLongA
    mov    [picker_edit_oldproc], eax

cp_done:
    popad
    ret
pci_substr_match:
    test   edx, edx
    jz     pci_match_done               ; empty needle always matches
    cmp    ecx, edx
    jb     pci_nomatch
    sub    ecx, edx
    inc    ecx                          ; max start positions
pci_outer:
    test   ecx, ecx
    jz     pci_nomatch
    push   esi
    push   edi
    push   edx
pci_cmp:
    test   edx, edx
    jz     pci_hit
    ; Use AL (haystack byte) and AH (needle byte) — both inside EAX —
    ; so EBX (snippet-loop index in caller) stays untouched.
    mov    al, [esi]
    mov    ah, [edi]
    cmp    al, 'A'
    jb     pci_al_ok
    cmp    al, 'Z'
    ja     pci_al_ok
    add    al, 20h
pci_al_ok:
    cmp    ah, 'A'
    jb     pci_bl_ok
    cmp    ah, 'Z'
    ja     pci_bl_ok
    add    ah, 20h
pci_bl_ok:
    cmp    al, ah
    jne    pci_fail
    inc    esi
    inc    edi
    dec    edx
    jmp    pci_cmp
pci_fail:
    pop    edx
    pop    edi
    pop    esi
    inc    esi
    dec    ecx
    jmp    pci_outer
pci_hit:
    pop    edx
    pop    edi
    pop    esi
pci_match_done:
    mov    eax, 1
    ret
pci_nomatch:
    xor    eax, eax
    ret

; ============================================================================
; fmt_snippet_line — build a tab-separated display row for snippet[ebx]
;
; Layout:  short<TAB>hotkey<TAB>part1<TAB>part2<NUL>
;
; Truncation and \r\n\t cleanup so each row is single-line.  Output
; goes into picker_name_buf (256 bytes).
;
; Input:  ebx = snippet index
; Output: picker_name_buf NUL-terminated, edi past NUL
; ============================================================================
fmt_snippet_line:
    push   eax
    push   ecx
    push   edx
    push   esi
    push   edi

    lea    edi, picker_name_buf

    ; --- Record address ---
    mov    eax, [snippets_tbl]
    mov    ecx, ebx
    shl    ecx, 4
    add    eax, ecx
    mov    [fsl_rec], eax

    ; --- Field 1: short (truncated to 12) ---
    mov    esi, [eax+0]
    mov    ecx, [eax+4]
    cmp    ecx, 12
    jbe    fsl_s_ok
    mov    ecx, 12
fsl_s_ok:
    test   ecx, ecx
    jz     fsl_s_done
    rep    movsb
fsl_s_done:
    mov    byte ptr [edi], 9          ; TAB
    inc    edi

    ; --- Field 2: hotkey (or '-' if none) ---
    mov    eax, [hotkey_tbl + ebx*4]
    test   eax, eax
    jz     fsl_no_hk
    mov    [fsl_pipe_pos], eax         ; reuse temp slot to stash packed value

    mov    ecx, eax
    shr    ecx, 16
    test   ecx, 2                      ; MOD_CTRL
    jz     fsl_skip_ctrl
    mov    esi, offset hk_ctrl_str
    call   copy_z_to_edi
fsl_skip_ctrl:
    mov    ecx, [fsl_pipe_pos]
    shr    ecx, 16
    test   ecx, 4                      ; MOD_SHIFT
    jz     fsl_skip_shift
    mov    esi, offset hk_shift_str
    call   copy_z_to_edi
fsl_skip_shift:
    mov    ecx, [fsl_pipe_pos]
    shr    ecx, 16
    test   ecx, 1                      ; MOD_ALT
    jz     fsl_skip_alt
    mov    esi, offset hk_alt_str
    call   copy_z_to_edi
fsl_skip_alt:
    mov    ecx, [fsl_pipe_pos]
    shr    ecx, 16
    test   ecx, 8                      ; MOD_WIN
    jz     fsl_skip_win
    mov    esi, offset hk_win_str
    call   copy_z_to_edi
fsl_skip_win:
    ; VK code (low 16 bits)
    movzx  eax, word ptr [fsl_pipe_pos]
    ; 0-9
    cmp    eax, 30h
    jb     fsl_vk_other
    cmp    eax, 39h
    ja     fsl_vk_letter
    mov    [edi], al
    inc    edi
    jmp    fsl_hk_done
fsl_vk_letter:
    cmp    eax, 41h
    jb     fsl_vk_other
    cmp    eax, 5Ah
    ja     fsl_vk_fn
    mov    [edi], al                   ; A-Z (preserve case as-is)
    inc    edi
    jmp    fsl_hk_done
fsl_vk_fn:
    cmp    eax, 70h
    jb     fsl_vk_other
    cmp    eax, 7Bh
    ja     fsl_vk_other
    mov    byte ptr [edi], 'F'
    inc    edi
    sub    eax, 70h - 1                ; eax now 1..12
    cmp    eax, 10
    jb     fsl_vk_fn_1digit
    mov    byte ptr [edi], '1'
    inc    edi
    sub    eax, 10
fsl_vk_fn_1digit:
    add    eax, '0'
    mov    [edi], al
    inc    edi
    jmp    fsl_hk_done
fsl_vk_other:
    mov    byte ptr [edi], '?'
    inc    edi
    jmp    fsl_hk_done
fsl_no_hk:
    mov    byte ptr [edi], '-'
    inc    edi
fsl_hk_done:
    mov    byte ptr [edi], 9           ; TAB
    inc    edi

    ; --- Fields 3 + 4: part1 / part2 (split on '|') ---
    mov    eax, [fsl_rec]
    mov    esi, [eax+8]                ; body_ptr
    mov    ecx, [eax+12]               ; body_len
    mov    edx, esi
    add    edx, ecx
    mov    [fsl_body_end], edx
    mov    [fsl_pipe_pos], 0           ; 0 = none found yet

    ; Scan for '|'
    push   esi
    push   ecx
fsl_scan:
    test   ecx, ecx
    jz     fsl_scan_done
    cmp    byte ptr [esi], '|'
    je     fsl_scan_hit
    inc    esi
    dec    ecx
    jmp    fsl_scan
fsl_scan_hit:
    mov    [fsl_pipe_pos], esi
fsl_scan_done:
    pop    ecx
    pop    esi

    ; Field 3: part1
    ; If pipe found, len = pipe_pos - esi, else len = body_len (clamped).
    cmp    dword ptr [fsl_pipe_pos], 0
    je     fsl_p1_full
    mov    ecx, [fsl_pipe_pos]
    sub    ecx, esi
    jmp    fsl_p1_clamp
fsl_p1_full:
    ; ecx already = body_len
fsl_p1_clamp:
    cmp    ecx, 40
    jbe    fsl_p1_ok
    mov    ecx, 40
fsl_p1_ok:
    call   copy_clean_to_edi

    mov    byte ptr [edi], 9           ; TAB
    inc    edi

    ; Field 4: part2 (only if pipe found)
    cmp    dword ptr [fsl_pipe_pos], 0
    je     fsl_p2_empty
    mov    esi, [fsl_pipe_pos]
    inc    esi                         ; past '|'
    mov    ecx, [fsl_body_end]
    sub    ecx, esi
    cmp    ecx, 40
    jbe    fsl_p2_ok
    mov    ecx, 40
fsl_p2_ok:
    call   copy_clean_to_edi
    jmp    fsl_eol
fsl_p2_empty:
    ; No '|' → leave Part2 column blank
fsl_eol:
    mov    byte ptr [edi], 0           ; NUL terminator

    pop    edi
    pop    esi
    pop    edx
    pop    ecx
    pop    eax
    ret

; copy_z_to_edi — copy NUL-terminated string at [esi] into [edi].
; Advances edi to just past the last byte copied (NOT including NUL).
; Clobbers esi.
copy_z_to_edi:
@@: mov    al, [esi]
    test   al, al
    jz     czti_done
    mov    [edi], al
    inc    esi
    inc    edi
    jmp    @b
czti_done:
    ret

; copy_clean_to_edi — copy ecx bytes from [esi] to [edi], replacing
; \r \n \t with single spaces and collapsing runs of whitespace.
; Advances edi past the last byte written.  Clobbers eax/esi/ecx.
copy_clean_to_edi:
    test   ecx, ecx
    jz     ccti_done
@@: mov    al, [esi]
    cmp    al, 0Dh
    je     ccti_space
    cmp    al, 0Ah
    je     ccti_space
    cmp    al, 09h
    je     ccti_space
    jmp    ccti_keep
ccti_space:
    mov    al, ' '
ccti_keep:
    mov    [edi], al
    inc    esi
    inc    edi
    dec    ecx
    jnz    @b
ccti_done:
    ret

; show_picker — capture target, populate, show. Lazy-creates the window.
show_picker:
    pushad
    cmp    dword ptr [picker_hwnd], 0
    jne    sp_have_wnd
    call   create_picker
sp_have_wnd:
    cmp    dword ptr [picker_hwnd], 0
    je     sp_done
    mov    byte ptr [picker_filter_buf], 0
    cmp    dword ptr [picker_edit], 0
    je     sp_no_edit_clear
    push   0
    push   offset picker_filter_buf
    push   0Ch                          ; WM_SETTEXT
    push   [picker_edit]
    call   SendMessageA
sp_no_edit_clear:
    ; tabnav mode: snapshot the browser tab list ONCE (single UIA walk) before
    ; populate. Filter keystrokes then read the cache — no DLL call per keystroke.
    cmp    dword ptr [picker_mode], 1
    jne    sp_no_snapshot
    mov    dword ptr [tabnav_cache_count], 0
    cmp    dword ptr [tabnav_snapshot_fn], 0
    je     sp_no_snapshot
    push   TABNAV_MAX
    push   TABNAV_STRIDE
    push   offset tabnav_titles_cache
    push   [picker_target]
    call   [tabnav_snapshot_fn]           ; -> count (or <0 on failure)
    cmp    eax, 0
    jl     sp_no_snapshot
    mov    [tabnav_cache_count], eax
sp_no_snapshot:
    call   populate_picker
    ; --- Force our window to the foreground. lal4s is a background app, so a
    ;     bare SetForegroundWindow is denied by Windows: the picker opens behind
    ;     the active window (only a taskbar button shows) or its own
    ;     WM_ACTIVATE(WA_INACTIVE) handler immediately re-hides it.
    ;     (1) Relax the foreground-lock timeout to 0 so activation is honored,
    ;     (2) attach to the foreground thread's input queue, then activate.
    ;     esi = foreground thread id, edi = our thread id (both survive the
    ;     stdcall calls below). ---
    ; SystemParametersInfoA(uiAction, uiParam, pvParam, fWinIni) — push R→L
    push   0                            ; fWinIni
    push   offset old_fg_lock           ; pvParam (receives current timeout)
    push   0                            ; uiParam
    push   2000h                        ; uiAction = SPI_GETFOREGROUNDLOCKTIMEOUT
    call   SystemParametersInfoA
    push   2                            ; fWinIni = SPIF_SENDCHANGE
    push   0                            ; pvParam = 0 (new timeout = no lock)
    push   0                            ; uiParam
    push   2001h                        ; uiAction = SPI_SETFOREGROUNDLOCKTIMEOUT
    call   SystemParametersInfoA
    call   GetForegroundWindow
    push   0
    push   eax
    call   GetWindowThreadProcessId     ; eax = foreground thread id
    mov    esi, eax
    call   GetCurrentThreadId           ; eax = our thread id
    mov    edi, eax
    cmp    esi, edi
    je     sp_show                      ; same thread → no attach needed
    push   1                            ; TRUE = attach
    push   esi
    push   edi
    call   AttachThreadInput
sp_show:
    push   5                            ; SW_SHOW
    push   [picker_hwnd]
    call   ShowWindow
    push   [picker_hwnd]
    call   BringWindowToTop
    push   [picker_hwnd]
    call   SetForegroundWindow
    cmp    dword ptr [picker_edit], 0
    je     sp_focus_lb
    push   [picker_edit]
    call   SetFocus
    jmp    sp_focused
sp_focus_lb:
    push   [picker_listbox]
    call   SetFocus
sp_focused:
    cmp    esi, edi
    je     sp_visible                   ; never attached → nothing to detach
    push   0                            ; FALSE = detach
    push   esi
    push   edi
    call   AttachThreadInput
sp_visible:
    ; restore the user's original foreground-lock timeout
    push   2                            ; SPIF_SENDCHANGE
    push   [old_fg_lock]
    push   0
    push   2001h                        ; SPI_SETFOREGROUNDLOCKTIMEOUT
    call   SystemParametersInfoA
    mov    dword ptr [picker_visible], 1
sp_done:
    popad
    ret
hide_picker:
    pushad
    cmp    dword ptr [picker_hwnd], 0
    je     hp_done
    push   0                            ; SW_HIDE
    push   [picker_hwnd]
    call   ShowWindow
    mov    dword ptr [picker_visible], 0
    ; Restore focus to the previous foreground window so user is back
    ; where they were.
    cmp    dword ptr [picker_target], 0
    je     hp_done
    push   [picker_target]
    call   SetForegroundWindow
hp_done:
    popad
    ret
paste_snippet_part:
    cmp    ecx, [snippets_cnt]
    jb     psp_in_range
    ret
psp_in_range:
    push   eax
    push   ebx
    push   esi
    push   edi
    mov    [psp_save_idx], ecx

    ; Compute record address into ebx (kept across the call)
    mov    eax, [snippets_tbl]
    mov    ebx, ecx
    shl    ecx, 4
    add    ecx, eax                          ; ecx = &record
    mov    ebx, ecx                          ; ebx = &record

    ; Save originals so we can restore even if no '|' or part 1 path.
    mov    eax, [ebx+8]
    mov    [psp_save_ptr], eax
    mov    eax, [ebx+12]
    mov    [psp_save_len], eax

    ; Scan [orig_ptr .. orig_ptr+orig_len) for '|'.
    mov    esi, [psp_save_ptr]
    mov    edi, [psp_save_len]
psp_scan:
    test   edi, edi
    jz     psp_no_pipe                       ; reached end without '|'
    cmp    byte ptr [esi], '|'
    je     psp_found_pipe
    inc    esi
    dec    edi
    jmp    psp_scan

psp_found_pipe:
    ; esi now points AT the '|'.
    cmp    edx, 1
    jne    psp_set_part2
    ; Part 1: ptr unchanged, len = esi - orig_ptr.
    mov    eax, esi
    sub    eax, [psp_save_ptr]
    mov    [ebx+12], eax
    jmp    psp_do_paste
psp_set_part2:
    ; Part 2: ptr = esi+1, len = orig_end - (esi+1).
    inc    esi
    mov    [ebx+8], esi
    mov    eax, [psp_save_ptr]
    add    eax, [psp_save_len]              ; orig_end
    sub    eax, esi
    mov    [ebx+12], eax
    jmp    psp_do_paste

psp_no_pipe:
    ; No '|' in body — both parts paste the full body, which is what
    ; the record already says.  No mutation needed.

psp_do_paste:
    mov    ecx, [psp_save_idx]
    call   expand_paste_no_bs

    ; Restore original body fields (the record address may have been
    ; clobbered by expand_paste_no_bs's use of ecx; recompute).
    mov    eax, [snippets_tbl]
    mov    ecx, [psp_save_idx]
    shl    ecx, 4
    add    eax, ecx
    mov    ecx, [psp_save_ptr]
    mov    [eax+8], ecx
    mov    ecx, [psp_save_len]
    mov    [eax+12], ecx

    pop    edi
    pop    esi
    pop    ebx
    pop    eax
    ret

; picker_wnd_proc — the picker window's WndProc (snippets only).
picker_wnd_proc proc pHWnd :DWORD, pUMsg :DWORD, pwParam :DWORD, plParam :DWORD
    mov    edx, [pUMsg]
    cmp    edx, 10h                     ; WM_CLOSE
    jne    pwp_check_activate
    call   hide_picker
    xor    eax, eax
    jmp    pwp_done
pwp_check_activate:
    cmp    edx, 6h                      ; WM_ACTIVATE — auto-hide on deactivate
    jne    pwp_check_close_user
    mov    eax, [pwParam]
    and    eax, 0FFFFh
    test   eax, eax                     ; WA_INACTIVE = 0
    jnz    pwp_default
    call   hide_picker
    xor    eax, eax
    jmp    pwp_done
pwp_check_close_user:
    cmp    edx, WM_CLOSE_PICKER         ; Esc relayed from LL hook
    jne    pwp_check_ins_p1
    call   hide_picker
    xor    eax, eax
    jmp    pwp_done
pwp_check_ins_p1:
    cmp    edx, WM_PICKER_INS_P1        ; Enter
    jne    pwp_check_ins_p2
    mov    edx, 1
    jmp    pwp_do_insert
pwp_check_ins_p2:
    cmp    edx, WM_PICKER_INS_P2        ; Shift+Enter
    jne    pwp_check_command
    mov    edx, 2
    jmp    pwp_do_insert
pwp_check_command:
    cmp    edx, 111h                    ; WM_COMMAND (EDIT EN_CHANGE -> refilter)
    jne    pwp_default
    mov    eax, [pwParam]
    shr    eax, 16
    cmp    eax, 300h                    ; EN_CHANGE
    jne    pwp_default
    push   128
    push   offset picker_filter_buf
    push   [picker_edit]
    call   GetWindowTextA
    call   populate_picker
    xor    eax, eax
    jmp    pwp_done
pwp_do_insert:
    push   edx                          ; part number (1/2)
    push   0
    push   0
    push   LB_GETCURSEL
    push   [picker_listbox]
    call   SendMessageA
    pop    edx
    cmp    eax, -1
    je     pwp_after_insert
    mov    ecx, [picker_idx_map + eax*4]
    cmp    dword ptr [picker_mode], 1
    je     pwp_tabnav_insert
    ; --- snippets path: paste Part1/Part2 ---
    push   ecx
    push   edx
    call   hide_picker
    push   30
    call   Sleep
    pop    edx
    pop    ecx
    call   paste_snippet_part
    jmp    pwp_after_insert
pwp_tabnav_insert:
    ; --- tabnav path: switch to the selected browser tab, THEN hide (so the
    ;     browser is the next foreground, not whatever hide_picker restores). ---
    cmp    dword ptr [tabnav_switch_fn], 0
    je     pwp_after_insert
    push   ecx                          ; tab index
    push   [picker_target]
    call   [tabnav_switch_fn]           ; TabNavSwitchTo(hwnd, index)
    call   hide_picker
pwp_after_insert:
    xor    eax, eax
    jmp    pwp_done
pwp_default:
    push   [plParam]
    push   [pwParam]
    push   [pUMsg]
    push   [pHWnd]
    call   DefWindowProcA
pwp_done:
    ret
picker_wnd_proc endp
picker_edit_proc proc pEHwnd :DWORD, pEMsg :DWORD, pEwParam :DWORD, pElParam :DWORD
    mov    edx, [pEMsg]
    cmp    edx, 100h                    ; WM_KEYDOWN
    jne    pep_default
    mov    eax, [pEwParam]

    cmp    eax, 26h                     ; VK_UP
    je     pep_move_up
    cmp    eax, 28h                     ; VK_DOWN
    je     pep_move_down
    cmp    eax, 21h                     ; VK_PRIOR (PgUp)
    je     pep_move_pgup
    cmp    eax, 22h                     ; VK_NEXT (PgDn)
    je     pep_move_pgdn
    jmp    pep_default

pep_move_up:
    push   -1                           ; delta
    call   pep_lb_move
    xor    eax, eax
    jmp    pep_done
pep_move_down:
    push   1
    call   pep_lb_move
    xor    eax, eax
    jmp    pep_done
pep_move_pgup:
    push   -10
    call   pep_lb_move
    xor    eax, eax
    jmp    pep_done
pep_move_pgdn:
    push   10
    call   pep_lb_move
    xor    eax, eax
    jmp    pep_done

pep_default:
    push   [pElParam]
    push   [pEwParam]
    push   [pEMsg]
    push   [pEHwnd]
    push   [picker_edit_oldproc]
    call   CallWindowProcA
pep_done:
    ret
picker_edit_proc endp

; pep_lb_move(delta) — clamp listbox selection by `delta` rows.
;   Arg on stack at [esp+4] = delta (signed).
;   Reads current sel via LB_GETCURSEL, sets new sel via LB_SETCURSEL.
pep_lb_move:
    push   ebp
    mov    ebp, esp
    push   eax
    push   ecx
    push   edx

    push   0
    push   0
    push   LB_GETCURSEL
    push   [picker_listbox]
    call   SendMessageA
    cmp    eax, -1
    jne    pep_have_sel
    xor    eax, eax                     ; no selection → start at 0
pep_have_sel:
    ; Reload delta into edx AFTER the LB_GETCURSEL SendMessageA call.
    ; SendMessageA (stdcall) clobbers edx, so loading delta before the
    ; call left garbage here: the selection never advanced while the
    ; EDIT had focus (only native listbox nav after a click worked).
    mov    edx, [ebp+8]                 ; delta
    add    eax, edx
    js     pep_clamp_zero
    mov    ecx, [picker_idx_count]
    test   ecx, ecx
    jz     pep_no_items
    dec    ecx                          ; max index
    cmp    eax, ecx
    jbe    pep_clamp_done
    mov    eax, ecx
    jmp    pep_clamp_done
pep_clamp_zero:
    xor    eax, eax
pep_clamp_done:
    push   0
    push   eax                          ; new index
    push   LB_SETCURSEL
    push   [picker_listbox]
    call   SendMessageA
pep_no_items:
    pop    edx
    pop    ecx
    pop    eax
    pop    ebp
    ret    4

; ===========================================================================
;  Background window-capture jobs (winshotevery / winshotstop / winshotstopall).
;    Non-blocking: each job is a Win32 timer (SetTimer on the message window).
;    On each WM_TIMER tick, lal4s_wnd_proc calls winshot_on_timer, which snaps
;    <title> to <prefix>NNNNN.bmp via helpers.dll WinShot and checks the job's
;    limits (image count and/or elapsed ms). Up to WINSHOT_JOBS run in parallel;
;    each is keyed by the window title it captures.
; ===========================================================================
WINSHOT_JOBS        equ  8
WINSHOT_TIMER_BASE  equ  5000h        ; timer id = base + slot

WSJOB struc
  wj_active   dd ?
  wj_count    dd ?
  wj_limit_n  dd ?          ; stop after N images (0 = no count limit)
  wj_limit_ms dd ?          ; stop after M ms elapsed (0 = no time limit)
  wj_start    dd ?          ; GetTickCount at job start
  wj_title    db 256 dup (?)
  wj_prefix   db 256 dup (?)
WSJOB ends

.data
ws_jobs     WSJOB  WINSHOT_JOBS dup (<>)
ws_path     db  600 dup (0)      ; built path "<prefix>NNNNN.bmp"
ws_ext      db  '.bmp', 0
ws_stop_title db 256 dup (0)
ws_div_tab  dd  10000, 1000, 100, 10, 1
we_limit_ms dd  0                ; winshotevery arg scratch
we_limit_n  dd  0
we_interval dd  0
we_plen     dd  0
we_pptr     dd  0
we_tlen     dd  0
we_tptr     dd  0
wot_slot    dd  0
wot_job     dd  0

.code
; ws_emit5(eax = value 0..99999, edi = dest) - write exactly 5 zero-padded
; decimal digits; advances edi past them. Preserves ebx/ecx/edx/esi.
ws_emit5:
    push   esi
    push   ebx
    push   ecx
    push   edx
    mov    esi, offset ws_div_tab
    mov    ecx, 5
we5_loop:
    xor    edx, edx
    mov    ebx, [esi]
    div    ebx                          ; eax = digit, edx = remainder
    add    al, '0'
    mov    [edi], al
    inc    edi
    mov    eax, edx
    add    esi, 4
    dec    ecx
    jnz    we5_loop
    pop    edx
    pop    ecx
    pop    ebx
    pop    esi
    ret

; winshot_to(esi = title asciiz, edi = path asciiz) - FindWindow + WinShot.
; No-op if the WinShot export is missing or the window is not found.
winshot_to:
    cmp    dword ptr [winshot_fn], 0
    je     wt_ret
    push   esi                          ; FindWindowA(NULL, title)
    push   0
    call   FindWindowA
    or     eax, eax
    jz     wt_ret
    push   edi                          ; WinShot(hwnd, path)
    push   eax
    call   [winshot_fn]
wt_ret:
    ret

; winshot_on_timer(ecx = timer id) - one capture tick for a job.
winshot_on_timer:
    pushad
    sub    ecx, WINSHOT_TIMER_BASE
    js     wot_done
    cmp    ecx, WINSHOT_JOBS
    jae    wot_done
    mov    [wot_slot], ecx
    mov    eax, ecx
    imul   eax, sizeof WSJOB
    lea    edx, ws_jobs
    add    edx, eax
    mov    [wot_job], edx
    cmp    dword ptr [edx].WSJOB.wj_active, 0
    je     wot_done
    ; --- build "<prefix>NNNNN.bmp" into ws_path ---
    lea    edi, ws_path
    lea    esi, [edx].WSJOB.wj_prefix
    call   copy_z_to_edi                ; append prefix (asciiz)
    mov    edx, [wot_job]
    mov    eax, [edx].WSJOB.wj_count
    inc    eax                          ; 1-based image number
    call   ws_emit5
    mov    esi, offset ws_ext
    call   copy_z_to_edi                ; ".bmp"
    mov    byte ptr [edi], 0
    ; --- capture ---
    mov    edx, [wot_job]
    lea    esi, [edx].WSJOB.wj_title
    lea    edi, ws_path
    call   winshot_to
    mov    edx, [wot_job]
    inc    dword ptr [edx].WSJOB.wj_count
    ; --- count limit ---
    mov    eax, [edx].WSJOB.wj_limit_n
    test   eax, eax
    jz     wot_time
    mov    ecx, [edx].WSJOB.wj_count
    cmp    ecx, eax
    jae    wot_stop
wot_time:
    ; --- time limit ---
    mov    edx, [wot_job]
    mov    eax, [edx].WSJOB.wj_limit_ms
    test   eax, eax
    jz     wot_done
    call   GetTickCount
    mov    edx, [wot_job]
    sub    eax, [edx].WSJOB.wj_start
    cmp    eax, [edx].WSJOB.wj_limit_ms
    jb     wot_done
wot_stop:
    mov    edx, [wot_job]
    mov    dword ptr [edx].WSJOB.wj_active, 0
    mov    eax, [wot_slot]
    add    eax, WINSHOT_TIMER_BASE
    push   eax
    push   [hwndmsg]
    call   KillTimer
wot_done:
    popad
    ret

; winshotevery ( "title" "prefix" interval_ms limit_count limit_ms -- )
sc_winshotevery:
    pushad
    call   scr_pop
    mov    [we_limit_ms], eax
    call   scr_pop
    mov    [we_limit_n], eax
    call   scr_pop
    mov    [we_interval], eax
    call   scr_pop
    mov    [we_plen], eax
    call   scr_pop
    mov    [we_pptr], eax
    call   scr_pop
    mov    [we_tlen], eax
    call   scr_pop
    mov    [we_tptr], eax
    cmp    dword ptr [winshot_fn], 0    ; no WinShot export -> nothing to do
    je     wse_done
    ; find a free slot
    xor    ebx, ebx
wse_find:
    cmp    ebx, WINSHOT_JOBS
    jae    wse_done                     ; all slots busy
    mov    eax, ebx
    imul   eax, sizeof WSJOB
    lea    edx, ws_jobs
    add    edx, eax
    cmp    dword ptr [edx].WSJOB.wj_active, 0
    je     wse_free
    inc    ebx
    jmp    wse_find
wse_free:
    mov    dword ptr [edx].WSJOB.wj_count, 0
    mov    eax, [we_limit_n]
    mov    [edx].WSJOB.wj_limit_n, eax
    mov    eax, [we_limit_ms]
    mov    [edx].WSJOB.wj_limit_ms, eax
    push   edx
    call   GetTickCount
    pop    edx
    mov    [edx].WSJOB.wj_start, eax
    ; copy title -> wj_title (cap 255, NUL-terminate)
    mov    ecx, [we_tlen]
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    esi, [we_tptr]
    lea    edi, [edx].WSJOB.wj_title
    push   edx
    rep    movsb
    mov    byte ptr [edi], 0
    pop    edx
    ; copy prefix -> wj_prefix
    mov    ecx, [we_plen]
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    esi, [we_pptr]
    lea    edi, [edx].WSJOB.wj_prefix
    push   edx
    rep    movsb
    mov    byte ptr [edi], 0
    pop    edx
    mov    dword ptr [edx].WSJOB.wj_active, 1
    ; SetTimer(hwndmsg, WINSHOT_TIMER_BASE+slot, interval_ms, NULL)
    push   0
    push   [we_interval]
    lea    eax, [ebx + WINSHOT_TIMER_BASE]
    push   eax
    push   [hwndmsg]
    call   SetTimer
wse_done:
    popad
    ret

; winshotstop ( "title" -- ) - stop the first active job capturing that title.
sc_winshotstop:
    pushad
    call   scr_pop                      ; title len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: call   scr_pop                      ; title ptr
    mov    esi, eax
    lea    edi, ws_stop_title
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    xor    ebx, ebx
wss_loop:
    cmp    ebx, WINSHOT_JOBS
    jae    wss_done
    mov    eax, ebx
    imul   eax, sizeof WSJOB
    lea    edx, ws_jobs
    add    edx, eax
    cmp    dword ptr [edx].WSJOB.wj_active, 0
    je     wss_next
    lea    esi, [edx].WSJOB.wj_title
    lea    edi, ws_stop_title
    call   cdp_streq                    ; ZF=1 if equal (preserves ebx/ecx/edx)
    jne    wss_next
    mov    dword ptr [edx].WSJOB.wj_active, 0
    mov    eax, ebx
    add    eax, WINSHOT_TIMER_BASE
    push   eax
    push   [hwndmsg]
    call   KillTimer
    jmp    wss_done                     ; one at a time
wss_next:
    inc    ebx
    jmp    wss_loop
wss_done:
    popad
    ret

; winshotstopall ( -- ) - stop every active job.
sc_winshotstopall:
    pushad
    xor    ebx, ebx
wsa_loop:
    cmp    ebx, WINSHOT_JOBS
    jae    wsa_done
    mov    eax, ebx
    imul   eax, sizeof WSJOB
    lea    edx, ws_jobs
    add    edx, eax
    cmp    dword ptr [edx].WSJOB.wj_active, 0
    je     wsa_next
    mov    dword ptr [edx].WSJOB.wj_active, 0
    mov    eax, ebx
    add    eax, WINSHOT_TIMER_BASE
    push   eax
    push   [hwndmsg]
    call   KillTimer
wsa_next:
    inc    ebx
    jmp    wsa_loop
wsa_done:
    popad
    ret

; ===========================================================================
;  Recoverable SEH (cf22, adapted). SetUnhandledExceptionFilter installs
;  seh_handler; on a fault it dumps exception code / registers / bytes@Eip /
;  memory to lal4s_debug.log, then RECOVERS: if the fault is continuable and a
;  snapshot exists, it patches CONTEXT.Eip to recover_to_loop and resumes ->
;  back to the message loop, so one bad script primitive doesn't kill lal4s.
;  (cf22's Forth-state dump is dropped; recovery targets the message loop
;  instead of the Forth ACCEPT loop.)
; ===========================================================================
.data
dbg_in_seh     dd  0                 ; re-entry guard for the handler
seh_exc_ptr    dd  0                 ; saved pExceptionRecord
seh_ctx_ptr    dd  0                 ; saved pContext
safe_valid     dd  0                 ; 1 once a message-loop snapshot exists
safe_esp       dd  0                 ; message-loop stack pointer
safe_esi       dd  0
safe_edi       dd  0
dbg_msg_trap   db  0Dh, 0Ah, '*** TRAP/FAULT ***', 0Dh, 0Ah, 0
dbg_msg_code   db  'Code=', 0
dbg_msg_eip    db  '  Eip=', 0
dbg_msg_flags  db  '  Flags=', 0
dbg_msg_eax    db  0Dh, 0Ah, 'EAX=', 0
dbg_msg_ebx    db  ' EBX=', 0
dbg_msg_ecx    db  ' ECX=', 0
dbg_msg_edx    db  ' EDX=', 0
dbg_msg_esi    db  0Dh, 0Ah, 'ESI=', 0
dbg_msg_edi    db  ' EDI=', 0
dbg_msg_ebp    db  ' EBP=', 0
dbg_msg_esp    db  ' ESP=', 0
dbg_msg_acc    db  0Dh, 0Ah, 'AccessType=', 0
dbg_msg_addr   db  ' FaultAddr=', 0
dbg_msg_bytes  db  0Dh, 0Ah, 'Bytes@Eip=', 0
dbg_msg_sp     db  ' '
dbg_msg_sp_len equ $ - dbg_msg_sp
dbg_msg_2sp    db  '  ', 0
dbg_msg_excrec db  0Dh, 0Ah, 'ExceptionRecord:', 0Dh, 0Ah, 0
dbg_msg_context db 0Dh, 0Ah, 'Context:', 0Dh, 0Ah, 0
dbg_msg_stack  db  0Dh, 0Ah, 'Stack:', 0Dh, 0Ah, 0
dbg_msg_eipmem db  0Dh, 0Ah, 'Memory@Eip:', 0Dh, 0Ah, 0
dbg_msg_recover  db 0Dh, 0Ah, '*** RECOVER *** code=', 0
dbg_msg_recover2 db '  eip=', 0

.code
; --- seh_handler(EXCEPTION_POINTERS* at [esp+4]) -> LONG ---
seh_handler:
    cmp    dword ptr [dbg_in_seh], 0
    jne    seh_panic                 ; faulted while dumping -> give up
    mov    dword ptr [dbg_in_seh], 1
    mov    eax, dword ptr [esp+4]    ; EXCEPTION_POINTERS*
    mov    ebx, dword ptr [eax]      ; pExceptionRecord
    mov    [seh_exc_ptr], ebx
    mov    ebx, dword ptr [eax+4]    ; pContext
    mov    [seh_ctx_ptr], ebx
    mov    edx, offset dbg_msg_trap
    call   dbg_writez
    ; Code / Eip / Flags (from ExceptionRecord)
    mov    edx, offset dbg_msg_code
    call   dbg_writez
    mov    ebx, [seh_exc_ptr]
    mov    eax, [ebx+0]              ; ExceptionCode
    call   dbg_writehex8
    mov    edx, offset dbg_msg_eip
    call   dbg_writez
    mov    ebx, [seh_exc_ptr]
    mov    eax, [ebx+0Ch]            ; ExceptionAddress
    call   dbg_writehex8
    mov    edx, offset dbg_msg_flags
    call   dbg_writez
    mov    ebx, [seh_exc_ptr]
    mov    eax, [ebx+4]             ; ExceptionFlags
    call   dbg_writehex8
    ; EAX EBX ECX EDX (CONTEXT 0B0/0A4/0AC/0A8)
    mov    edx, offset dbg_msg_eax
    call   dbg_writez
    mov    ebx, [seh_ctx_ptr]
    mov    eax, [ebx+0B0h]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_ebx
    call   dbg_writez
    mov    ebx, [seh_ctx_ptr]
    mov    eax, [ebx+0A4h]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_ecx
    call   dbg_writez
    mov    ebx, [seh_ctx_ptr]
    mov    eax, [ebx+0ACh]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_edx
    call   dbg_writez
    mov    ebx, [seh_ctx_ptr]
    mov    eax, [ebx+0A8h]
    call   dbg_writehex8
    ; ESI EDI EBP ESP (CONTEXT 0A0/09C/0B4/0C4)
    mov    edx, offset dbg_msg_esi
    call   dbg_writez
    mov    ebx, [seh_ctx_ptr]
    mov    eax, [ebx+0A0h]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_edi
    call   dbg_writez
    mov    ebx, [seh_ctx_ptr]
    mov    eax, [ebx+09Ch]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_ebp
    call   dbg_writez
    mov    ebx, [seh_ctx_ptr]
    mov    eax, [ebx+0B4h]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_esp
    call   dbg_writez
    mov    ebx, [seh_ctx_ptr]
    mov    eax, [ebx+0C4h]
    call   dbg_writehex8
    call   dbg_writecrlf
    ; AccessType / FaultAddr (if NumberParameters >= 2)
    mov    ebx, [seh_exc_ptr]
    cmp    dword ptr [ebx+10h], 2
    jb     seh_skip_excinfo
    mov    edx, offset dbg_msg_acc
    call   dbg_writez
    mov    ebx, [seh_exc_ptr]
    mov    eax, [ebx+14h]
    call   dbg_writehex8
    mov    edx, offset dbg_msg_addr
    call   dbg_writez
    mov    ebx, [seh_exc_ptr]
    mov    eax, [ebx+18h]
    call   dbg_writehex8
seh_skip_excinfo:
    ; 16 raw bytes at EIP (guarded by dbg_in_seh re-entry if EIP unmapped)
    mov    edx, offset dbg_msg_bytes
    call   dbg_writez
    mov    ebx, [seh_exc_ptr]
    mov    esi, [ebx+0Ch]
    mov    ecx, 16
seh_byte_loop:
    mov    al, [esi]
    call   dbg_writehex2
    pushad
    push   0
    push   offset dbg_written
    push   dbg_msg_sp_len
    push   offset dbg_msg_sp
    push   [dbg_handle]
    call   WriteFile
    popad
    inc    esi
    dec    ecx
    jnz    seh_byte_loop
    call   dbg_writecrlf
    ; raw dumps: ExceptionRecord(20) / Context(56) / Stack(16) / Memory@Eip(8)
    mov    edx, offset dbg_msg_excrec
    call   dbg_writez
    mov    edx, [seh_exc_ptr]
    mov    ecx, 20
    call   dbg_dump_dwords
    mov    edx, offset dbg_msg_context
    call   dbg_writez
    mov    edx, [seh_ctx_ptr]
    mov    ecx, 56
    call   dbg_dump_dwords
    mov    edx, offset dbg_msg_stack
    call   dbg_writez
    mov    ebx, [seh_ctx_ptr]
    mov    edx, [ebx+0C4h]           ; CONTEXT.Esp
    mov    ecx, 16
    call   dbg_dump_dwords
    mov    edx, offset dbg_msg_eipmem
    call   dbg_writez
    mov    ebx, [seh_exc_ptr]
    mov    edx, [ebx+0Ch]
    mov    ecx, 8
    call   dbg_dump_dwords
    ; --- recover if continuable + a snapshot exists ---
    mov    ebx, [seh_exc_ptr]
    test   dword ptr [ebx+4], 1      ; EXCEPTION_NONCONTINUABLE
    jnz    seh_panic_close
    cmp    dword ptr [safe_valid], 0
    je     seh_panic_close
    mov    eax, [ebx+0]              ; ExceptionCode
    push   eax
    mov    edx, offset dbg_msg_recover
    call   dbg_writez
    pop    eax
    call   dbg_writehex8
    mov    edx, offset dbg_msg_recover2
    call   dbg_writez
    mov    ebx, [seh_exc_ptr]
    mov    eax, [ebx+0Ch]
    call   dbg_writehex8
    call   dbg_writecrlf
    ; Patch CONTEXT.Eip (0B8h) to recover_to_loop and continue execution.
    mov    ebx, [seh_ctx_ptr]
    mov    dword ptr [ebx+0B8h], offset recover_to_loop
    mov    eax, -1                   ; EXCEPTION_CONTINUE_EXECUTION
    ret
seh_panic_close:
    push   [dbg_handle]             ; flush via close
    call   CloseHandle
seh_panic:
    push   1
    call   ExitProcess

; save_safe_state — snapshot the message-loop stack pointer as the recovery
; landing spot. Called at the top of each message-loop iteration.
save_safe_state:
    push   eax
    lea    eax, [esp+8]             ; caller's esp (before the call)
    mov    [safe_esp], eax
    mov    [safe_esi], esi
    mov    [safe_edi], edi
    mov    dword ptr [safe_valid], 1
    pop    eax
    ret

; recover_to_loop — the OS resumes here after a recovered fault. Unwind to the
; saved message-loop stack and re-enter the pump.
recover_to_loop:
    mov    esp, [safe_esp]
    mov    esi, [safe_esi]
    mov    edi, [safe_edi]
    mov    dword ptr [dbg_in_seh], 0   ; re-arm the handler for the next fault
    jmp    msg_loop

; install_seh — register the unhandled-exception filter.
install_seh:
    push   offset seh_handler
    call   SetUnhandledExceptionFilter
    ret

dbg_dump_dwords:
    pushad
    test   ecx, ecx
    jz     ddd_done
ddd_row:
    ; header: <addr>
    mov    eax, edx
    call   dbg_writehex8
    push   edx
    mov    edx, offset dbg_msg_2sp
    call   dbg_writez
    pop    edx
    ; 4 dwords on this row
    mov    ebx, 4
ddd_dw:
    mov    eax, [edx]
    call   dbg_writehex8
    pushad                       ; preserve ecx (outer loop) + edx
    push   0
    push   offset dbg_written
    push   1
    push   offset dbg_msg_sp
    push   [dbg_handle]
    call   WriteFile
    popad
    add    edx, 4
    dec    ebx
    jnz    ddd_dw
    call   dbg_writecrlf
    sub    ecx, 4
    ja     ddd_row              ; ja: unsigned, exits when ecx <= 0
ddd_done:
    popad
    ret

dbg_writehex2:
    cmp    dword ptr [dbg_handle], 0FFFFFFFFh
    je     dwh2_ret
    pushad
    movzx  ebx, al
    mov    edi, offset dbg_buf
    mov    edx, ebx
    shr    edx, 4
    and    edx, 0Fh
    mov    al, byte ptr [edx + dbg_hex_tab]
    mov    [edi], al
    mov    edx, ebx
    and    edx, 0Fh
    mov    al, byte ptr [edx + dbg_hex_tab]
    mov    [edi+1], al
    push   0
    push   offset dbg_written
    push   2
    push   offset dbg_buf
    push   [dbg_handle]
    call   WriteFile
    popad
dwh2_ret:
    ret

; ===========================================================================
;  weblog ( "js" -- ) - eval JS on the current CDP port and write both the
;  expression and its result to lal4s_debug.log. Same eval as webeval, but
;  surfaces the value (webeval only stashes it internally). Use for inspecting
;  page state while debugging: "document.title" weblog / "app.version" weblog.
; ===========================================================================
.data
dbg_msg_weblog_pre db  '[weblog] ', 0
dbg_msg_weblog_mid db  ' => ', 0

.code
sc_weblog:
    pushad
    call   scr_pop                           ; js len
    mov    ecx, eax
    call   scr_pop                           ; js ptr
    or     ecx, ecx
    jz     cdp_weblog_done
    call   sc_copy_str                       ; JS -> sc_str_buf
    cmp    dword ptr [cdp_eval_fn], 0
    je     cdp_weblog_done                   ; no CDP -> nothing to eval
    push   1024
    push   offset cdp_result_buf
    push   offset sc_str_buf
    push   [cdp_cur_port]
    call   [cdp_eval_fn]                      ; CdpEval(port, js, out, len)
    ; log "[weblog] <js> => <result>"
    mov    edx, offset dbg_msg_weblog_pre
    call   dbg_writez
    mov    edx, offset sc_str_buf
    call   dbg_writez
    mov    edx, offset dbg_msg_weblog_mid
    call   dbg_writez
    mov    edx, offset cdp_result_buf
    call   dbg_writez
    call   dbg_writecrlf
cdp_weblog_done:
    popad
    ret

; ===========================================================================
;  log_boot_state - one-shot startup diagnostic dumped to lal4s_debug.log after
;  init: snippets source + parsed table, every helpers.dll export that resolved
;  (0 = missing), and the terminal skip-list. Restores the cf22 boot logging
;  that was dropped during the lift. Reads already-populated globals; call once
;  from _start after load_image_dll / parse_snippets_txt / register_hotkeys.
; ===========================================================================
.data
dbg_b_hdr   db  0Dh,0Ah,'=== lal4s boot ===',0Dh,0Ah,0
dbg_b_src   db  'snippets source: ',0
dbg_b_cnt   db  'snippets count=',0
dbg_b_rec   db  '  [',0
dbg_b_short db  '] short="',0
dbg_b_scr   db  '"  script=',0
dbg_b_hk    db  '  hotkey=',0
dbg_b_blen  db  '  body_len=',0
dbg_b_dll   db  0Dh,0Ah,'helpers.dll base=',0
dbg_b_isf   db  0Dh,0Ah,'  ImageSearch=',0
dbg_b_wsf   db  '  WinShot=',0
dbg_b_dbf   db  '  DebugBox=',0
dbg_b_tnf   db  0Dh,0Ah,'  TabNavSnapshot=',0
dbg_b_crf   db  '  ConsentRejectAll=',0
dbg_b_cdl   db  0Dh,0Ah,'  CdpLaunchEdge=',0
dbg_b_cev   db  '  CdpEval=',0
dbg_b_ccon  db  '  CdpConnect=',0
dbg_b_skip  db  0Dh,0Ah,'skip classes: ',0
dbg_b_sep   db  ' | ',0
dbg_b_end   db  0Dh,0Ah,'=== boot end ===',0Dh,0Ah,0
; hotkey-fire line (referenced from lal4s.asm lw_hotkey)
dbg_msg_hk_fire db 0Dh,0Ah,'[HOTKEY] fired id=',0
; register_hotkeys per-key logging
rh_packed       dd  0
dbg_msg_rh_pre  db  'hotkey id=',0
dbg_msg_rh_pk   db  '  packed=',0
dbg_msg_rh_ret  db  '  RegisterHotKey=',0

.code
log_boot_state:
    pushad
    mov    edx, offset dbg_b_hdr
    call   dbg_writez
    mov    edx, offset dbg_b_src
    call   dbg_writez
    mov    edx, [effective_snippets_path]
    call   dbg_writez
    call   dbg_writecrlf
    mov    edx, offset dbg_b_cnt
    call   dbg_writez
    mov    eax, [snippets_cnt]
    call   dbg_writehex8
    call   dbg_writecrlf
    ; --- per-snippet: [idx] short="..." script=.. hotkey=.. body_len=.. ---
    xor    ebx, ebx
lbs_loop:
    cmp    ebx, [snippets_cnt]
    jae    lbs_dll
    mov    edx, offset dbg_b_rec
    call   dbg_writez
    mov    eax, ebx
    call   dbg_writehex8
    mov    edx, offset dbg_b_short
    call   dbg_writez
    mov    eax, [snippets_tbl]
    mov    ecx, ebx
    shl    ecx, 4
    add    eax, ecx                         ; record ptr
    mov    ecx, [eax+4]                      ; short_len
    mov    edx, [eax+0]                      ; short_ptr
    call   dbg_writeN
    mov    edx, offset dbg_b_scr
    call   dbg_writez
    mov    ecx, ebx
    mov    eax, [is_script_tbl + ecx*4]
    call   dbg_writehex8
    mov    edx, offset dbg_b_hk
    call   dbg_writez
    mov    ecx, ebx
    mov    eax, [hotkey_tbl + ecx*4]
    call   dbg_writehex8
    mov    edx, offset dbg_b_blen
    call   dbg_writez
    mov    eax, [snippets_tbl]
    mov    ecx, ebx
    shl    ecx, 4
    add    eax, ecx
    mov    eax, [eax+12]                     ; body_len
    call   dbg_writehex8
    call   dbg_writecrlf
    inc    ebx
    jmp    lbs_loop
lbs_dll:
    ; --- helpers.dll exports (0 = not resolved) ---
    mov    edx, offset dbg_b_dll
    call   dbg_writez
    mov    eax, [h_image_dll]
    call   dbg_writehex8
    mov    edx, offset dbg_b_isf
    call   dbg_writez
    mov    eax, [image_search_fn]
    call   dbg_writehex8
    mov    edx, offset dbg_b_wsf
    call   dbg_writez
    mov    eax, [winshot_fn]
    call   dbg_writehex8
    mov    edx, offset dbg_b_dbf
    call   dbg_writez
    mov    eax, [debug_box_fn]
    call   dbg_writehex8
    mov    edx, offset dbg_b_tnf
    call   dbg_writez
    mov    eax, [tabnav_snapshot_fn]
    call   dbg_writehex8
    mov    edx, offset dbg_b_crf
    call   dbg_writez
    mov    eax, [consent_reject_fn]
    call   dbg_writehex8
    mov    edx, offset dbg_b_cdl
    call   dbg_writez
    mov    eax, [cdp_launch_fn]
    call   dbg_writehex8
    mov    edx, offset dbg_b_cev
    call   dbg_writez
    mov    eax, [cdp_eval_fn]
    call   dbg_writehex8
    mov    edx, offset dbg_b_ccon
    call   dbg_writez
    mov    eax, [cdp_connect_fn]
    call   dbg_writehex8
    ; --- skip-list (single-NUL separated, double-NUL end) ---
    mov    edx, offset dbg_b_skip
    call   dbg_writez
    mov    esi, offset skip_class_buf
lbs_skip_loop:
    cmp    byte ptr [esi], 0
    je     lbs_skip_done
    mov    edx, esi                          ; one class (asciiz); dbg_writez preserves esi
    call   dbg_writez
lbs_skip_adv:
    cmp    byte ptr [esi], 0
    je     lbs_skip_next
    inc    esi
    jmp    lbs_skip_adv
lbs_skip_next:
    inc    esi                               ; past the NUL
    cmp    byte ptr [esi], 0                  ; double-NUL = end of list
    je     lbs_skip_done
    mov    edx, offset dbg_b_sep
    call   dbg_writez
    jmp    lbs_skip_loop
lbs_skip_done:
    mov    edx, offset dbg_b_end
    call   dbg_writez
    popad
    ret

; ===========================================================================
;  winactivate_substr ( "substr" -- ) - foreground the first top-level window
;    whose title CONTAINS substr (for fluctuating titles: browsers, editors).
;    Pairs with send/type. Reuses enum_win_proc + fws_* from the EnumWindows group.
;
;  key ( "name" -- ) - press one bare key (no modifier) as a real keystroke via
;    SendInput. Names: esc enter return tab space backspace bksp delete del
;    insert ins home end pageup pgup pagedown pgdn up down left right f1..f12,
;    or a single letter/digit. For chorded keys use send ("ctrl+c" etc.).
; ===========================================================================
.data
key_name_buf   db  16 dup (0)
key_name_len   dd  0
kn_esc       db 'esc',0
kn_escape    db 'escape',0
kn_enter     db 'enter',0
kn_return    db 'return',0
kn_tab       db 'tab',0
kn_space     db 'space',0
kn_bksp      db 'bksp',0
kn_backspace db 'backspace',0
kn_del       db 'del',0
kn_delete    db 'delete',0
kn_ins       db 'ins',0
kn_insert    db 'insert',0
kn_home      db 'home',0
kn_end       db 'end',0
kn_pgup      db 'pgup',0
kn_pageup    db 'pageup',0
kn_pgdn      db 'pgdn',0
kn_pagedown  db 'pagedown',0
kn_up        db 'up',0
kn_down      db 'down',0
kn_left      db 'left',0
kn_right     db 'right',0
kn_f1  db 'f1',0
kn_f2  db 'f2',0
kn_f3  db 'f3',0
kn_f4  db 'f4',0
kn_f5  db 'f5',0
kn_f6  db 'f6',0
kn_f7  db 'f7',0
kn_f8  db 'f8',0
kn_f9  db 'f9',0
kn_f10 db 'f10',0
kn_f11 db 'f11',0
kn_f12 db 'f12',0
key_table label dword
    dd offset kn_esc,       01Bh
    dd offset kn_escape,    01Bh
    dd offset kn_enter,     00Dh
    dd offset kn_return,    00Dh
    dd offset kn_tab,       009h
    dd offset kn_space,     020h
    dd offset kn_bksp,      008h
    dd offset kn_backspace, 008h
    dd offset kn_del,       02Eh
    dd offset kn_delete,    02Eh
    dd offset kn_ins,       02Dh
    dd offset kn_insert,    02Dh
    dd offset kn_home,      024h
    dd offset kn_end,       023h
    dd offset kn_pgup,      021h
    dd offset kn_pageup,    021h
    dd offset kn_pgdn,      022h
    dd offset kn_pagedown,  022h
    dd offset kn_up,        026h
    dd offset kn_down,      028h
    dd offset kn_left,      025h
    dd offset kn_right,     027h
    dd offset kn_f1,  070h
    dd offset kn_f2,  071h
    dd offset kn_f3,  072h
    dd offset kn_f4,  073h
    dd offset kn_f5,  074h
    dd offset kn_f6,  075h
    dd offset kn_f7,  076h
    dd offset kn_f8,  077h
    dd offset kn_f9,  078h
    dd offset kn_f10, 079h
    dd offset kn_f11, 07Ah
    dd offset kn_f12, 07Bh
    dd 0, 0

.code
; winactivate_substr ( "substr" -- )
sc_winactivate_substr:
    pushad
    mov    dword ptr [fws_match_hwnd], 0
    call   scr_pop                     ; len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [fws_substr_len], ecx
    call   scr_pop                     ; ptr
    or     ecx, ecx
    jz     was_done
    mov    esi, eax
    mov    edi, offset fws_substr_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    push   0
    push   offset enum_win_proc
    call   EnumWindows
    mov    eax, [fws_match_hwnd]
    or     eax, eax
    jz     was_done
    push   eax
    call   SetForegroundWindow
was_done:
    popad
    ret

; key ( "name" -- ) - one bare keypress via SendInput (down + up)
sc_key:
    pushad
    call   scr_pop                     ; len
    mov    ecx, eax
    call   scr_pop                     ; ptr
    or     ecx, ecx
    jz     sk_done
    cmp    ecx, 15
    jbe    @f
    mov    ecx, 15
@@: mov    [key_name_len], ecx
    mov    esi, eax                     ; src
    mov    edi, offset key_name_buf
    mov    edx, ecx                     ; counter (survives)
sk_copy:
    test   edx, edx
    jz     sk_copy_done
    mov    al, [esi]
    cmp    al, 'A'
    jb     sk_lc_ok
    cmp    al, 'Z'
    ja     sk_lc_ok
    add    al, 20h                      ; lowercase
sk_lc_ok:
    mov    [edi], al
    inc    esi
    inc    edi
    dec    edx
    jmp    sk_copy
sk_copy_done:
    mov    byte ptr [edi], 0
    ; --- match against key_table (names are lowercase asciiz) ---
    mov    esi, offset key_table
sk_scan:
    mov    ebx, [esi]                   ; name ptr (0 = end of table)
    or     ebx, ebx
    jz     sk_single
    mov    edi, offset key_name_buf
sk_cmp:
    mov    al, [ebx]
    cmp    al, [edi]
    jne    sk_cmp_no
    or     al, al
    jz     sk_found                     ; both NUL = match
    inc    ebx
    inc    edi
    jmp    sk_cmp
sk_cmp_no:
    add    esi, 8                        ; next entry (name + vk)
    jmp    sk_scan
sk_found:
    mov    eax, [esi+4]                  ; vk
    jmp    sk_press
sk_single:
    ; not named; single letter/digit -> its VK
    cmp    dword ptr [key_name_len], 1
    jne    sk_done
    movzx  eax, byte ptr [key_name_buf]
    cmp    al, 'a'
    jb     sk_chk_digit
    cmp    al, 'z'
    ja     sk_done
    sub    al, 20h                       ; letter VK = uppercase ascii
    jmp    sk_press
sk_chk_digit:
    cmp    al, '0'
    jb     sk_done
    cmp    al, '9'
    ja     sk_done
    ; digit VK = its ascii code (0x30..0x39)
sk_press:
    mov    dword ptr [sni_input_buf+0], 1     ; INPUT_KEYBOARD
    mov    word  ptr [sni_input_buf+4], ax    ; wVk
    mov    word  ptr [sni_input_buf+6], 0
    mov    dword ptr [sni_input_buf+8], 0     ; key down
    mov    dword ptr [sni_input_buf+12], 0
    mov    dword ptr [sni_input_buf+16], 0
    push   28
    push   offset sni_input_buf
    push   1
    call   SendInput
    mov    dword ptr [sni_input_buf+8], 2     ; key up (KEYEVENTF_KEYUP)
    push   28
    push   offset sni_input_buf
    push   1
    call   SendInput
sk_done:
    popad
    ret

; ===========================================================================
;  winclose ( "substr" -- ) - post WM_CLOSE to the first top-level window whose
;    title CONTAINS substr. Cleaner than focus+Alt+F4: no focus dependency, and
;    it targets exactly that window. Reuses enum_win_proc + fws_* .
; ===========================================================================
sc_winclose:
    pushad
    mov    dword ptr [fws_match_hwnd], 0
    call   scr_pop                     ; len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [fws_substr_len], ecx
    call   scr_pop                     ; ptr
    or     ecx, ecx
    jz     wcl_done
    mov    esi, eax
    mov    edi, offset fws_substr_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    push   0
    push   offset enum_win_proc
    call   EnumWindows
    mov    eax, [fws_match_hwnd]
    or     eax, eax
    jz     wcl_done
    push   0
    push   0
    push   10h                          ; WM_CLOSE
    push   eax                          ; hwnd
    call   PostMessageA
wcl_done:
    popad
    ret

; ===========================================================================
;  winmin / winmax ( "substr" -- ) - minimize / maximize the first window whose
;    title CONTAINS substr. keydown / keyup ( "name" -- ) - press or release one
;    bare key (hold a key across other actions, then release). Same key names as
;    the key command. All reuse existing helpers/data.
; ===========================================================================
.code
; fws_find ( "substr" -- eax=hwnd|0 ) - pop substr, EnumWindows substring match.
fws_find:
    mov    dword ptr [fws_match_hwnd], 0
    call   scr_pop                     ; len
    mov    ecx, eax
    cmp    ecx, 255
    jbe    @f
    mov    ecx, 255
@@: mov    [fws_substr_len], ecx
    call   scr_pop                     ; ptr
    or     ecx, ecx
    jz     ff_none
    mov    esi, eax
    mov    edi, offset fws_substr_buf
    push   ecx
    rep    movsb
    pop    ecx
    mov    byte ptr [edi], 0
    push   0
    push   offset enum_win_proc
    call   EnumWindows
    mov    eax, [fws_match_hwnd]
    ret
ff_none:
    xor    eax, eax
    ret

; winmin ( "substr" -- )
sc_winmin:
    pushad
    call   fws_find
    or     eax, eax
    jz     wmin_done
    push   6                            ; SW_MINIMIZE
    push   eax
    call   ShowWindow
wmin_done:
    popad
    ret

; winmax ( "substr" -- )
sc_winmax:
    pushad
    call   fws_find
    or     eax, eax
    jz     wmax_done
    push   3                            ; SW_MAXIMIZE
    push   eax
    call   ShowWindow
wmax_done:
    popad
    ret

; parse_key_vk ( "name" -- eax=vk | 0FFFFFFFFh ) - shared by keydown/keyup.
parse_key_vk:
    call   scr_pop                     ; len
    mov    ecx, eax
    call   scr_pop                     ; ptr
    or     ecx, ecx
    jz     pkv_bad
    cmp    ecx, 15
    jbe    @f
    mov    ecx, 15
@@: mov    [key_name_len], ecx
    mov    esi, eax
    mov    edi, offset key_name_buf
    mov    edx, ecx
pkv_copy:
    test   edx, edx
    jz     pkv_copy_done
    mov    al, [esi]
    cmp    al, 'A'
    jb     pkv_lc_ok
    cmp    al, 'Z'
    ja     pkv_lc_ok
    add    al, 20h
pkv_lc_ok:
    mov    [edi], al
    inc    esi
    inc    edi
    dec    edx
    jmp    pkv_copy
pkv_copy_done:
    mov    byte ptr [edi], 0
    mov    esi, offset key_table
pkv_scan:
    mov    ebx, [esi]
    or     ebx, ebx
    jz     pkv_single
    mov    edi, offset key_name_buf
pkv_cmp:
    mov    al, [ebx]
    cmp    al, [edi]
    jne    pkv_cmp_no
    or     al, al
    jz     pkv_found
    inc    ebx
    inc    edi
    jmp    pkv_cmp
pkv_cmp_no:
    add    esi, 8
    jmp    pkv_scan
pkv_found:
    mov    eax, [esi+4]                 ; vk
    ret
pkv_single:
    cmp    dword ptr [key_name_len], 1
    jne    pkv_bad
    movzx  eax, byte ptr [key_name_buf]
    cmp    al, 'a'
    jb     pkv_chk_digit
    cmp    al, 'z'
    ja     pkv_bad
    sub    al, 20h                       ; letter VK = uppercase ascii
    ret
pkv_chk_digit:
    cmp    al, '0'
    jb     pkv_bad
    cmp    al, '9'
    ja     pkv_bad
    ret                                  ; digit VK = its ascii (0x30..0x39)
pkv_bad:
    mov    eax, 0FFFFFFFFh
    ret

; key_send ( eax=vk, ecx=flags ) - one SendInput keyboard event.
key_send:
    mov    dword ptr [sni_input_buf+0], 1
    mov    word  ptr [sni_input_buf+4], ax
    mov    word  ptr [sni_input_buf+6], 0
    mov    dword ptr [sni_input_buf+8], ecx
    mov    dword ptr [sni_input_buf+12], 0
    mov    dword ptr [sni_input_buf+16], 0
    push   28
    push   offset sni_input_buf
    push   1
    call   SendInput
    ret

; keydown ( "name" -- )
sc_keydown:
    pushad
    call   parse_key_vk
    cmp    eax, 0FFFFFFFFh
    je     kd_done
    xor    ecx, ecx                      ; flags = 0 (key down)
    call   key_send
kd_done:
    popad
    ret

; keyup ( "name" -- )
sc_keyup:
    pushad
    call   parse_key_vk
    cmp    eax, 0FFFFFFFFh
    je     ku_done
    mov    ecx, 2                        ; KEYEVENTF_KEYUP
    call   key_send
ku_done:
    popad
    ret

; ===========================================================================
;  mousedown / mouseup ( "button" -- ) - press or release a mouse button at the
;    cursor's current position. button = left/l, right/r, middle/mid/m.
;    Pair with move for drags:  x1 y1 move "left" mousedown  x2 y2 move "left" mouseup
;    (plain click/rclick/dclick still exist for one-shot left/right clicks.)
; ===========================================================================
.data
mb_left   db 'left',0
mb_l      db 'l',0
mb_right  db 'right',0
mb_r      db 'r',0
mb_middle db 'middle',0
mb_mid    db 'mid',0
mb_m      db 'm',0
mbtn_table label dword
    dd offset mb_left,   0
    dd offset mb_l,      0
    dd offset mb_right,  1
    dd offset mb_r,      1
    dd offset mb_middle, 2
    dd offset mb_mid,    2
    dd offset mb_m,      2
    dd 0, 0
mbtn_down dd 00002h, 00008h, 00020h     ; LEFT/RIGHT/MIDDLE DOWN
mbtn_up   dd 00004h, 00010h, 00040h     ; LEFT/RIGHT/MIDDLE UP

.code
; parse_mouse_btn ( "button" -- eax=0/1/2 | 0FFFFFFFFh ). Reuses key_name_buf.
parse_mouse_btn:
    call   scr_pop                     ; len
    mov    ecx, eax
    call   scr_pop                     ; ptr
    or     ecx, ecx
    jz     pmb_bad
    cmp    ecx, 7
    jbe    @f
    mov    ecx, 7
@@: mov    esi, eax
    mov    edi, offset key_name_buf
    mov    edx, ecx
pmb_copy:
    test   edx, edx
    jz     pmb_copy_done
    mov    al, [esi]
    cmp    al, 'A'
    jb     pmb_lc
    cmp    al, 'Z'
    ja     pmb_lc
    add    al, 20h
pmb_lc:
    mov    [edi], al
    inc    esi
    inc    edi
    dec    edx
    jmp    pmb_copy
pmb_copy_done:
    mov    byte ptr [edi], 0
    mov    esi, offset mbtn_table
pmb_scan:
    mov    ebx, [esi]
    or     ebx, ebx
    jz     pmb_bad
    mov    edi, offset key_name_buf
pmb_cmp:
    mov    al, [ebx]
    cmp    al, [edi]
    jne    pmb_cmp_no
    or     al, al
    jz     pmb_found
    inc    ebx
    inc    edi
    jmp    pmb_cmp
pmb_cmp_no:
    add    esi, 8
    jmp    pmb_scan
pmb_found:
    mov    eax, [esi+4]                 ; button index 0/1/2
    ret
pmb_bad:
    mov    eax, 0FFFFFFFFh
    ret

; mouse_send ( ecx=dwFlags ) - one SendInput MOUSEINPUT event at cursor pos.
mouse_send:
    mov    dword ptr [sni_input_buf+0], 0     ; INPUT_MOUSE
    mov    dword ptr [sni_input_buf+4], 0     ; dx
    mov    dword ptr [sni_input_buf+8], 0     ; dy
    mov    dword ptr [sni_input_buf+12], 0    ; mouseData
    mov    dword ptr [sni_input_buf+16], ecx  ; dwFlags
    mov    dword ptr [sni_input_buf+20], 0    ; time
    mov    dword ptr [sni_input_buf+24], 0    ; dwExtraInfo
    push   28
    push   offset sni_input_buf
    push   1
    call   SendInput
    ret

; mousedown ( "button" -- )
sc_mousedown:
    pushad
    call   parse_mouse_btn
    cmp    eax, 0FFFFFFFFh
    je     msd_done
    mov    ecx, [mbtn_down + eax*4]
    call   mouse_send
msd_done:
    popad
    ret

; mouseup ( "button" -- )
sc_mouseup:
    pushad
    call   parse_mouse_btn
    cmp    eax, 0FFFFFFFFh
    je     msu_done
    mov    ecx, [mbtn_up + eax*4]
    call   mouse_send
msu_done:
    popad
    ret

; ===========================================================================
;  scroll ( notches -- ) - mouse wheel; +up / -down (each notch = 120 delta).
;  winmove ( x y "substr" -- ) - move the substring-matched window to (x,y).
;  winsize ( w h "substr" -- ) - resize the substring-matched window to w x h.
;  winmove/winsize use SetWindowPos (SWP_NOSIZE / SWP_NOMOVE) + fws_find.
; ===========================================================================
.data
wmv_hwnd dd 0
wmv_x    dd 0
wmv_y    dd 0

.code
; scroll ( notches -- )
sc_scroll:
    pushad
    call   scr_pop                     ; notches (signed)
    imul   eax, eax, 120                ; wheel delta = notches * WHEEL_DELTA
    mov    dword ptr [sni_input_buf+0], 0     ; INPUT_MOUSE
    mov    dword ptr [sni_input_buf+4], 0     ; dx
    mov    dword ptr [sni_input_buf+8], 0     ; dy
    mov    dword ptr [sni_input_buf+12], eax  ; mouseData = wheel delta
    mov    dword ptr [sni_input_buf+16], 0800h ; MOUSEEVENTF_WHEEL
    mov    dword ptr [sni_input_buf+20], 0
    mov    dword ptr [sni_input_buf+24], 0
    push   28
    push   offset sni_input_buf
    push   1
    call   SendInput
    popad
    ret

; winmove ( x y "substr" -- )
sc_winmove:
    pushad
    call   fws_find                    ; pops "substr" (top), returns eax=hwnd
    mov    [wmv_hwnd], eax
    call   scr_pop                     ; y
    mov    [wmv_y], eax
    call   scr_pop                     ; x
    mov    [wmv_x], eax
    cmp    dword ptr [wmv_hwnd], 0
    je     wmv_done
    ; SetWindowPos(hwnd, 0, x, y, 0, 0, SWP_NOSIZE|SWP_NOZORDER)
    push   5                            ; 1 (NOSIZE) | 4 (NOZORDER)
    push   0                            ; cy
    push   0                            ; cx
    push   [wmv_y]
    push   [wmv_x]
    push   0                            ; hWndInsertAfter
    push   [wmv_hwnd]
    call   SetWindowPos
wmv_done:
    popad
    ret

; winsize ( w h "substr" -- )
sc_winsize:
    pushad
    call   fws_find                    ; pops "substr", returns eax=hwnd
    mov    [wmv_hwnd], eax
    call   scr_pop                     ; h -> reuse wmv_y
    mov    [wmv_y], eax
    call   scr_pop                     ; w -> reuse wmv_x
    mov    [wmv_x], eax
    cmp    dword ptr [wmv_hwnd], 0
    je     wsz_done
    ; SetWindowPos(hwnd, 0, 0, 0, w, h, SWP_NOMOVE|SWP_NOZORDER)
    push   6                            ; 2 (NOMOVE) | 4 (NOZORDER)
    push   [wmv_y]                      ; cy = h
    push   [wmv_x]                      ; cx = w
    push   0                            ; Y
    push   0                            ; X
    push   0                            ; hWndInsertAfter
    push   [wmv_hwnd]
    call   SetWindowPos
wsz_done:
    popad
    ret

; ===========================================================================
;  clipset ( "str" -- )   - put str on the clipboard (CF_TEXT).
;  clipget ( -- ptr len ) - push the clipboard text (into clip_buf) onto the
;                           script stack; e.g. clipget type = paste-as-keystrokes.
;  winhide ( "substr" -- ) / winshow ( "substr" -- ) - SW_HIDE / SW_SHOW a
;                           substring-matched window (winhide removes it from
;                           the taskbar too; winshow brings it back).
; ===========================================================================
.data
clip_buf db 1024 dup (0)
cs_len   dd 0
cs_ptr   dd 0
cs_hmem  dd 0
cg_h     dd 0

.code
; clipset ( "str" -- )
sc_clipset:
    pushad
    call   scr_pop                     ; len
    mov    [cs_len], eax
    call   scr_pop                     ; ptr
    mov    [cs_ptr], eax
    push   0
    call   OpenClipboard
    or     eax, eax
    jz     cs_done
    call   EmptyClipboard
    mov    ecx, [cs_len]
    inc    ecx                          ; +1 for NUL
    push   ecx
    push   2                            ; GMEM_MOVEABLE
    call   GlobalAlloc
    or     eax, eax
    jz     cs_close
    mov    [cs_hmem], eax
    push   eax
    call   GlobalLock
    or     eax, eax
    jz     cs_close
    mov    edi, eax
    mov    esi, [cs_ptr]
    mov    ecx, [cs_len]
    rep    movsb
    mov    byte ptr [edi], 0
    push   [cs_hmem]
    call   GlobalUnlock
    push   [cs_hmem]
    push   1                            ; CF_TEXT
    call   SetClipboardData
cs_close:
    call   CloseClipboard
cs_done:
    popad
    ret

; clipget ( -- ptr len )
sc_clipget:
    pushad
    mov    byte ptr [clip_buf], 0        ; default empty
    push   0
    call   OpenClipboard
    or     eax, eax
    jz     cg_push
    push   1                            ; CF_TEXT
    call   GetClipboardData
    or     eax, eax
    jz     cg_close
    mov    [cg_h], eax
    push   eax
    call   GlobalLock
    or     eax, eax
    jz     cg_close
    mov    esi, eax                      ; clipboard text
    mov    edi, offset clip_buf
    mov    ecx, 1023
cg_copy:
    test   ecx, ecx
    jz     cg_copy_done
    mov    al, [esi]
    test   al, al
    jz     cg_copy_done
    mov    [edi], al
    inc    esi
    inc    edi
    dec    ecx
    jmp    cg_copy
cg_copy_done:
    mov    byte ptr [edi], 0
    push   [cg_h]
    call   GlobalUnlock
cg_close:
    call   CloseClipboard
cg_push:
    mov    eax, offset clip_buf
    call   scr_push                     ; ptr
    mov    esi, offset clip_buf
    xor    ecx, ecx
cg_strlen:
    cmp    byte ptr [esi+ecx], 0
    je     cg_strlen_done
    inc    ecx
    cmp    ecx, 1023
    jb     cg_strlen
cg_strlen_done:
    mov    eax, ecx
    call   scr_push                     ; len (top)
    popad
    ret

; winhide ( "substr" -- )
sc_winhide:
    pushad
    call   fws_find
    or     eax, eax
    jz     whid_done
    push   0                            ; SW_HIDE
    push   eax
    call   ShowWindow
whid_done:
    popad
    ret

; winshow ( "substr" -- )
sc_winshow:
    pushad
    call   fws_find
    or     eax, eax
    jz     wsho_done
    push   5                            ; SW_SHOW
    push   eax
    call   ShowWindow
wsho_done:
    popad
    ret
