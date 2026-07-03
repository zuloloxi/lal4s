# lal4s — extraction plan (standalone snippet/automation runner)

**Goal:** a standalone AHK-like snippet + script runner, extracted from the cf22
colorForth tool (`D:\cf22\color_iw.asm`) **without the Forth kernel**. The
snippet manager was originally the "run scripts like AHK" feature of cf22; this
pulls it into its own project so it (a) isn't entangled with colorForth and
(b) builds as a clean W^X PE with no runtime codegen (much lower AV signal;
see "AV rationale").

Source to lift from: **`D:\cf22\color_iw.asm`** (line numbers below are from the
state on 2026-07-02; re-grep if they drifted).

## Why this is feasible (the seam)

`run_script` is a **self-contained mini-interpreter**: its own stack
(`script_stk` / `scr_push` / `scr_pop`) and its own command table
(`sc_name_*` -> `sc_*` handlers). It does **not** use the Forth interpreter
(`INTER`/`ACCEPT`/`LOAD`/`spaces[]`). The only real coupling is:
1. **the message pump** — cf22 pumps Windows messages inside the Forth key-wait
   loop; lal4s uses a normal `GetMessage`/`DispatchMessage` loop (already
   written in `lal4s.asm`), and
2. **the window** — cf22's window is the Forth editor; lal4s uses a hidden
   window just for `WM_HOTKEY` + the tray callback (`create_msgwin` in
   `lal4s.asm`).

The `-kernel` flag in cf22 already proves the reverse split (Forth with the
snippet layer OFF), so the boundary is real.

## Files already scaffolded here

| File | State |
|---|---|
| `lal4s.asm` | NEW glue: `_start`/WinMain, message loop, `lal4s_wnd_proc`, `create_msgwin`, `remove_hook`. Has `LIFT`/`PRUNE` markers. |
| `win32.inc` | Win32 API PROTOs + includelibs (extracted from color_iw.asm). |
| `cl.bat` | Clean build (no W+X section, no exec stack). Toolchain on PATH; libs via absolute `/LIBPATH:D:\cf22\psdk2003\Lib`. |
| `resource.rc` + `lal4s.ico` | Icon (brown/yellow/green boxes). |
| `helpers.dll` | Reused as-is (image search + CDP web automation; loaded at runtime). |
| `snippets.txt` | Sample snippet config. |

## Routines to LIFT (from color_iw.asm) into a new `snippets.asm`

Create `snippets.asm`, paste these routines, then `include snippets.asm` near
the end of `lal4s.asm`.

| Group | Routines (line in color_iw.asm) |
|---|---|
| Script engine | `run_script` (3055), `scr_push` (3032), `scr_pop` (3042) |
| Primitives | the `sc_name_*` string table (~3267+), the `sc_cmd_table` (`dd offset sc_*`), and all **~80 `sc_*:` handlers** (send/click/move/keys/type/paste/enter/tab/wait/pixel*/img*/web*/expect_*/…) |
| Config | `parse_cmdline` (~1039, adapt), `parse_snippets_txt` (2527), `load_settings_txt` (2425), `load_default_skip_classes` (1006) |
| Input hook | `install_hook` (9665), `hook_proc` (9344-9660), the `SEND_KEY` macro (~215) + `sni_input_buf` data |
| Hotkeys | `register_hotkeys` (9226) — change `[hwndmain]` -> `[hwndmsg]` |
| Picker (optional) | `show_picker` (2018), `picker_wnd_proc` (2203-2319), `picker_edit_proc` (2327-2373) + picker data |
| Tray | `install_tray` (1257) + `tray_nid`/menu data — change `[hwndmain]` -> `[hwndmsg]`; add a `remove_tray` (NIM_DELETE) |
| DLL loaders | `load_image_dll` (4534) + the CDP `GetProcAddress` block (`lid_got_hmod` ~4544) + fn-ptr vars |
| Debug (optional) | `open_dbg_log`, `dbg_writez`/`dbg_writehex8`/`dbg_writecrlf`, SEH handler |

## Routines to DROP (the Forth kernel — do NOT lift)

`INTER`/`ACCEPT`/`KEY`/`LOAD`, `spaces[]`/`display[]`, the dictionary +
`forth0`/`forth2`/`macro*` tables, the editor (`E`/`eout`/`REFRESH`/`type0`/
`KEYBOARD`/`print_blk2x`/`cf22_status`), the co-routine (`ROUND`/`PAAUSE_`/`ACT`/
`SWITCH`/`show`), **`alloc_mem` (16 MB RWX JIT)** + `alloc_buffers`, the block
store (`map_blocks_file`/`blocks_adr`), all graphics, the `_STACK` segment
(Godd/Gods/mains — lal4s has no Forth data stack).

## PRUNE step (the main risk)

After lifting, grep the lifted code for Forth-state references and stub/remove:
`blk`, `xy`, `fore`, `H`, `ACCEPT`, `REFRESH`, `esi`/`Godd`, `list`, `board`.
Expected to be few/none (the `sc_*` primitives are Win32 calls using
`script_stk`, not the Forth data stack), but confirm each. Also confirm any
missing PROTO gets added to `win32.inc` (e.g. `RegisterClassExA`,
`CreateWindowExA`, `PostQuitMessage`, `UnhookWindowsHookEx`,
`GetModuleHandleA` — add if the extract didn't include them).

## Suggested incremental build order

1. **Compile the skeleton** with the lifts stubbed (empty `ret` procs) to get a
   linking `lal4s.exe` (hidden window + message loop + tray placeholder).
2. Lift `run_script` + `scr_push`/`scr_pop` + a couple `sc_*` (e.g. `keys`,
   `type`, `send`) + `parse_snippets_txt`; wire `WM_HOTKEY -> run_script`.
   Test one hotkey -> text expansion.
3. Add `install_hook`/`hook_proc` (global hotkeys / `:` shorthand).
4. Add the rest of the `sc_*` primitives (mouse/pixel/image via helpers.dll,
   CDP web via helpers.dll).
5. Add the CapsLock picker + tray menu.

## Build

`cl.bat` — note the **absence** of `/section:.text,ERW` and `/section:_STACK,ERW`
vs cf22. Put writable state in `.data` (default) so `.text` stays read-execute.
Result: clean W^X, no RWX region, no self-modifying section.

## AV rationale (why this project helps)

cf22's `TIE/Suspect` is a **cloud-reputation** false positive driven by: (a) the
Forth **runtime codegen / RWX JIT** and W+X section, (b) the input-automation
API combo, (c) unsigned + rare. lal4s **eliminates (a)** entirely (no Forth =
no JIT; clean W^X) — the biggest heuristic trigger. It still has (b) the LL hook
+ `SendInput` (the tool's honest purpose, far more defensible in a scoped
text-expander) and (c) unsigned/rare, so **code-sign lal4s.exe** to clear the
reputation verdict. See `D:\cf22\docs\AV_FALSE_POSITIVE.md` for the full
analysis and the signing/exclusion options.
