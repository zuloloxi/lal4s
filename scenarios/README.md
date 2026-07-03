# lal4s scenarios

Three ready-to-run, hotkey-driven demos of the automation surface. Each is a
`snippets.txt`-format file of `:::` script snippets.

| File | Demonstrates | Hotkeys |
|---|---|---|
| `cdp_scenario.txt` | CDP web automation vs the local Node server — assertions, `weblog` inspection, driving the page, and negative error-detection | Ctrl+Shift+**F1–F4** |
| `devloop_scenario.txt` | The natural dev loop — open once, then one hotkey re-checks + inspects the live page after every code change | Ctrl+Shift+**F5–F7** |
| `windows_scenario.txt` | `run → winwait → type/key/click → winclose`, window move/size/min, and paste-proof password entry via `type` / `clipget type` | Ctrl+Shift+**F8–F12** |

## How to run

lal4s loads **one** snippets file per launch:
```
lal4s.exe scenarios\cdp_scenario.txt
```
Then press the hotkeys and tail `lal4s_debug.log`.

The hotkeys don't collide across the three files (F1–F4 / F5–F7 / F8–F12), so to
have them all live at once just concatenate them, e.g.:
```
copy /b scenarios\cdp_scenario.txt + scenarios\devloop_scenario.txt + scenarios\windows_scenario.txt scenarios\all.txt
lal4s.exe scenarios\all.txt
```
…or append the ones you want to your main `snippets.txt`.

## Prerequisites

- **CDP / dev-loop** (`cdp_scenario`, `devloop_scenario`): start the test server
  first — `node tests\webserver\server.js` (serves `http://localhost:8722`) —
  and have `helpers.dll` (CDP exports) + Edge/Chrome present. For the dev loop,
  point `weburl` at your own dev server instead of `localhost:8722`.
- **Windows** (`windows_scenario`): no prerequisites; `pw_type` targets a PuTTY
  window — change the title substring / password to suit. `type` sends real
  keystrokes (paste-proof); `clipget type` types whatever you copied.

## Notes

- Everything the assertions and `weblog` produce goes to `lal4s_debug.log`
  (flushed per line, so tail it live).
- `winclose`/`winactivate_substr`/`winmin`/… match by **title substring**, so
  they survive fluctuating titles (browsers, editors).
- `run_weblog_test.bat` / `run_web_tests.bat` in the repo root automate the
  server-start + launch for the CDP paths if you prefer one click.
