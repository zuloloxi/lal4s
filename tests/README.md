# lal4s test suite

Script test sets. `smoke.txt` is lal4s-native; the rest are ported from
`D:\cf22\tests` and target one feature each.

## How to run

Each file defines a `:::` runner bound to **`Ctrl+Shift+B`** that chains its
`tname`/`expect_*` tests and ends with `tsummary`. Only one file is loaded at a
time (they share the hotkey), so pass the file on the command line:

```
lal4s.exe tests\smoke.txt      # load this suite
                               # press Ctrl+Shift+B to run it
                               # exit lal4s.exe
runtests.bat                   # greps lal4s_debug.log → exit code
```

Results (`[TEST ...] BEGIN/PASS/FAIL:` and `[TEST RUN] N pass, M fail`) go to
**`lal4s_debug.log`** in the working directory. Counts in the log are hex
(`00000003` = 3).

> Ported files' header comments still say `color_iw.exe` / `color_debug.log` —
> substitute `lal4s.exe` / `lal4s_debug.log`.

## Status vs the current command set

### ✅ Runs today (uses only lifted commands)

| File | Expect | Notes |
|---|---|---|
| `smoke.txt` | 3 pass, 0 fail | lal4s-native; launches Notepad (leaves it open). |
| `snippets_fail.txt` | 0 pass, 4 fail | Validates the FAIL log format + runner exit code 1. |
| `snippets_pass.txt` | 4 pass* | *`p2` targets the `ColorForth 22 for Win32` window (absent in lal4s) → that test FAILs; `p4` needs `Images\OpenButton.bmp` visible on screen. Retarget `p2` to a real window title for a clean all-pass. |
| `snippets_tests.txt` | 5 pass* | Uses `expect_no_img` + `expect_no_window` (now lifted). *`tC1` targets the `ColorForth 22 for Win32` window → FAILs until retargeted; `tC5` launches Notepad; `tC2/tC3` need `Images\OpenButton.bmp` visible. |
| `snippets_no_window.txt` | — | `expect_no_window_in` now lifted (`EnumWindows` substring). |
| `snippets_findwin.txt` | — | `findwin_substr` lifted; pushes matched hwnds. |
| `snippets_enumwins.txt` | — | `enumwins`/`enumwinsh` lifted; dumps the window list to the log (`[WINS]` lines). |
| `snippets_ctrl_text*.txt`, `snippets_no_ctrl_text.txt` | — | `expect_ctrl_text`/`_in` + `expect_no_ctrl_text_in` lifted. `snippets_ctrl_text.txt` targets the cf22 window — retarget. |
| `snippets_any_ctrl*.txt` | — | `expect_any_ctrl_text`/`_in` lifted (scan every child of a class). |
| `snippets_statusbar*.txt`, `snippets_no_statusbar.txt` | — | `expect_statusbar`/`_in` + `expect_no_statusbar_in` lifted. |
| `snippets_winctrls.txt` | — | `winctrls`/`winctrls_in` lifted (dump a window's child controls to the log). Targets the cf22 window — retarget. |
| `snippets_pixel_avg.txt`, `snippets_pix3eq*.txt` | — | `expect_pixel_avg`/`_any`, `expect_pix3eq`, `mouselog`, `ocr_digit`, `debug_box` all lifted. |
| `snippets_mouselog.txt`, `snippets_debug_box.txt` | — | `mouselog` / `debug_box` lifted (need `helpers.dll` for `debug_box`). |
| `snippets_winshot.txt`, `snippets_no_img_in.txt` | — | `winshot` lifted (needs `helpers.dll`'s `WinShot` export). |

**Every `snippets_*.txt` now runs** against the current build (some assert on the
`ColorForth 22 for Win32` window — retarget those to a window on your desktop,
and `winshot`/`debug_box` need `helpers.dll` present).

### 🌐 Web/CDP — lifted, but need a runtime

The `web*` commands are lifted, but `web_tests.txt`, `web_tests_fail.txt`,
`web_local_tests.txt`, `web_local_fail_tests.txt` need **`helpers.dll` with its
CDP exports** and an **Edge/Chrome** install to actually drive a page. Without
those the commands no-op / auto-fail rather than being unrecognized.

**All script commands are now lifted** — every test file's vocabulary resolves.

## Assets

`..\Images\OpenButton.bmp` (copied from cf22) backs the `expect_img` / `img*`
tests — open it in any viewer so it's visible on screen before running an
image test.
