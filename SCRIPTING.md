# lal4s scripting guide

lal4s runs two kinds of snippets, both defined in **`snippets.txt`**:

- **Text snippets** (`::`) — expand a typed abbreviation (or a hotkey) into
  literal text via the clipboard + Ctrl+V.
- **Script snippets** (`:::`) — run a small stack-based script of commands
  (type, click, wait, image-search, window control, assertions, …).

This document covers the **script** language. For a quick text snippet you only
need the `::` form (see [Text snippets](#text-snippets)).

---

## 1. Anatomy of `snippets.txt`

Each entry starts with a marker line and is followed by its body until the next
marker or end of file.

```
:: short [! Mods+VK]         ← text snippet   (body = literal text)
::: short [! Mods+VK]        ← script snippet (body = commands)
```

- **`short`** — the abbreviation you type to trigger it (letters/digits). May be
  omitted if you only want a hotkey.
- **`! Mods+VK`** — optional global hotkey (see [Hotkeys](#4-hotkeys)).
- Lines starting with `#` are comments. Blank lines outside a body are ignored.

Two trigger mechanisms:

| Trigger | How it fires |
|---|---|
| **Hotstring** | You type `short` followed by an *end character* (space, tab, enter, `.` `,` `;` `?`). The typed short is erased (text snippets) and the body runs. |
| **Hotkey** | You press the bound `Mods+VK`. Nothing is erased. |

> The keyboard hook is **suppressed in terminals** (cmd, PowerShell, Windows
> Terminal, PuTTY, mintty, …) so hotstrings don't interfere with typing there.
> Add more classes with `::skip <ClassName>` or `settings.txt` (see §7).

---

## 2. The script language

A script body is a sequence of **tokens** separated by whitespace/newlines.
There are exactly three token kinds:

| Token | Example | Effect |
|---|---|---|
| **Number** | `500`, `-3`, `0xFF00` | Push the integer onto the stack. Decimal, or `0x`-prefixed hex; optional leading `-`. |
| **String** | `"hello world"` | Push `(ptr, len)` onto the stack (`len` ends up on top). |
| **Identifier** | `wait`, `imgclick` | Look up in the command table and execute it. |

`#` starts a line comment (rest of the line is skipped). Unknown identifiers are
**silently ignored** — a typo aborts nothing; the word is just skipped.

### The stack model

Execution is **postfix / RPN**, like Forth or an HP calculator. Commands take
their arguments from a private 32-slot integer stack and push results back.
Arguments are written *before* the command:

```
100 200 move          →  move( x=100, y=200 )
"notepad" run         →  run( "notepad" )
500 wait              →  wait( 500 ms )
```

Stack effects are written `( inputs -- outputs )`, top-of-stack on the **right**:

```
pixelcolor ( x y -- bgr )       ; pops y then x, pushes the pixel color
imgfind    ( "f" tol -- cx cy found )
```

Notes:
- The stack is **reset to empty** at the start of every run.
- A string literal pushes **two** cells: pointer then length. Commands that take
  a string (`type`, `run`, `imgclick`, …) document it as `"str"` but consume both.
- Popping an empty stack yields `0` (no crash).
- Max depth 32; overflow silently drops.

---

## 3. Command reference

Only the commands below are implemented today. (Others from the source —
`web*`, `ocr_digit`, the `ctrl_text`/`statusbar` assertions, … — are not lifted
yet and will be ignored if used.)

### Keyboard / text

| Command | Stack | Description |
|---|---|---|
| `type` | `( "str" -- )` | Types the string as Unicode keystrokes into the focused control. |
| `send` | `( "combo" -- )` | Sends a **modifier chord**, e.g. `"ctrl+v"`, `"shift+a"`, `"ctrl+shift+t"`. Requires at least one modifier (for a bare Enter/Tab use `enter`/`tab`). |
| `key` | `( "name" -- )` | Presses one **bare key** (no modifier) as a real keystroke: `esc enter tab space backspace del insert home end pgup pgdn up down left right f1`..`f12`, or a single letter/digit. |
| `keydown` | `( "name" -- )` | Press a key **and hold** it (no release) — same names as `key`. |
| `keyup` | `( "name" -- )` | Release a held key. |
| `paste` | `( -- )` | Releases held modifiers, then Ctrl+V. |
| `clipset` | `( "str" -- )` | Put `str` on the clipboard (CF_TEXT). |
| `clipget` | `( -- ptr len )` | Push the current clipboard text onto the stack. `clipget type` = paste-as-keystrokes (works where Ctrl+V is blocked, e.g. PuTTY). |
| `enter` | `( -- )` | Presses Enter. |
| `tab` | `( -- )` | Presses Tab. |
| `wait` | `( ms -- )` | Sleeps `ms` milliseconds. |

### Mouse

| Command | Stack | Description |
|---|---|---|
| `move` | `( x y -- )` | Moves the cursor to absolute screen `(x, y)`. |
| `click` | `( -- )` | Left click at the current position. |
| `rclick` | `( -- )` | Right click. |
| `dclick` | `( -- )` | Double left click. |
| `mousedown` | `( "button" -- )` | Press-and-hold a mouse button: `left`/`l`, `right`/`r`, `middle`/`mid`/`m`. |
| `mouseup` | `( "button" -- )` | Release a mouse button. Pair with `move` for drags. |
| `scroll` | `( notches -- )` | Mouse wheel: **positive = up, negative = down** (each notch = one wheel click). |

### Pixels

Colors are Win32 `COLORREF` values, `0x00BBGGRR` (blue high byte, red low):

| Color | Decimal | Hex |
|---|---|---|
| white | `16777215` | `0xFFFFFF` |
| black | `0` | `0x000000` |
| red | `255` | `0x0000FF` |
| green | `65280` | `0x00FF00` |
| blue | `16711680` | `0xFF0000` |

| Command | Stack | Description |
|---|---|---|
| `pixelcolor` | `( x y -- bgr )` | Reads the screen pixel; pushes its color (`0xFFFFFFFF` on failure). |
| `pixelwait` | `( x y bgr ms -- )` | Polls every 50 ms until the pixel equals `bgr` or `ms` elapses. |
| `pix3eq` | `( x1 y1 c1 x2 y2 c2 x3 y3 c3 tol -- 0\|1 )` | Pushes 1 if all three pixels match their colors within `tol` per channel. |
| `ocr_digit` | `( base_x base_y -- digit\|-1 )` | 3-pixel-fingerprint OCR of a single digit glyph at `(base_x, base_y)`; pushes `0..9` or `-1`. |
| `mouselog` | `( -- )` | Log the cursor position + the pixel color under it (`[MOUSE]` line) — calibration helper for `pix3eq`/`ocr_digit`. |

### Image search

`tol` = per-channel tolerance (`0` = exact, `~20–50` for anti-aliased UI). The
`*c` / `*inc` variants use the built-in BMP scanner (no DLL, **BMP only**); the
others use `helpers.dll`'s `ImageSearch` (BMP always; PNG if the DLL has GDI+).
`find` pushes `cx cy found`; `click` moves+clicks the center; `wait` polls.

| Full screen | Rect-bound (`x1 y1 x2 y2` first) | Inline BMP (no DLL) |
|---|---|---|
| `imgfind ( "f" tol -- cx cy found )` | `imgfindin` | `imgfindc` / `imgfindinc` |
| `imgclick ( "f" tol -- )` | `imgclickin` | `imgclickc` / `imgclickinc` |
| `imgwait ( "f" tol ms -- )` | `imgwaitin` | `imgwaitc` / `imgwaitinc` |

`imgclick` example: `"Images\OpenButton.bmp" 50 imgclick`.

### Windows / processes

| Command | Stack | Description |
|---|---|---|
| `winactivate` | `( "title" -- )` | `FindWindow` by exact title; brings it to the foreground. |
| `winactivate_substr` | `( "substr" -- )` | Foreground the first window whose title **contains** `substr` (for fluctuating titles: browsers, editors). Pairs with `send`/`type`/`key`. |
| `winclose` | `( "substr" -- )` | Close (post `WM_CLOSE` to) the first window whose title contains `substr`. No focus needed; targets exactly that window. |
| `winmin` | `( "substr" -- )` | Minimize the first window whose title contains `substr`. |
| `winmax` | `( "substr" -- )` | Maximize the first window whose title contains `substr`. |
| `winmove` | `( x y "substr" -- )` | Move the substring-matched window to screen `(x, y)` (keeps its size). |
| `winsize` | `( w h "substr" -- )` | Resize the substring-matched window to `w × h` (keeps its position). |
| `winhide` | `( "substr" -- )` | Hide the window (`SW_HIDE` — also removes its taskbar button). |
| `winshow` | `( "substr" -- )` | Un-hide the window (`SW_SHOW`). |
| `winwait` | `( "title" ms -- )` | Polls for the window up to `ms`, then activates it. |
| `run` | `( "cmdline" -- )` | Launches a process (detached). |
| `findwin_substr` | `( "substr" -- hwnd )` | First top-level window whose title **contains** `substr` (`0` if none). |
| `enumwins` | `( -- )` | Log every visible titled top-level window (`[WINS]` lines). |
| `enumwinsh` | `( -- )` | Like `enumwins`, also including hidden/nameless windows. |

### Test framework (writes to `lal4s_debug.log`)

Assertions have **no visible effect** — they record PASS/FAIL to the log. A
`tname` opens a test; the next `tname`/`tsummary` closes it with an implicit PASS
unless something failed.

| Command | Stack | Description |
|---|---|---|
| `tname` | `( "name" -- )` | Begin a named test. |
| `tpass` | `( -- )` | Explicit pass (optional). |
| `tfail` | `( "reason" -- )` | Force a fail with a reason. |
| `tsummary` | `( -- )` | Log `[TEST RUN] N pass, M fail`. |
| `expect_pixel` | `( x y color tol -- )` | Fail unless the pixel matches within `tol`. |
| `expect_img` | `( "fname" tol -- )` | Fail unless the image is on screen. |
| `expect_window` | `( "title" -- )` | Fail unless the window exists. |
| `expect_no_img` | `( "fname" tol -- )` | Inverse: fail if the image **is** on screen. |
| `expect_no_window` | `( "title" -- )` | Inverse: fail if the window **does** exist. |
| `expect_no_img_in` | `( "substr" "fname" tol -- )` | Fail if the image is found inside a window whose title contains `substr` (vacuous pass if none). |
| `expect_no_window_in` | `( "substr" -- )` | Fail if any top-level window title contains `substr`. |
| `expect_ctrl_text` | `( "title" "class" "expected" -- )` | Fail unless a `class` child of the `title` window's `WM_GETTEXT` contains `expected`. |
| `expect_ctrl_text_in` | `( "substr" "class" "expected" -- )` | As above, but the parent is found by title **substring**. |
| `expect_no_ctrl_text_in` | `( "substr" "class" "expected" -- )` | Inverse: fail if `expected` **is** present. |
| `expect_any_ctrl_text` | `( "title" "class" "expected" -- )` | Scans **every** `class` child; pass if any contains `expected` (tab-order independent). |
| `expect_any_ctrl_text_in` | `( "substr" "class" "expected" -- )` | Scan-all-children + substring parent. |
| `expect_statusbar` | `( "title" partN "expected" -- )` | Fail unless the window's status bar part `partN` contains `expected` (`partN 0` = whole bar via `WM_GETTEXT`). |
| `expect_statusbar_in` | `( "substr" partN "expected" -- )` | As above, substring parent. |
| `expect_no_statusbar_in` | `( "substr" partN "expected" -- )` | Inverse status-bar assertion. |
| `winctrls` | `( "title" -- )` | Log every child control (hwnd/class/text) of the exact-title window (`[CTRLS]` lines). |
| `winctrls_in` | `( "substr" -- )` | As `winctrls`, parent found by title substring. |
| `expect_pixel_avg` | `( x y color tol -- )` | Fail unless the 3×3 average at `(x,y)` matches `color` within `tol`. |
| `expect_pixel_any` | `( x y color tol -- )` | Fail unless **some** pixel in the 3×3 grid matches. |
| `expect_pix3eq` | `( x1 y1 c1 … c3 tol -- )` | Test-framework wrapper around `pix3eq` (logs which slot mismatched). |

### helpers.dll utilities

These call `helpers.dll` (loaded at startup); they silently no-op if the DLL or
export is missing.

| Command | Stack | Description |
|---|---|---|
| `winshot` | `( "title" "outpath" -- )` | `PrintWindow` capture of a window to `outpath` (`.bmp`) — works on minimized/covered windows. |
| `debug_box` | `( L T R B ms -- )` | Flash an XOR rectangle outline on screen for `ms` — visualize search rects / coordinates. |
| `winshotevery` | `( "title" "prefix" interval_ms limit_count limit_ms -- )` | Start a **background** timer job: capture `<title>` to `<prefix>NNNNN.bmp` every `interval_ms`. Stops after `limit_count` images (if >0) **or** `limit_ms` elapsed (if >0); both `0` = until stopped/exit. Up to 8 jobs run in parallel. |
| `winshotstop` | `( "title" -- )` | Stop the running capture job for that window title. |
| `winshotstopall` | `( -- )` | Stop all capture jobs. |

`winshotevery` returns immediately and keeps lal4s responsive (it uses a Win32
timer, not a blocking loop). Filenames auto-increment (`prefix00001.bmp`,
`prefix00002.bmp`, …) so nothing overwrites. Jobs are keyed by window title.

### Web automation (CDP)

Drives Edge/Chrome over the DevTools Protocol via `helpers.dll`'s CDP exports.
`weburl` launches a browser on a debug port (with its own profile) and sets the
"current port"; the rest operate on it. No-op / auto-fail if the DLL export is
missing. The `expect_*` variants feed the test framework.

| Command | Stack | Description |
|---|---|---|
| `weburl` | `( "url" port -- )` | Launch Edge on `port` + connect; sets the current port. |
| `webeval` | `( "js" -- )` | Run JS (`Runtime.evaluate`); result stashed internally. |
| `weblog` | `( "js" -- )` | Like `webeval`, but writes `[weblog] <js> => <result>` to `lal4s_debug.log` — for inspecting page values while debugging. |
| `expect_dom` | `( "selector" -- )` | Pass iff `document.querySelector(selector)` exists. |
| `expect_js` | `( "js" -- )` | Pass iff the JS boolean expression is `true`. |
| `expect_no_console_errors` | `( -- )` | Pass iff no console errors were captured. |
| `expect_no_net_failures` | `( -- )` | Pass iff no failed/4xx-5xx requests were captured. |
| `webclear` | `( -- )` | Reset the captured console/network logs. |
| `webwatch` | `( "healthJS" interval_ms count -- )` | Poll page health `count` times; fail+stop on first BROKEN/DEAD. |
| `webclose` | `( -- )` | Disconnect the current port. |

---

## 4. Hotkeys

Append `! Mods+VK` to a marker line:

```
Mods: Ctrl  Alt  Shift  Win     (case-insensitive, '+' separated)
VK:   A..Z   0..9   F1..F12
```

At least one modifier is required. Examples:

```
::: save ! Ctrl+Shift+S
::: reload ! Ctrl+F5
::  ! Ctrl+Alt+M              ← hotkey only, no typed short
```

Snippet index doubles as the hotkey id, so the same body runs whether triggered
by hotstring or hotkey.

---

## 5. Worked examples

### A. Text snippet (no scripting)
```
:: br
Best Regards!
```
Type `br` then space → `br ` is erased and `Best Regards!` is pasted.

### B. Type + navigate a form
```
::: login ! Ctrl+Shift+L
"myusername" type
tab
"secret123" type
enter
```
Types the username, Tab to the next field, types the password, submits.

### C. Launch an app and wait for it
```
::: np ! Ctrl+Shift+N
"notepad" run
"Untitled - Notepad" 3000 winwait
"hello from a lal4s script" type
```
Runs Notepad, waits up to 3 s for its window, focuses it, types.

### D. Image-driven click
```
::: openbtn ! Ctrl+Shift+O
"Images\OpenButton.bmp" 50 5000 imgwait
```
Waits up to 5 s for the button bitmap to appear, then moves+clicks its center.
Faster, rect-bound form:
```
0 0 960 540 "Images\OpenButton.bmp" 50 imgclickin
```

### E. Pixel gate
```
::: gate ! Ctrl+Shift+G
10 10 16777215 5000 pixelwait      # wait until (10,10) turns white, ≤5s
10 10 move click                   # then click there
```

### F. Assertion run (results in the log)
```
::: smoke ! Ctrl+Shift+B
"pixel_top_left_black" tname
0 0 0 30 expect_pixel
"button_visible" tname
"Images\OpenButton.bmp" 50 expect_img
"notepad_open" tname
"Untitled - Notepad" expect_window
tsummary
```
Produces `[TEST ...] BEGIN/PASS/FAIL:` lines and a final
`[TEST RUN] N pass, M fail` in `lal4s_debug.log`.

---

## 6. Running scripts

1. **Build** (once): `cl.bat` → `lal4s.exe`.
2. **Put `snippets.txt` next to `lal4s.exe`** (or pass a path as the first
   argument: `lal4s.exe D:\configs\my_snippets.txt`). Any `Images\*.bmp`
   referenced by `img*` commands are resolved relative to the working directory.
3. **Launch `lal4s.exe`.** It has no window — it registers the hotkeys and the
   keyboard hook and sits in the message loop.
4. **Trigger** a script by typing its short (+ end char) or pressing its hotkey.
5. **Exit**: end the `lal4s.exe` process (Task Manager, or `taskkill /im
   lal4s.exe`). On exit it unhooks and unregisters cleanly.

### The CapsLock picker
Press **CapsLock** anywhere to open a filterable list of your snippets (columns:
short / hotkey / Part 1 / Part 2). Type to filter (matches the short or the
body), **Up/Down/PgUp/PgDn** to move the selection, **Enter** to paste Part 1,
**Shift+Enter** to paste Part 2 (the text before / after a `|` in the body), and
**Esc** to cancel. Runs windowless from the tray otherwise; right-click the tray
icon for **Exit**.

### Browser & consent shortcuts (UIA, need `helpers.dll`)
- **Ctrl+Shift+Space** over a Chromium browser → the same picker, but listing the
  browser's **open tabs** (via UIA); type to filter, Enter to switch to that tab.
- **Ctrl+Alt+R** → **reject-all** on a cookie/consent banner in the foreground
  window (clicks the "Reject all" button found via UIA). Debounced so key-repeat
  can't stack runs.

Both no-op if `helpers.dll` (with its `TabNav*` / `ConsentRejectAll` exports)
isn't loaded.

### Reloading after edits
`snippets.txt` is parsed **once at startup**. After editing it, restart
`lal4s.exe` to pick up changes.

### Debug log
`open_dbg_log` creates **`lal4s_debug.log`** in the working directory
(overwritten each run). Test-framework and `expect_*` output goes here; it's the
only way to see assertion results. Tail it while triggering scripts.

---

## 7. Gotchas & tips

- **Postfix order.** Arguments come *before* the command: `100 200 move`, not
  `move 100 200`.
- **`send` needs a modifier.** `"enter" send` does nothing; use the `enter`
  command. `"ctrl+v"`, `"shift+a"`, `"ctrl+shift+t"` are fine.
- **Exact window titles.** `winactivate`/`winwait`/`expect_window` match the
  full title exactly (e.g. `Untitled - Notepad`), not a substring.
- **BMP for the inline engine.** `imgfindc`/`imgclickc`/… only read `.bmp`
  (24/32-bpp, uncompressed). The DLL variants also do PNG if the DLL supports it.
- **Unknown words are ignored.** Handy for forward-compat, but a misspelled
  command fails silently — check the log if a script "does nothing."
- **Terminals are skipped** by the hotstring hook. Trigger those via hotkeys, or
  add classes with `::skip <Class>` in `snippets.txt` / `skip=<Class>` in
  `settings.txt`.
- **Numbers are integers.** No floats; colors and coordinates are whole numbers.

---

## 8. Text snippets

For completeness — a `::` body is copied verbatim (leading/trailing blank lines
trimmed) to the clipboard and pasted:

```
:: addr
123 Main St
Apt 4B

:: pw ! Ctrl+Shift+P
Password123+
```

`addr` + end char pastes both lines; `Ctrl+Shift+P` pastes the password anywhere.

---

## Appendix A — design origins (from cf22)

lal4s's script engine is lifted from the cf22 colorForth tool's "snippet
manager." The original design docs live in `D:\cf22` and are worth reading for
rationale and for the roadmap of features not yet ported here:

- **`D:\cf22\notes\SNIPPET_PHASE3_ROADMAP.md`** — the DSL design. Why `:::`
  marks a script (vs `::` text), the Forth-style RPN token model + the separate
  32-slot `script_stk`, the Phase 3A/3B command table with stack effects and
  Win32 backing, and the open design questions that shaped today's behavior:
  - `send` uses the same `ctrl+`/`alt+`/`shift+`/`win+` combo parser as hotkeys
    (hence it needs a modifier).
  - **Re-entrancy is a known sharp edge:** a script's `send "ctrl+shift+p"` can
    trip your own registered hotkey. The LL hook filters `LLKHF_INJECTED`, but
    `WM_HOTKEY` routing can still fire — avoid binding a script to a combo it
    also `send`s.
  - Errors (unknown word, missing window, …) abort silently — by design.

- **`D:\cf22\notes\TEST_AUTOMATION.md`** — the A/B/C test-framework plan behind
  `tname`/`tpass`/`tfail`/`tsummary` + the `expect_*` assertions: the
  grep-friendly log format, the `runtests.bat` exit-code convention, and the
  future-expansion list (`expect_no_img`, `expect_no_window`, `tcall <name>`,
  `pix3eq` OCR).

- **`D:\cf22\CLAUDE.md`** ("Snippet manager" section) — the phase index, the
  five input-automation traps handled during the lift (injected-key filter,
  memcmp body-trim, `SendInput` foreground targeting, modifier release, `esi`
  preservation), the ImageSearch DLL contract, and the Phase 4 CDP web set.

### Differences vs those docs

The cf22 notes are partly aspirational and drifted from the shipped code that
lal4s was lifted from:

| cf22 docs say | lal4s reality |
|---|---|
| `keys`, `wfocus`/`wwait` commands | The real commands are `type`/`send` and `winactivate`/`winwait`. |
| `send "enter"` shorthands | `send` requires a modifier; use the `enter`/`tab` commands. |
| logs to `color_debug.log` | lal4s logs to `lal4s_debug.log`. |
| tests target the `ColorForth 22 for Win32` window | No Forth window in lal4s — retarget `expect_window`/`winactivate` to a real app. |

### Port status

**The port is complete.** All 68 cf22 script commands are lifted (lal4s and cf22
are at command parity), plus the global hotkeys, the hotstring hook, the default
tray icon, the CapsLock snippet picker, the Ctrl+Shift+Space browser-tab picker,
and the Ctrl+Alt+R consent reject-all. The only cf22 piece intentionally left out
is the Forth kernel (by design); the Ctrl+Shift+D `UIADump` diagnostic is also
skipped. The `web*` (CDP), tabnav, and consent features need `helpers.dll`'s
exports at runtime (plus Edge/Chrome for `web*`); without them they no-op. See
`EXTRACTION_PLAN.md` for the full history.

---

## Appendix B — test suite

`tests/` holds script test sets ported from `D:\cf22\tests`, plus a lal4s-native
smoke test. See `tests/README.md` for which run against the current command set.
The `runtests.bat` runner greps `lal4s_debug.log` for `FAIL:` and sets an exit
code (0 = all pass, 1 = failures, 2 = summary missing, 3 = no log).
