# lal4s

A standalone snippet / automation runner (AHK-like): global hotkeys → text
expansion, plus a small script language (`keys`/`click`/`move`/`type`/`send`/
`pixel*`/`img*`/`web*`/`expect_*`) driven by a self-contained mini-interpreter.

It's the "run scripts like AHK" feature extracted out of the cf22 colorForth
tool (`D:\cf22`) into its own project — **no Forth kernel**, so it builds as a
clean W^X PE with no runtime code generation.

## Status: full command parity

The snippet engine and **all 68 script commands** have been lifted from
`D:\cf22\color_iw.asm` into `snippets.asm` — the lal4s and cf22 command sets are
at parity. Working: `::` hotstring text expansion via the LL keyboard hook,
`!`-bound global hotkeys, and the whole `:::` script vocabulary — keyboard/mouse
(`type send paste enter tab wait move click rclick dclick`), pixels
(`pixelcolor pixelwait pix3eq ocr_digit mouselog`), image search
(`imgfind`/`imgclick`/`imgwait` × full-screen/`in`/`c`/`inc`), windows/process
(`winactivate winwait run findwin_substr enumwins enumwinsh`), the test
framework (`tname tpass tfail tsummary` + the full `expect_*` suite: pixel /
image / window / `ctrl_text` / `statusbar` families with `_in`/`no_` variants),
`helpers.dll` utilities (`winshot debug_box`), and the `web*` CDP group
(`weburl`/`webeval`/`expect_dom`/…). A `dbg_*` log writes `lal4s_debug.log`.

`load_image_dll` resolves `helpers.dll`'s `ImageSearch` / `WinShot` / `DebugBox`
/ CDP exports; each command no-ops if its export is absent. lal4s runs
windowless with a **tray icon** (default) — right-click it for **Exit** — and a
**CapsLock snippet picker** (a filterable listbox: type to filter, Up/Down to
move, Enter/Shift+Enter to paste Part 1/2, Esc to cancel).

Two UIA extras (need `helpers.dll`): **Ctrl+Shift+Space** lists a Chromium
browser's tabs in the picker (Enter switches), and **Ctrl+Alt+R** clicks
"reject all" on a cookie/consent banner. The port is **complete**: everything
from cf22's automation layer is carried over except the Forth kernel (by design)
and the Ctrl+Shift+D `UIADump` diagnostic. See **`SCRIPTING.md`** for the command
reference and **`EXTRACTION_PLAN.md`** for history.

| File | Purpose |
|---|---|
| `lal4s.asm` | Entry point, Windows message loop, `wnd_proc`, hidden window. `include snippets.asm` at the end. |
| `snippets.asm` | The lifted snippet engine, script primitives, config parsers, hotkeys, and LL hook. |
| `win32.inc` | Win32 API PROTOs. |
| `cl.bat` | Build (clean flags — no writable/executable code section). |
| `*.lib` | Local copies of kernel32/gdi32/user32/shell32 import libs (`/LIBPATH:.`). |
| `resource.rc`, `lal4s.ico` | Application icon. |
| `helpers.dll` | Image-search + CDP web automation (loaded at runtime; used once `load_image_dll` is lifted). |
| `snippets.txt` | Sample snippet config. |
| `SCRIPTING.md` | How to write & run `::`/`:::` snippets — language, command reference, examples, design origins. |
| `tests/` | Script test suites (`smoke.txt` + cf22 ports) — see `tests/README.md`. |
| `runtests.bat` | Greps `lal4s_debug.log` for `FAIL:` and sets an exit code. |
| `Images/OpenButton.bmp` | Landmark bitmap for the `img*` / `expect_img` examples. |
| `EXTRACTION_PLAN.md` | The full port roadmap. |

## Build

Needs the MASM 6 toolchain (`ml`/`rc`/`cvtres`/`link`) on PATH — run `cl.bat`
from a MASM/VS developer prompt. Import libs are kept locally (`/LIBPATH:.`).
`ml`/`cvtres`/`link` are in this folder; `rc` comes from
`D:\cf22\psdk2003\Bin` (put it on PATH before running `cl.bat`).

```
cl.bat            → #### SUCCESS #### → lal4s.exe
```

Builds clean **W^X**: `.text` = Execute/Read, `.data` = Read/Write, no
writable+executable (RWX) section — the whole point vs cf22's JIT/`.text,ERW`.

Note: `snippets.txt`'s later examples exercise script words not yet lifted
(`run`, `winwait`, `pixel*`, `img*`, `expect_*`); `run_script` silently
ignores unknown words, so those snippets are no-ops for now rather than errors.

## Next steps

1. Compile the skeleton with lifts stubbed → get a linking `lal4s.exe`.
2. Lift `run_script` + `scr_push`/`scr_pop` + `parse_snippets_txt` + a few
   `sc_*` primitives; wire `WM_HOTKEY → run_script`; test one hotkey.
3. Add the hook, the rest of the primitives, the picker + tray.
4. **Code-sign** `lal4s.exe` (clears the AV reputation flag that hit the cf22
   builds — see `D:\cf22\docs\AV_FALSE_POSITIVE.md`).

## Origin / credits

Derived from cf22 (Chuck Moore's colorForth 2003, Win32 MASM port). The Forth
IDE stays in `D:\cf22`; lal4s takes only the automation layer.
