// ImageSearchDLL.cpp : Defines the entry point for the DLL application.
//

#include "stdafx.h"
#include <windows.h>
#include "util.h"
#include <stdio.h>
#include <stdlib.h>


#ifdef _MANAGED
#pragma managed(push, off)
#endif

BOOL APIENTRY DllMain( HMODULE hModule,
                       DWORD  ul_reason_for_call,
                       LPVOID lpReserved
					 )
{
    return TRUE;
}

#ifdef _MANAGED
#pragma managed(pop)
#endif


void _tmain()
{
	int z;
	HBITMAP hbmp = LoadPicture("c:\\pic.bmp",0,0,z,0,0);
	char *answer="";
	answer = ImageSearch(0,0,1024,768,"c:\\pic.bmp");
	return;
}

// ============================================================
// WinShot — capture a window via PrintWindow and save to .bmp.
// Works for minimized/covered/off-screen windows where screen
// BitBlt would return blank/wrong pixels.
//
// Args: hwnd target window, outpath ASCII BMP path to write.
// Returns: 1 on success, 0 on any failure.
//
// Uses PW_RENDERFULLCONTENT (flag bit 2, Win8.1+) so DirectX /
// UWP-composed content is captured correctly. Older Windows
// silently ignore the bit.
// ============================================================
#ifndef PW_RENDERFULLCONTENT
#define PW_RENDERFULLCONTENT 0x00000002
#endif

extern "C" __declspec(dllexport)
int __stdcall WinShot(HWND hwnd, const char* outpath)
{
    if (!hwnd || !outpath) return 0;

    // For minimized windows, GetWindowRect returns off-screen iconic
    // coords. Use the normal-position rect instead.
    RECT rc;
    if (IsIconic(hwnd)) {
        WINDOWPLACEMENT wp = {0};
        wp.length = sizeof(wp);
        if (!GetWindowPlacement(hwnd, &wp)) return 0;
        rc = wp.rcNormalPosition;
    } else {
        if (!GetWindowRect(hwnd, &rc)) return 0;
    }
    int w = rc.right - rc.left;
    int h = rc.bottom - rc.top;
    if (w <= 0 || h <= 0) return 0;

    // Use screen DC only to create a compatible bitmap; the actual
    // capture is PrintWindow with PW_RENDERFULLCONTENT (Win8.1+),
    // which works for minimized/covered/off-screen/hidden windows.
    // Earlier BitBlt-from-WindowDC fallback overwrote PrintWindow's
    // result with blank pixels for minimized windows — removed.
    HDC hdcScreen = GetDC(NULL);
    if (!hdcScreen) return 0;
    HDC hdcMem    = CreateCompatibleDC(hdcScreen);
    HBITMAP hbm   = CreateCompatibleBitmap(hdcScreen, w, h);
    HBITMAP hbmOld = (HBITMAP)SelectObject(hdcMem, hbm);

    // WS_EX_LAYERED windows often return blank from PrintWindow.
    // Clear the bit temporarily, capture, restore. No-op for most
    // windows since they don't have it set.
    LONG ex = GetWindowLong(hwnd, GWL_EXSTYLE);
    if (ex & WS_EX_LAYERED) {
        SetWindowLong(hwnd, GWL_EXSTYLE, ex & ~WS_EX_LAYERED);
    }
    PrintWindow(hwnd, hdcMem, PW_RENDERFULLCONTENT);
    // PrintWindow uses DWM's cached compositor image for visible
    // windows and the iconic representation (usually black) for
    // minimized ones. Neither path actually invokes our wndproc.
    // Send WM_PRINTCLIENT directly so a target that implements it
    // (e.g. cf22's wnd_proc with the 2026-06-07 patch) gets a
    // chance to render into hdcMem regardless of window state.
    // For targets that don't handle it, DefWindowProc ignores the
    // message — harmless overlay on PrintWindow's result.
    SendMessage(hwnd, WM_PRINTCLIENT, (WPARAM)hdcMem,
                PRF_CLIENT | PRF_NONCLIENT | PRF_ERASEBKGND | PRF_CHILDREN);
    if (ex & WS_EX_LAYERED) {
        SetWindowLong(hwnd, GWL_EXSTYLE, ex);
    }

    int saved = 0;
    {
        BITMAPFILEHEADER bfh = {0};
        BITMAPINFOHEADER bih = {0};
        bih.biSize        = sizeof(bih);
        bih.biWidth       = w;
        bih.biHeight      = h;          // bottom-up (positive)
        bih.biPlanes      = 1;
        bih.biBitCount    = 24;
        bih.biCompression = BI_RGB;
        int stride        = ((w * 3 + 3) & ~3);
        int imgsize       = stride * h;
        bih.biSizeImage   = imgsize;

        bfh.bfType    = 0x4D42; // 'BM'
        bfh.bfOffBits = sizeof(bfh) + sizeof(bih);
        bfh.bfSize    = bfh.bfOffBits + imgsize;

        BYTE* pixels = (BYTE*)malloc(imgsize);
        if (pixels) {
            BITMAPINFO bi = {0};
            bi.bmiHeader = bih;
            if (GetDIBits(hdcMem, hbm, 0, h, pixels, &bi, DIB_RGB_COLORS) > 0) {
                FILE* f = fopen(outpath, "wb");
                if (f) {
                    fwrite(&bfh, sizeof(bfh), 1, f);
                    fwrite(&bih, sizeof(bih), 1, f);
                    fwrite(pixels, imgsize, 1, f);
                    fclose(f);
                    saved = 1;
                }
            }
            free(pixels);
        }
    }

    SelectObject(hdcMem, hbmOld);
    DeleteObject(hbm);
    DeleteDC(hdcMem);
    ReleaseDC(NULL, hdcScreen);
    return saved;
}

// ============================================================
// DebugBox — flash a rectangle outline on screen for visual
// debugging of imgfindin / pixelwait / mouse-coordinate work.
//
// Draws the four edges of (left,top)-(right,bottom) on the
// screen DC using R2_NOT (XOR) so the same draw operation
// erases itself. Sleep(durationMs) between draw and erase.
//
// Pros: no window registration, doesn't steal focus, exact
// pixels on screen. Cons: rect may flicker if another window
// repaints in that area during the sleep.
//
// Returns 1 always (no failure modes that matter).
// ============================================================
static void xor_rect_outline(HDC hdc, int left, int top, int right, int bottom)
{
    HPEN pen = CreatePen(PS_SOLID, 3, RGB(0, 0, 0));
    HGDIOBJ oldPen = SelectObject(hdc, pen);
    int oldRop = SetROP2(hdc, R2_NOT);
    MoveToEx(hdc, left,  top,    NULL);
    LineTo  (hdc, right, top);
    LineTo  (hdc, right, bottom);
    LineTo  (hdc, left,  bottom);
    LineTo  (hdc, left,  top);
    SetROP2(hdc, oldRop);
    SelectObject(hdc, oldPen);
    DeleteObject(pen);
}

extern "C" __declspec(dllexport)
int __stdcall DebugBox(int left, int top, int right, int bottom, int durationMs)
{
    HDC hdc = GetDC(NULL);  // whole-screen DC
    if (!hdc) return 0;
    xor_rect_outline(hdc, left, top, right, bottom);
    Sleep(durationMs);
    xor_rect_outline(hdc, left, top, right, bottom);  // XOR again = erase
    ReleaseDC(NULL, hdc);
    return 1;
}

// ============================================================
// UI Automation (UIA) helpers — tab navigation in Edge, plus
// generic button / checkbox automation (cookie consent reject,
// form fill, etc).  Uses COM CoCreateInstance — no static link
// against uiautomationcore.lib.  Works on Windows 7+.
//
// All exports take an HWND so the caller picks which window to
// operate on (typically GetForegroundWindow on the asm side).
// Returns -1 on error / 0..N for counts / 0|1 for actions unless
// the function comment says otherwise.
//
// UIA headers + OLE prerequisites live in stdafx.h so the PCH
// covers them; nothing else needed here.
// ============================================================

static IUIAutomation* g_uia = NULL;
static int g_com_inited = 0;

static int uia_ensure(void)
{
    if (!g_com_inited) {
        HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
        if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) return 0;
        g_com_inited = 1;
    }
    if (!g_uia) {
        HRESULT hr = CoCreateInstance(__uuidof(CUIAutomation), NULL,
                                       CLSCTX_INPROC_SERVER,
                                       __uuidof(IUIAutomation),
                                       (void**)&g_uia);
        if (FAILED(hr) || !g_uia) return 0;
    }
    return 1;
}

// uia_find_all — collect every descendant of `root` whose
// ControlType == ctype.  Caller releases the array.
static IUIAutomationElementArray* uia_find_all(IUIAutomationElement* root, int ctype)
{
    if (!root) return NULL;
    IUIAutomationCondition* cond = NULL;
    VARIANT v;
    VariantInit(&v);
    v.vt   = VT_I4;
    v.lVal = ctype;
    HRESULT hr = g_uia->CreatePropertyCondition(UIA_ControlTypePropertyId, v, &cond);
    if (FAILED(hr) || !cond) return NULL;
    IUIAutomationElementArray* arr = NULL;
    root->FindAll(TreeScope_Descendants, cond, &arr);
    cond->Release();
    return arr;
}

// uia_root_for — top-level root element for the given window.
// Caller releases.
static IUIAutomationElement* uia_root_for(HWND hwnd)
{
    if (!uia_ensure() || !hwnd) return NULL;
    IUIAutomationElement* root = NULL;
    if (FAILED(g_uia->ElementFromHandle(hwnd, &root))) return NULL;
    return root;
}

// Forward declaration — defined later, used by uia_find_consent_root
// and uia_click_button_by_class_in below.
static int uia_wstr_contains_ci(BSTR haystack, const char* needle);

// uia_ci_contains — case-insensitive substring test on a wide
// haystack vs an ASCII needle.
static int uia_ci_contains(BSTR haystack, const char* needle)
{
    if (!haystack || !needle || !*needle) return 0;
    wchar_t wneedle[256];
    int n = MultiByteToWideChar(CP_UTF8, 0, needle, -1, wneedle, 256);
    if (n <= 0) return 0;
    for (int i = 0; wneedle[i]; ++i) {
        if (wneedle[i] >= L'A' && wneedle[i] <= L'Z') wneedle[i] += 32;
    }
    // Lowercase a copy of haystack in place (BSTR is allocated by us
    // when calling get_CurrentName so we can mutate the buffer).
    int hlen = (int)wcslen(haystack);
    for (int i = 0; i < hlen; ++i) {
        if (haystack[i] >= L'A' && haystack[i] <= L'Z') haystack[i] += 32;
    }
    return wcsstr(haystack, wneedle) != NULL ? 1 : 0;
}

// ============================================================
// TabNavCount(hwnd) → tab count in the given Edge window
// ============================================================
extern "C" __declspec(dllexport)
int __stdcall TabNavCount(HWND hwnd)
{
    IUIAutomationElement* root = uia_root_for(hwnd);
    if (!root) return -1;
    IUIAutomationElementArray* arr = uia_find_all(root, UIA_TabItemControlTypeId);
    int n = -1;
    if (arr) {
        arr->get_Length(&n);
        arr->Release();
    }
    root->Release();
    return n;
}

// ============================================================
// TabNavGetTitle(hwnd, idx, buf, buflen) → bytes written, or -1
// ============================================================
extern "C" __declspec(dllexport)
int __stdcall TabNavGetTitle(HWND hwnd, int idx, char* buf, int buflen)
{
    if (!buf || buflen <= 0) return -1;
    buf[0] = 0;
    IUIAutomationElement* root = uia_root_for(hwnd);
    if (!root) return -1;
    IUIAutomationElementArray* arr = uia_find_all(root, UIA_TabItemControlTypeId);
    int written = -1;
    if (arr) {
        int len = 0;
        arr->get_Length(&len);
        if (idx >= 0 && idx < len) {
            IUIAutomationElement* tab = NULL;
            arr->GetElement(idx, &tab);
            if (tab) {
                BSTR name = NULL;
                tab->get_CurrentName(&name);
                if (name) {
                    int n = WideCharToMultiByte(CP_UTF8, 0, name, -1,
                                                 buf, buflen - 1, NULL, NULL);
                    if (n > 0) {
                        buf[n - 1] = 0;
                        written = n - 1;
                    } else {
                        written = 0;
                    }
                    SysFreeString(name);
                }
                tab->Release();
            }
        }
        arr->Release();
    }
    root->Release();
    return written;
}

// ============================================================
// TabNavSwitchTo(hwnd, idx) → 1 on success, 0 on failure
// ============================================================
extern "C" __declspec(dllexport)
int __stdcall TabNavSwitchTo(HWND hwnd, int idx)
{
    IUIAutomationElement* root = uia_root_for(hwnd);
    if (!root) return 0;
    IUIAutomationElementArray* arr = uia_find_all(root, UIA_TabItemControlTypeId);
    int ok = 0;
    if (arr) {
        int len = 0;
        arr->get_Length(&len);
        if (idx >= 0 && idx < len) {
            IUIAutomationElement* tab = NULL;
            arr->GetElement(idx, &tab);
            if (tab) {
                IUIAutomationSelectionItemPattern* sel = NULL;
                tab->GetCurrentPatternAs(UIA_SelectionItemPatternId,
                                          __uuidof(IUIAutomationSelectionItemPattern),
                                          (void**)&sel);
                if (sel) {
                    if (SUCCEEDED(sel->Select())) ok = 1;
                    sel->Release();
                }
                tab->Release();
            }
        }
        arr->Release();
    }
    root->Release();
    return ok;
}

// ============================================================
// TabNavSnapshot(hwnd, buf, stride, maxN) → count of tabs written.
// Single-call replacement for TabNavCount + N×TabNavGetTitle.
// Walks the UIA tree ONCE; writes up to maxN tab titles into buf
// at `stride` bytes each (NUL-terminated within each slot).
// Returns -1 on error, 0..maxN on success.
//
// Performance: TabNavCount + N TabNavGetTitle each call
// FindAll(TreeScope_Descendants) which walks Edge's ENTIRE
// accessibility tree.  For 30 tabs that's 31 full walks (seconds).
// This function does one Descendants walk to locate the tab list
// container, then Children walk on it for the tab items — both
// orders of magnitude faster.
// ============================================================
extern "C" __declspec(dllexport)
int __stdcall TabNavSnapshot(HWND hwnd, char* buf, int stride, int maxN)
{
    if (!buf || stride <= 0 || maxN <= 0) return -1;
    IUIAutomationElement* root = uia_root_for(hwnd);
    if (!root) return -1;

    // One Descendants walk for TabItem — same as TabNavCount, but
    // read names in the same pass.  N+1 calls collapse to 1.
    IUIAutomationElementArray* arr = uia_find_all(root, UIA_TabItemControlTypeId);
    root->Release();
    if (!arr) return -1;

    int len = 0;
    arr->get_Length(&len);
    if (len > maxN) len = maxN;

    for (int i = 0; i < len; ++i) {
        char* slot = buf + i * stride;
        slot[0] = 0;
        IUIAutomationElement* tab = NULL;
        arr->GetElement(i, &tab);
        if (tab) {
            BSTR name = NULL;
            tab->get_CurrentName(&name);
            if (name) {
                int n = WideCharToMultiByte(CP_UTF8, 0, name, -1,
                                             slot, stride - 1, NULL, NULL);
                if (n > 0) slot[n - 1] = 0;
                SysFreeString(name);
            }
            tab->Release();
        }
    }
    arr->Release();
    return len;
}

// ============================================================
// UIADump(hwnd, outpath) → count of elements written, or -1 on error.
// Walks every descendant of hwnd's root and writes one line per
// element to outpath:
//   <ControlTypeName> "<Name>" toggle=<state> selected=<state> class=<ClassName>
// Used to diagnose what a cookie / consent panel actually exposes.
// ============================================================
static const char* ctype_name(int ct)
{
    switch (ct) {
        case UIA_ButtonControlTypeId:      return "Button";
        case UIA_CheckBoxControlTypeId:    return "CheckBox";
        case UIA_RadioButtonControlTypeId: return "RadioButton";
        case UIA_HyperlinkControlTypeId:   return "Link";
        case UIA_TextControlTypeId:        return "Text";
        case UIA_EditControlTypeId:        return "Edit";
        case UIA_TabControlTypeId:         return "TabControl";
        case UIA_TabItemControlTypeId:     return "TabItem";
        case UIA_GroupControlTypeId:       return "Group";
        case UIA_ListControlTypeId:        return "List";
        case UIA_ListItemControlTypeId:    return "ListItem";
        case UIA_PaneControlTypeId:        return "Pane";
        case UIA_DocumentControlTypeId:    return "Document";
        case UIA_ImageControlTypeId:       return "Image";
        case UIA_MenuItemControlTypeId:    return "MenuItem";
        case UIA_ComboBoxControlTypeId:    return "ComboBox";
        case UIA_CustomControlTypeId:      return "Custom";
        default:                            return "Other";
    }
}

extern "C" __declspec(dllexport)
int __stdcall UIADump(HWND hwnd, const char* outpath)
{
    if (!outpath) return -1;
    IUIAutomationElement* root = uia_root_for(hwnd);
    if (!root) return -1;

    IUIAutomationCondition* trueCond = NULL;
    g_uia->CreateTrueCondition(&trueCond);
    IUIAutomationElementArray* arr = NULL;
    root->FindAll(TreeScope_Descendants, trueCond, &arr);
    trueCond->Release();
    root->Release();
    if (!arr) return -1;

    FILE* f = fopen(outpath, "w");
    if (!f) { arr->Release(); return -1; }

    int len = 0;
    arr->get_Length(&len);
    int written = 0;
    for (int i = 0; i < len; ++i) {
        IUIAutomationElement* el = NULL;
        arr->GetElement(i, &el);
        if (!el) continue;

        CONTROLTYPEID ct = 0;
        el->get_CurrentControlType(&ct);

        BSTR name = NULL;
        el->get_CurrentName(&name);
        char name_a[256] = {0};
        if (name) {
            WideCharToMultiByte(CP_UTF8, 0, name, -1, name_a, sizeof(name_a)-1, NULL, NULL);
            SysFreeString(name);
        }

        BSTR cls = NULL;
        el->get_CurrentClassName(&cls);
        char cls_a[128] = {0};
        if (cls) {
            WideCharToMultiByte(CP_UTF8, 0, cls, -1, cls_a, sizeof(cls_a)-1, NULL, NULL);
            SysFreeString(cls);
        }

        BSTR loc = NULL;
        el->get_CurrentLocalizedControlType(&loc);
        char loc_a[64] = {0};
        if (loc) {
            WideCharToMultiByte(CP_UTF8, 0, loc, -1, loc_a, sizeof(loc_a)-1, NULL, NULL);
            SysFreeString(loc);
        }

        const char* tog_str = "-";
        IUIAutomationTogglePattern* tog = NULL;
        el->GetCurrentPatternAs(UIA_TogglePatternId,
                                 __uuidof(IUIAutomationTogglePattern),
                                 (void**)&tog);
        if (tog) {
            ToggleState st = ToggleState_Indeterminate;
            if (SUCCEEDED(tog->get_CurrentToggleState(&st))) {
                tog_str = (st == ToggleState_On) ? "ON" :
                          (st == ToggleState_Off) ? "off" : "?";
            }
            tog->Release();
        }

        const char* sel_str = "-";
        IUIAutomationSelectionItemPattern* sel = NULL;
        el->GetCurrentPatternAs(UIA_SelectionItemPatternId,
                                 __uuidof(IUIAutomationSelectionItemPattern),
                                 (void**)&sel);
        if (sel) {
            BOOL selected = FALSE;
            if (SUCCEEDED(sel->get_CurrentIsSelected(&selected))) {
                sel_str = selected ? "SEL" : "uns";
            }
            sel->Release();
        }

        const char* inv_str = "-";
        IUIAutomationInvokePattern* inv = NULL;
        el->GetCurrentPatternAs(UIA_InvokePatternId,
                                 __uuidof(IUIAutomationInvokePattern),
                                 (void**)&inv);
        if (inv) { inv_str = "INV"; inv->Release(); }

        fprintf(f, "%-12s %-12s tog=%-3s sel=%-3s inv=%-3s name=\"%s\" class=\"%s\"\n",
                ctype_name(ct), loc_a, tog_str, sel_str, inv_str,
                name_a, cls_a);
        written++;
        el->Release();
    }
    fclose(f);
    arr->Release();
    return written;
}

// ============================================================
// FindAndClickButton(hwnd, namePattern) → 1 on click, 0 if not found.
// Case-insensitive substring match on each Button's Name property.
// ============================================================
extern "C" __declspec(dllexport)
int __stdcall FindAndClickButton(HWND hwnd, const char* namePattern)
{
    if (!namePattern || !*namePattern) return 0;
    IUIAutomationElement* root = uia_root_for(hwnd);
    if (!root) return 0;
    IUIAutomationElementArray* arr = uia_find_all(root, UIA_ButtonControlTypeId);
    int ok = 0;
    if (arr) {
        int len = 0;
        arr->get_Length(&len);
        for (int i = 0; i < len && !ok; ++i) {
            IUIAutomationElement* btn = NULL;
            arr->GetElement(i, &btn);
            if (!btn) continue;
            BSTR name = NULL;
            btn->get_CurrentName(&name);
            if (name && uia_ci_contains(name, namePattern)) {
                IUIAutomationInvokePattern* inv = NULL;
                btn->GetCurrentPatternAs(UIA_InvokePatternId,
                                          __uuidof(IUIAutomationInvokePattern),
                                          (void**)&inv);
                if (inv) {
                    if (SUCCEEDED(inv->Invoke())) ok = 1;
                    inv->Release();
                }
            }
            if (name) SysFreeString(name);
            btn->Release();
        }
        arr->Release();
    }
    root->Release();
    return ok;
}

// uia_toggle_one_on — find the FIRST descendant of root whose
// TogglePattern state == On, toggle it Off, return 1 on success or
// 0 if no ON toggle remains.  Repeated calls drain the panel.
// Each toggle may invalidate other element handles (DOM re-render)
// so we re-query on every iteration instead of caching an array.
static int uia_toggle_one_on(IUIAutomationElement* root)
{
    if (!root) return 0;
    IUIAutomationCondition* cond = NULL;
    VARIANT v;
    VariantInit(&v);
    v.vt        = VT_BOOL;
    v.boolVal   = VARIANT_TRUE;
    HRESULT hr = g_uia->CreatePropertyCondition(
        UIA_IsTogglePatternAvailablePropertyId, v, &cond);
    if (FAILED(hr) || !cond) return 0;
    IUIAutomationElementArray* arr = NULL;
    root->FindAll(TreeScope_Descendants, cond, &arr);
    cond->Release();
    if (!arr) return 0;
    int len = 0;
    arr->get_Length(&len);
    int did_toggle = 0;
    for (int i = 0; i < len && !did_toggle; ++i) {
        IUIAutomationElement* el = NULL;
        arr->GetElement(i, &el);
        if (!el) continue;
        IUIAutomationTogglePattern* tog = NULL;
        el->GetCurrentPatternAs(UIA_TogglePatternId,
                                 __uuidof(IUIAutomationTogglePattern),
                                 (void**)&tog);
        if (tog) {
            ToggleState st = ToggleState_Indeterminate;
            if (SUCCEEDED(tog->get_CurrentToggleState(&st)) &&
                st == ToggleState_On) {
                if (SUCCEEDED(tog->Toggle())) did_toggle = 1;
            }
            tog->Release();
        }
        el->Release();
    }
    arr->Release();
    return did_toggle;
}

// uia_drain_toggles — keep toggling ON switches off until none
// remain or the safety budget is exhausted.  Returns total count.
// Operates inside the subtree of `root` only (so the caller can
// scope the walk to the consent dialog and avoid touching Edge
// browser UI elements).
static int uia_drain_toggles_in(IUIAutomationElement* root, int max_iters)
{
    int total = 0;
    for (int i = 0; i < max_iters; ++i) {
        int did = uia_toggle_one_on(root);
        if (!did) break;
        total++;
    }
    return total;
}

// uia_drain_toggles_hwnd — same but takes a top-level HWND and
// re-resolves the root each iteration.  Kept for the legacy path.
static int uia_drain_toggles(HWND hwnd, int max_iters)
{
    int total = 0;
    for (int i = 0; i < max_iters; ++i) {
        IUIAutomationElement* root = uia_root_for(hwnd);
        if (!root) break;
        int did = uia_toggle_one_on(root);
        root->Release();
        if (!did) break;
        total++;
    }
    return total;
}

// uia_count_on_toggles_in — READ-ONLY count of descendants of root
// whose TogglePattern state == On.  No mutation.  Used by the
// (guarded) Phase 2 to verify the panel is FULLY drained before it
// is ever allowed to click "Confirm choices" — clicking Save on a
// partially-drained panel persists a broken consent blob that
// survives browser/OS restarts.  Never save unless this returns 0.
static int uia_count_on_toggles_in(IUIAutomationElement* root)
{
    if (!root) return -1;
    IUIAutomationCondition* cond = NULL;
    VARIANT v;
    VariantInit(&v);
    v.vt      = VT_BOOL;
    v.boolVal = VARIANT_TRUE;
    HRESULT hr = g_uia->CreatePropertyCondition(
        UIA_IsTogglePatternAvailablePropertyId, v, &cond);
    if (FAILED(hr) || !cond) return -1;
    IUIAutomationElementArray* arr = NULL;
    root->FindAll(TreeScope_Descendants, cond, &arr);
    cond->Release();
    if (!arr) return -1;
    int len = 0;
    arr->get_Length(&len);
    int on = 0;
    for (int i = 0; i < len; ++i) {
        IUIAutomationElement* el = NULL;
        arr->GetElement(i, &el);
        if (!el) continue;
        IUIAutomationTogglePattern* tog = NULL;
        el->GetCurrentPatternAs(UIA_TogglePatternId,
                                 __uuidof(IUIAutomationTogglePattern),
                                 (void**)&tog);
        if (tog) {
            ToggleState st = ToggleState_Indeterminate;
            if (SUCCEEDED(tog->get_CurrentToggleState(&st)) &&
                st == ToggleState_On) {
                on++;
            }
            tog->Release();
        }
        el->Release();
    }
    arr->Release();
    return on;
}

// uia_toggle_all_on_off_once — ONE FindAll snapshot of the dialog's
// toggle elements, then flip every element currently ON in that same
// pass.  Returns the number flipped.  This is the fast bulk path:
// the per-toggle re-walk in uia_drain_toggles_in costs a full
// FindAll(Descendants) per switch (~300ms each → ~21s for 71 vendor
// toggles); doing it from a single snapshot is one walk + N cheap
// state reads.  A page re-render after a flip can stale later
// element handles in the snapshot (their COM calls then fail and we
// skip them) — that is fine: the caller follows up with the proven
// re-query drain to mop up any stragglers, so correctness (after==0)
// is unchanged.  A small per-toggle Sleep paces the renderer so a
// fast burst of toggles doesn't stall Edge's content process.
static int uia_toggle_all_on_off_once(IUIAutomationElement* root)
{
    if (!root) return 0;
    IUIAutomationCondition* cond = NULL;
    VARIANT v;
    VariantInit(&v);
    v.vt      = VT_BOOL;
    v.boolVal = VARIANT_TRUE;
    HRESULT hr = g_uia->CreatePropertyCondition(
        UIA_IsTogglePatternAvailablePropertyId, v, &cond);
    if (FAILED(hr) || !cond) return 0;
    IUIAutomationElementArray* arr = NULL;
    root->FindAll(TreeScope_Descendants, cond, &arr);
    cond->Release();
    if (!arr) return 0;
    int len = 0;
    arr->get_Length(&len);
    int toggled = 0;
    for (int i = 0; i < len; ++i) {
        IUIAutomationElement* el = NULL;
        arr->GetElement(i, &el);
        if (!el) continue;
        IUIAutomationTogglePattern* tog = NULL;
        el->GetCurrentPatternAs(UIA_TogglePatternId,
                                 __uuidof(IUIAutomationTogglePattern),
                                 (void**)&tog);
        if (tog) {
            ToggleState st = ToggleState_Indeterminate;
            if (SUCCEEDED(tog->get_CurrentToggleState(&st)) &&
                st == ToggleState_On) {
                if (SUCCEEDED(tog->Toggle())) {
                    toggled++;
                    Sleep(10);   // pace the renderer (avoid content-process stall)
                }
            }
            tog->Release();
        }
        el->Release();
    }
    arr->Release();
    return toggled;
}

// Known consent-dialog class fingerprints.  We use these to scope
// every subsequent UIA walk to the dialog subtree — keeps phase 2
// from clicking buttons in Edge's chrome (BackForwardButton, tab
// close, etc.) or in another tab.
static const char* g_consent_dialog_classes[] = {
    "fc-dialog",                // Quantcast Choice
    "fc-consent-root",
    "fc-root-container",
    "onetrust-banner-sdk",      // OneTrust
    "onetrust-pc-dark-filter",
    "ot-pc-content",
    "CybotCookiebotDialog",     // Cookiebot
    "truste-banner",            // TrustArc
    "trustarc",
    "sp_message_container",     // Sourcepoint
    "qc-cmp",                   // Quantcast (older)
    "iab-consent",
    "consent-banner",
    "cookie-consent",
    "cookieconsent",
    NULL,
};

// uia_find_consent_root — locate the first descendant of root whose
// ClassName contains one of the known consent-dialog fingerprints.
// Returns AddRef'd element (caller releases) or NULL.  When this
// returns NULL the dialog is either absent or in an iframe UIA
// can't enumerate; caller falls back to the full window.
static IUIAutomationElement* uia_find_consent_root(HWND hwnd)
{
    IUIAutomationElement* root = uia_root_for(hwnd);
    if (!root) return NULL;
    // No CreateClassNameProperty-condition primitive in older SDKs
    // is reliable across Win versions — walk Panes / Customs and
    // check ClassName ourselves.  Cheap because we stop at first hit.
    IUIAutomationCondition* trueCond = NULL;
    g_uia->CreateTrueCondition(&trueCond);
    IUIAutomationElementArray* arr = NULL;
    root->FindAll(TreeScope_Descendants, trueCond, &arr);
    trueCond->Release();
    root->Release();
    if (!arr) return NULL;
    int len = 0;
    arr->get_Length(&len);
    IUIAutomationElement* hit = NULL;
    for (int i = 0; i < len && !hit; ++i) {
        IUIAutomationElement* el = NULL;
        arr->GetElement(i, &el);
        if (!el) continue;
        BSTR cls = NULL;
        el->get_CurrentClassName(&cls);
        if (cls) {
            for (int j = 0; g_consent_dialog_classes[j]; ++j) {
                if (uia_wstr_contains_ci(cls, g_consent_dialog_classes[j])) {
                    hit = el;
                    el->AddRef();
                    break;
                }
            }
            SysFreeString(cls);
        }
        el->Release();
    }
    arr->Release();
    return hit;
}

// uia_find_all_in / uia_click_button_by_name_in — variants of the
// earlier helpers that take a pre-located root instead of an HWND,
// so we can scope all phase-2 operations to the consent dialog
// subtree.  Avoids the "click Edge's BackForwardButton" disaster.
static int uia_click_button_by_name_in(IUIAutomationElement* root, const char* namePattern)
{
    if (!root || !namePattern || !*namePattern) return 0;
    IUIAutomationElementArray* arr = uia_find_all(root, UIA_ButtonControlTypeId);
    int ok = 0;
    if (arr) {
        int len = 0;
        arr->get_Length(&len);
        for (int i = 0; i < len && !ok; ++i) {
            IUIAutomationElement* btn = NULL;
            arr->GetElement(i, &btn);
            if (!btn) continue;
            BSTR name = NULL;
            btn->get_CurrentName(&name);
            if (name && uia_ci_contains(name, namePattern)) {
                IUIAutomationInvokePattern* inv = NULL;
                btn->GetCurrentPatternAs(UIA_InvokePatternId,
                                          __uuidof(IUIAutomationInvokePattern),
                                          (void**)&inv);
                if (inv) {
                    if (SUCCEEDED(inv->Invoke())) ok = 1;
                    inv->Release();
                }
            }
            if (name) SysFreeString(name);
            btn->Release();
        }
        arr->Release();
    }
    return ok;
}

static int uia_click_button_by_class_in(IUIAutomationElement* root, const char* classSubstring)
{
    if (!root || !classSubstring || !*classSubstring) return 0;
    IUIAutomationElementArray* arr = uia_find_all(root, UIA_ButtonControlTypeId);
    int clicked = 0;
    if (arr) {
        int len = 0;
        arr->get_Length(&len);
        for (int i = 0; i < len && !clicked; ++i) {
            IUIAutomationElement* btn = NULL;
            arr->GetElement(i, &btn);
            if (!btn) continue;
            BSTR cls = NULL;
            btn->get_CurrentClassName(&cls);
            if (cls && uia_wstr_contains_ci(cls, classSubstring)) {
                IUIAutomationInvokePattern* inv = NULL;
                btn->GetCurrentPatternAs(UIA_InvokePatternId,
                                          __uuidof(IUIAutomationInvokePattern),
                                          (void**)&inv);
                if (inv) {
                    if (SUCCEEDED(inv->Invoke())) clicked = 1;
                    inv->Release();
                }
            }
            if (cls) SysFreeString(cls);
            btn->Release();
        }
        arr->Release();
    }
    return clicked;
}

// uia_wstr_contains_ci — case-insensitive ASCII-subset substring test.
// Adequate for class-name fingerprints ("fc-", "consent", etc.).
static int uia_wstr_contains_ci(BSTR haystack, const char* needle)
{
    if (!haystack || !needle || !*needle) return 0;
    int nlen = (int)strlen(needle);
    int hlen = (int)wcslen(haystack);
    if (nlen > hlen) return 0;
    for (int i = 0; i <= hlen - nlen; ++i) {
        int ok = 1;
        for (int j = 0; j < nlen; ++j) {
            wchar_t h = haystack[i + j];
            char    n = needle[j];
            if (h >= L'A' && h <= L'Z') h += 32;
            if (n >= 'A' && n <= 'Z')   n += 32;
            if (h != (wchar_t)n) { ok = 0; break; }
        }
        if (ok) return 1;
    }
    return 0;
}

// uia_click_button_by_class — find first invokable Button whose
// ClassName contains classSubstring (case-insensitive); invoke it.
// Returns 1 on click, 0 on no match.  Used to disambiguate "Back"
// buttons in consent dialogs (`fc-`) from the browser's own
// `BackForwardButton`.
static int uia_click_button_by_class(HWND hwnd, const char* classSubstring)
{
    if (!classSubstring || !*classSubstring) return 0;
    IUIAutomationElement* root = uia_root_for(hwnd);
    if (!root) return 0;
    IUIAutomationElementArray* arr = uia_find_all(root, UIA_ButtonControlTypeId);
    int clicked = 0;
    if (arr) {
        int len = 0;
        arr->get_Length(&len);
        for (int i = 0; i < len && !clicked; ++i) {
            IUIAutomationElement* btn = NULL;
            arr->GetElement(i, &btn);
            if (!btn) continue;
            BSTR cls = NULL;
            btn->get_CurrentClassName(&cls);
            if (cls && uia_wstr_contains_ci(cls, classSubstring)) {
                IUIAutomationInvokePattern* inv = NULL;
                btn->GetCurrentPatternAs(UIA_InvokePatternId,
                                          __uuidof(IUIAutomationInvokePattern),
                                          (void**)&inv);
                if (inv) {
                    if (SUCCEEDED(inv->Invoke())) clicked = 1;
                    inv->Release();
                }
            }
            if (cls) SysFreeString(cls);
            btn->Release();
        }
        arr->Release();
    }
    root->Release();
    return clicked;
}

// ============================================================
// ConsentRejectAll(hwnd) → number of toggles flipped OFF (0 if none).
//
// STRIPPED to a single, non-harmful action: flip every ON (blue)
// toggle in the currently-open consent panel to OFF.  That is ALL it
// does — by design:
//   * NO navigation (no "Manage options", no Back, no scrolling)
//   * NO "Accept all" / "Confirm choices" / "Save" click
//   * NO reject-button click
// The user drives the panels (Manage options -> scroll -> Vendor
// preferences) and presses "Confirm choices" themselves AFTER
// checking.  Because the tool never commits anything, it can never
// auto-persist a partial/broken IAB-TCF consent cookie — the bug
// that previously corrupted cookies across browser + OS restarts.
//
// On these IAB-TCF panels the switches left ON by default are the
// blue "Legitimate interest" toggles; this turns off whatever is ON
// in the panel that is open right now.  Re-run after scrolling /
// switching screens to catch toggles that weren't rendered yet.
// ============================================================
extern "C" __declspec(dllexport)
int __stdcall ConsentRejectAll(HWND hwnd)
{
    FILE* trace = fopen("D:\\cf22\\consent_trace.log", "a");
    DWORD t0 = GetTickCount();
    #define TRACE(fmt, ...) do { \
        if (trace) { \
            fprintf(trace, "[t+%-5u] " fmt "\n", GetTickCount() - t0, ##__VA_ARGS__); \
            fflush(trace); \
        } \
    } while (0)
    TRACE("==== ConsentRejectAll (toggle-off only) ENTER hwnd=0x%p ====", (void*)hwnd);

    // Scope to the consent-dialog subtree so we never touch Edge's
    // own UI; fall back to the full window root if no known dialog
    // class matches (unmapped CMP).  ONE retry rides out the panel
    // still rendering when the hotkey fired: a press-too-early run
    // logged "no class matched / ON before=0", then the toggles
    // appeared ~300 ms later.  So if the first walk finds no ON
    // toggle, settle 400 ms and look again before giving up.
    IUIAutomationElement* dialog = NULL;
    int before = 0;
    int scoped = 0;
    for (int attempt = 0; attempt < 2; ++attempt) {
        if (attempt > 0) {
            TRACE("retry: panel not ready (scoped=%d before=%d) — settling 400ms",
                  scoped, before);
            Sleep(400);
        }
        dialog = uia_find_consent_root(hwnd);
        scoped = (dialog != NULL);
        if (!dialog) {
            dialog = uia_root_for(hwnd);
            if (!dialog) {
                TRACE("uia_root_for(hwnd) NULL — aborting");
                TRACE("EXIT return=0 elapsed=%ums", GetTickCount() - t0);
                if (trace) fclose(trace);
                return 0;
            }
        }
        before = uia_count_on_toggles_in(dialog);
        if (before > 0) break;          // toggles present — proceed
        if (attempt == 0) {             // first miss — release + retry once
            dialog->Release();
            dialog = NULL;
        }
    }
    if (scoped) {
        BSTR cls = NULL;
        dialog->get_CurrentClassName(&cls);
        char cls_a[128] = {0};
        if (cls) {
            WideCharToMultiByte(CP_UTF8, 0, cls, -1, cls_a, sizeof(cls_a)-1, NULL, NULL);
            SysFreeString(cls);
        }
        TRACE("scoped to dialog class=\"%s\" (ON before=%d)", cls_a, before);
    } else {
        TRACE("no consent-dialog class matched — using full window root (ON before=%d)", before);
    }

    // Flip every ON toggle off.  No clicks of any button.
    //   1. Fast bulk pass — one FindAll snapshot, flip all ON in it.
    //   2. Mop-up drain — re-query loop catches any stragglers the
    //      page re-rendered mid-bulk (guarantees we reach 0 ON).
    int bulk  = uia_toggle_all_on_off_once(dialog);
    int strag = uia_drain_toggles_in(dialog, 256);
    int total = bulk + strag;
    int after = uia_count_on_toggles_in(dialog);
    dialog->Release();
    TRACE("drain detail: bulk=%d straggler=%d", bulk, strag);

    TRACE("flipped %d toggles OFF (ON before=%d, ON after=%d) in %ums",
          total, before, after, GetTickCount() - t0);
    if (after > 0)
        TRACE("NOTE: %d toggles still ON — likely on another screen or "
              "not yet scrolled into view; re-run after scrolling.", after);
    TRACE("EXIT return=%d elapsed=%ums (NO commit — user presses "
          "\"Confirm choices\" manually)", total, GetTickCount() - t0);
    if (trace) fclose(trace);
    #undef TRACE
    return total;
}

// Retired two-phase reject implementation — kept disabled (#if 0)
// for reference / possible CDP-era reuse.  It clicked reject/accept
// buttons and auto-saved, which is exactly what we removed.
#if 0
extern "C" __declspec(dllexport)
int __stdcall ConsentRejectAll_OLD(HWND hwnd)
{
    static const char* tries[] = {
        // English — explicit reject (highest priority: matches first)
        "Reject all",
        "Reject All",
        "Reject non-essential",
        "Reject Non-Essential",
        "Refuse all",
        "Decline all",
        "Disagree and close",
        "Disagree to all",
        "Disagree",
        "Do not agree",
        "I do not agree",
        "I do not accept",
        "Do not accept",
        "Object to all",      // IAB TCF "legitimate interest" objection
        "Object All",
        "Continue without accepting",
        "Continue Without Accepting",
        // English — softer single-word fallbacks (lower priority,
        // tried after explicit phrases so we don't accidentally hit
        // an "I reject" label that means something else)
        "Reject",
        "Refuse",
        "Decline",
        // French
        "Tout refuser",
        "Refuser tout",
        "Continuer sans accepter",
        "Je refuse",
        "Refuser",
        // German
        "Alle ablehnen",
        "Ablehnen",
        "Nicht zustimmen",
        // Italian
        "Rifiuta tutto",
        "Rifiuta",
        // Spanish
        "Rechazar todo",
        "No acepto",
        "Rechazar",
        // Privacy-only labels (consent banners with no explicit
        // reject — these only allow strictly-necessary cookies)
        "Strictly necessary",
        "Only essential",
        "Only necessary",
        NULL,
    };
    // Open the per-call trace log.  Closed at every exit path.
    FILE* trace = fopen("D:\\cf22\\consent_trace.log", "a");
    DWORD t0 = GetTickCount();
    #define TRACE(fmt, ...) do { \
        if (trace) { \
            fprintf(trace, "[t+%-5u] " fmt "\n", GetTickCount() - t0, ##__VA_ARGS__); \
            fflush(trace); \
        } \
    } while (0)
    TRACE("==== ConsentRejectAll ENTER hwnd=0x%p ====", (void*)hwnd);

    TRACE("PHASE1: trying reject labels (full window)");
    for (int i = 0; tries[i]; ++i) {
        if (FindAndClickButton(hwnd, tries[i])) {
            TRACE("PHASE1: matched \"%s\" — clicked", tries[i]);
            TRACE("EXIT return=1 elapsed=%ums", GetTickCount() - t0);
            if (trace) fclose(trace);
            return 1;
        }
    }
    TRACE("PHASE1: no match");

    static const char* saves[] = {
        "Confirm choices",
        "Save choices",
        "Save and exit",
        "Save preferences",
        "Save my choices",
        "Save selection",
        "Save settings",
        "Save",
        "Confirm my choices",
        "Confirm",
        "Apply",
        // Localised
        "Enregistrer mes choix",
        "Enregistrer",
        "Auswahl speichern",
        "Speichern",
        "Salva le mie scelte",
        "Salva",
        "Guardar mis opciones",
        "Guardar",
        NULL,
    };
    // Class fingerprints for consent-dialog "Back" buttons.  Searching
    // by NAME alone would also match Edge's own BackForwardButton and
    // navigate the page away — disastrous.  We only accept buttons
    // whose ClassName carries a consent-vendor signature.
    static const char* back_classes[] = {
        "fc-vendor-preferences-back",   // Quantcast Choice
        "fc-dialog-header-back",        // Quantcast Choice (generic)
        "ot-pc-back",                   // OneTrust
        "consent-back",
        "cookie-back",
        "preferences-back",
        NULL,
    };

    // Phase 2 — locate the consent dialog subtree and operate
    // ONLY within it.  Prevents stray matches in Edge's own UI
    // (BackForwardButton, tab close, settings page, etc.).
    IUIAutomationElement* dialog = uia_find_consent_root(hwnd);
    int scoped = (dialog != NULL);
    if (!dialog) {
        TRACE("PHASE2: no consent-dialog class matched — falling back to full window root");
        dialog = uia_root_for(hwnd);
        if (!dialog) {
            TRACE("PHASE2: uia_root_for(hwnd) NULL — aborting");
            TRACE("EXIT return=0 elapsed=%ums", GetTickCount() - t0);
            if (trace) fclose(trace);
            return 0;
        }
    } else {
        BSTR cls = NULL;
        dialog->get_CurrentClassName(&cls);
        char cls_a[128] = {0};
        if (cls) {
            WideCharToMultiByte(CP_UTF8, 0, cls, -1, cls_a, sizeof(cls_a)-1, NULL, NULL);
            SysFreeString(cls);
        }
        TRACE("PHASE2: scoped to dialog class=\"%s\"", cls_a);
    }

    // Phase 2a (SAFE) — try a single explicit reject/object button
    // scoped to the dialog.  One Invoke of a real reject button is
    // safe: the site writes consent atomically, no toggle storm, no
    // partial state.  This is the only Phase-2 action allowed by
    // default.
    for (int i = 0; tries[i]; ++i) {
        if (uia_click_button_by_name_in(dialog, tries[i])) {
            TRACE("PHASE2a: scoped reject \"%s\" — clicked", tries[i]);
            dialog->Release();
            TRACE("EXIT return=1 elapsed=%ums", GetTickCount() - t0);
            if (trace) fclose(trace);
            return 1;
        }
    }

    // Phase 2b (GUARDED) — per-vendor toggle drain + Save.  Disabled
    // by default; in safe mode we never mutate a toggle and never
    // click Save, so a broken/partial consent blob can never be
    // persisted (see g_consent_allow_toggle_drain header).
    if (!g_consent_allow_toggle_drain) {
        TRACE("PHASE2b: toggle-drain disabled (safe mode) — no mutation, no save");
        dialog->Release();
        TRACE("EXIT return=0 elapsed=%ums (safe-mode)", GetTickCount() - t0);
        if (trace) fclose(trace);
        return 0;
    }

    int total_toggled = 0;
    for (int screen = 0; screen < 4; ++screen) {
        DWORD ts = GetTickCount();
        int this_drain = uia_drain_toggles_in(dialog, 256);
        total_toggled += this_drain;
        TRACE("PHASE2 screen=%d: drained %d toggles in %ums",
              screen, this_drain, GetTickCount() - ts);

        // Re-try reject labels — scoped to the dialog subtree this time
        int matched = 0;
        for (int i = 0; tries[i]; ++i) {
            if (uia_click_button_by_name_in(dialog, tries[i])) {
                TRACE("PHASE2 screen=%d: matched reject \"%s\" — clicked",
                      screen, tries[i]);
                matched = 1;
                break;
            }
        }
        if (matched) {
            dialog->Release();
            TRACE("EXIT return=1 elapsed=%ums", GetTickCount() - t0);
            if (trace) fclose(trace);
            return 1;
        }

        // Click consent-dialog-scoped Back button
        int went_back = 0;
        for (int i = 0; back_classes[i]; ++i) {
            if (uia_click_button_by_class_in(dialog, back_classes[i])) {
                TRACE("PHASE2 screen=%d: back-click class=\"%s\" OK",
                      screen, back_classes[i]);
                went_back = 1;
                Sleep(150);
                break;
            }
        }
        if (!went_back) {
            TRACE("PHASE2 screen=%d: no back button — exit loop", screen);
            break;
        }

        // Re-root after navigation: the dialog may have torn down
        // its subtree and rebuilt.  Refresh while we still have a
        // dialog class hit.
        if (scoped) {
            dialog->Release();
            dialog = uia_find_consent_root(hwnd);
            if (!dialog) {
                TRACE("PHASE2 screen=%d: dialog vanished after back-click", screen);
                break;
            }
        }
    }

    // Final commit — save/confirm, but ONLY if the panel is FULLY
    // drained.  Clicking Save on a partially-drained panel is exactly
    // what persisted the broken consent cookie, so we verify zero ON
    // toggles remain first and otherwise REFUSE to save.
    int saved = 0;
    if (dialog) {
        int remaining = uia_count_on_toggles_in(dialog);
        TRACE("SAVE-GUARD: %d ON toggles remain", remaining);
        if (!g_consent_allow_auto_save) {
            // Default path — never auto-commit.  We have flipped the
            // toggles off; the user verifies and presses "Confirm
            // choices" themselves.  This is what keeps a partial /
            // broken consent blob from ever being persisted.
            TRACE("SAVE: auto-save OFF — drained %d toggles, %d still ON; "
                  "leaving \"Confirm choices\" to the user",
                  total_toggled, remaining);
        } else if (remaining == 0) {
            for (int i = 0; saves[i]; ++i) {
                if (uia_click_button_by_name_in(dialog, saves[i])) {
                    TRACE("SAVE: matched \"%s\" — clicked", saves[i]);
                    saved = 1;
                    break;
                }
            }
            if (!saved)
                TRACE("SAVE: no save/confirm button found (total_toggled=%d)", total_toggled);
        } else {
            TRACE("SAVE-GUARD: REFUSING to save — %d toggles still ON "
                  "(partial drain would persist a broken consent blob)", remaining);
        }
        dialog->Release();
    }
    // Success = we drained at least one toggle (user will commit) OR
    // an explicit reject button was clicked earlier.  Never depends
    // on an auto-save that we intentionally don't perform.
    int rc = (saved || total_toggled > 0) ? 1 : 0;
    TRACE("EXIT return=%d elapsed=%ums total_toggled=%d", rc, GetTickCount() - t0, total_toggled);
    if (trace) fclose(trace);
    #undef TRACE
    return rc;
}
#endif // retired two-phase ConsentRejectAll_OLD

// ============================================================
// CDP (Chrome DevTools Protocol) client — Direction C, phase C-1.
//
// Lets color_iw scripts drive Edge/Chrome over DevTools: open pages,
// run JS (DOM assertions), and (C-2+) read console errors + network
// failures.  Transport = WinHTTP WebSocket (Win8+); no external libs.
//
// Each browser instance is a (profile dir, debug port) pair, so
// several profiles run at once — port 9222 -> ...\cf22_cdp_9222,
// 9223 -> ...\cf22_cdp_9223, ...  Every export takes the port so a
// script selects which instance it talks to.
//
// Reference: G33kDude/Chrome.ahk.  Critical detail learned there:
// modern Chromium (>=v111) REJECTS the WebSocket upgrade (HTTP 403)
// unless the browser was launched with --remote-allow-origins=*.
// ============================================================
#include <winhttp.h>
#pragma comment(lib, "winhttp.lib")

#define CDP_MAX_CONN 8

#define CDP_LOG_CAP 16384

struct CdpConn {
    int       port;          // 0 = slot free
    HINTERNET hSession;
    HINTERNET hConnect;
    HINTERNET hWebSocket;
    int       nextId;
    // C-2 background reader + event capture --------------------
    HANDLE           hReader;     // reader thread
    volatile LONG    running;
    CRITICAL_SECTION lock;
    HANDLE           respEvent;   // signaled when the awaited response lands
    int              pendingId;   // id cdp_cmd is waiting for (0 = none)
    char*            pendingResp; // reader copies the response here
    int              pendingCap;
    int              pendingLen;
    char  conLog[CDP_LOG_CAP]; int conLen; int conCount;  // console errors
    char  netLog[CDP_LOG_CAP]; int netLen; int netCount;  // network failures
};
static CdpConn g_cdp[CDP_MAX_CONN] = {0};

static CdpConn* cdp_slot_find(int port)
{
    for (int i = 0; i < CDP_MAX_CONN; ++i)
        if (g_cdp[i].port == port && g_cdp[i].hWebSocket) return &g_cdp[i];
    return NULL;
}
static CdpConn* cdp_slot_alloc(int port)
{
    for (int i = 0; i < CDP_MAX_CONN; ++i)
        if (g_cdp[i].port == 0) {
            ZeroMemory(&g_cdp[i], sizeof(CdpConn));
            g_cdp[i].port = port; g_cdp[i].nextId = 1;
            InitializeCriticalSection(&g_cdp[i].lock);
            g_cdp[i].respEvent = CreateEvent(NULL, FALSE, FALSE, NULL); // auto-reset
            g_cdp[i].running = 1;
            return &g_cdp[i];
        }
    return NULL;
}

// --- minimal JSON helpers (we control the queries) ----------------
// pointer just past  "key":  (skips spaces/colon), or NULL
static const char* json_after_key(const char* buf, const char* key)
{
    char pat[64];
    _snprintf(pat, sizeof(pat)-1, "\"%s\"", key); pat[63] = 0;
    const char* p = strstr(buf, pat);
    if (!p) return NULL;
    p += strlen(pat);
    while (*p == ' ' || *p == ':' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    return p;
}
// copy a JSON string value (p at opening quote) into out, unescaping basics
static int json_copy_string(const char* p, char* out, int outlen)
{
    int n = 0;
    if (!p || *p != '"' || outlen <= 0) { if (outlen) out[0] = 0; return 0; }
    p++;
    while (*p && *p != '"' && n < outlen-1) {
        if (*p == '\\' && p[1]) {
            p++;
            char c = *p;
            if (c=='n') c='\n'; else if (c=='t') c='\t'; else if (c=='r') c='\r';
            out[n++] = c; p++;
        } else out[n++] = *p++;
    }
    out[n] = 0;
    return n;
}
// escape an arbitrary string so it can sit inside a JSON "string"
static int json_escape(const char* s, char* out, int outlen)
{
    int n = 0;
    for (; s && *s && n < outlen-2; ++s) {
        char c = *s;
        if      (c=='"'  || c=='\\') { out[n++]='\\'; out[n++]=c; }
        else if (c=='\n') { out[n++]='\\'; out[n++]='n'; }
        else if (c=='\r') { out[n++]='\\'; out[n++]='r'; }
        else if (c=='\t') { out[n++]='\\'; out[n++]='t'; }
        else out[n++]=c;
    }
    if (outlen) out[n]=0;
    return n;
}

// --- HTTP GET on the debug port (for the /json target list) -------
static int cdp_http_get(int port, const char* path, char* out, int outlen)
{
    int got = 0; if (outlen) out[0] = 0;
    HINTERNET hS = WinHttpOpen(L"cf22-cdp", WINHTTP_ACCESS_TYPE_NO_PROXY,
                               WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hS) return 0;
    HINTERNET hC = WinHttpConnect(hS, L"127.0.0.1", (INTERNET_PORT)port, 0);
    if (hC) {
        wchar_t wpath[256]; MultiByteToWideChar(CP_ACP, 0, path, -1, wpath, 256);
        HINTERNET hR = WinHttpOpenRequest(hC, L"GET", wpath, NULL,
                          WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
        if (hR) {
            if (WinHttpSendRequest(hR, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                   WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
                WinHttpReceiveResponse(hR, NULL)) {
                DWORD avail = 0;
                while (WinHttpQueryDataAvailable(hR, &avail) && avail) {
                    if (got + (int)avail > outlen-1) avail = outlen-1-got;
                    if ((int)avail <= 0) break;
                    DWORD rd = 0;
                    if (!WinHttpReadData(hR, out+got, avail, &rd) || rd == 0) break;
                    got += rd; out[got] = 0;
                }
            }
            WinHttpCloseHandle(hR);
        }
        WinHttpCloseHandle(hC);
    }
    WinHttpCloseHandle(hS);
    return got;
}

// pick the first "type":"page" target's webSocketDebuggerUrl path
// (strip ws://host:port, keep /devtools/page/<id>).  Returns 1 on hit.
// Pick a "page" target's WebSocket path.  When wantUrl is given, prefer
// the target whose "url" contains it (so we attach to the tab weburl
// just opened, not a stale tab / the new-tab page); otherwise fall back
// to the first page target.
static int cdp_pick_page_ws(const char* json, char* wspath, int wplen,
                            const char* wantUrl, int allowFallback)
{
    char fallback[512] = {0};
    int  haveFallback = 0;
    const char* t = json;
    while ((t = strstr(t, "\"type\"")) != NULL) {
        const char* v = json_after_key(t, "type");
        if (v && *v == '"' && strncmp(v+1, "page", 4) == 0) {
            char turl[1024] = {0};
            const char* uu = json_after_key(t, "url");      // this target's page url
            if (uu && *uu == '"') json_copy_string(uu, turl, sizeof(turl));
            const char* w = json_after_key(t, "webSocketDebuggerUrl");
            if (w && *w == '"') {
                char full[512]; json_copy_string(w, full, sizeof(full));
                const char* host = strstr(full, "://");
                if (host) {
                    const char* path = strchr(host + 3, '/');
                    if (path) {
                        if (wantUrl && *wantUrl && strstr(turl, wantUrl)) {
                            strncpy(wspath, path, wplen-1); wspath[wplen-1]=0;
                            return 1;                        // exact tab — done
                        }
                        if (!haveFallback) {
                            strncpy(fallback, path, sizeof(fallback)-1);
                            fallback[sizeof(fallback)-1] = 0;
                            haveFallback = 1;
                        }
                    }
                }
            }
        }
        t += 6;
    }
    if (allowFallback && haveFallback) { strncpy(wspath, fallback, wplen-1); wspath[wplen-1]=0; return 1; }
    return 0;
}

// Per-port "URL we launched" so CdpConnect attaches to the right tab.
struct CdpWant { int port; char url[512]; };
static CdpWant g_cdp_want[CDP_MAX_CONN] = {0};
static void cdp_set_want(int port, const char* url)
{
    int free_i = -1;
    for (int i = 0; i < CDP_MAX_CONN; ++i) {
        if (g_cdp_want[i].port == port) {
            strncpy(g_cdp_want[i].url, url ? url : "", 511); g_cdp_want[i].url[511]=0; return;
        }
        if (g_cdp_want[i].port == 0 && free_i < 0) free_i = i;
    }
    if (free_i >= 0) {
        g_cdp_want[free_i].port = port;
        strncpy(g_cdp_want[free_i].url, url ? url : "", 511); g_cdp_want[free_i].url[511]=0;
    }
}
static const char* cdp_get_want(int port)
{
    for (int i = 0; i < CDP_MAX_CONN; ++i)
        if (g_cdp_want[i].port == port) return g_cdp_want[i].url;
    return NULL;
}

// --- open a WebSocket to a page target ----------------------------
static int cdp_ws_open(CdpConn* c, const char* wsPath)
{
    wchar_t wpath[512]; MultiByteToWideChar(CP_ACP, 0, wsPath, -1, wpath, 512);
    c->hSession = WinHttpOpen(L"cf22-cdp", WINHTTP_ACCESS_TYPE_NO_PROXY,
                              WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!c->hSession) return 0;
    c->hConnect = WinHttpConnect(c->hSession, L"127.0.0.1", (INTERNET_PORT)c->port, 0);
    if (!c->hConnect) return 0;
    HINTERNET hR = WinHttpOpenRequest(c->hConnect, L"GET", wpath, NULL,
                      WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
    if (!hR) return 0;
    int ok = 0;
    if (WinHttpSetOption(hR, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, NULL, 0) &&
        WinHttpSendRequest(hR, WINHTTP_NO_ADDITIONAL_HEADERS, 0, NULL, 0, 0, 0) &&
        WinHttpReceiveResponse(hR, NULL)) {
        c->hWebSocket = WinHttpWebSocketCompleteUpgrade(hR, 0);
        ok = (c->hWebSocket != NULL);
    }
    WinHttpCloseHandle(hR);   // request handle no longer needed after upgrade
    return ok;
}

// copy a JSON value (string or scalar token) for `key` into out
static int json_get(const char* buf, const char* key, char* out, int outlen)
{
    const char* p = json_after_key(buf, key);
    if (!p) { if (outlen) out[0] = 0; return 0; }
    if (*p == '"') return json_copy_string(p, out, outlen);
    int n = 0;
    while (p[n] && p[n] != ',' && p[n] != '}' && p[n] != ']' && n < outlen-1) { out[n]=p[n]; n++; }
    if (outlen) out[n] = 0;
    return n;
}
// append a line to a capped log buffer (caller holds the lock)
static void cdp_append(char* log, int cap, int* len, const char* s)
{
    int avail = cap - *len - 2;
    if (avail <= 0) return;
    int n = (int)strlen(s); if (n > avail) n = avail;
    memcpy(log + *len, s, n); *len += n;
    log[(*len)++] = '\n'; log[*len] = 0;
}

// classify one async CDP event into the console/network buckets
// (caller holds c->lock).  Buckets:
//   console  <- Runtime.exceptionThrown, console.error, Log error (non-net)
//   network  <- Network.loadingFailed, Network.responseReceived status>=400
static void cdp_classify_event(CdpConn* c, const char* msg)
{
    const char* meth = json_after_key(msg, "method");
    if (!meth || *meth != '"') return;
    meth++;                                   // past the opening quote
    char val[1024], line[1200];

    if (strncmp(meth, "Network.loadingFailed", 21) == 0) {
        json_get(msg, "errorText", val, sizeof(val));
        _snprintf(line, sizeof(line)-1, "[net] loadingFailed: %s", val); line[1199]=0;
        c->netCount++; cdp_append(c->netLog, CDP_LOG_CAP, &c->netLen, line);
    }
    else if (strncmp(meth, "Network.responseReceived", 24) == 0) {
        char st[16]; json_get(msg, "status", st, sizeof(st));
        int code = atoi(st);
        if (code >= 400) {
            char url[800]; json_get(msg, "url", url, sizeof(url));
            _snprintf(line, sizeof(line)-1, "[net] HTTP %d: %s", code, url); line[1199]=0;
            c->netCount++; cdp_append(c->netLog, CDP_LOG_CAP, &c->netLen, line);
        }
    }
    else if (strncmp(meth, "Runtime.exceptionThrown", 23) == 0) {
        if (!json_get(msg, "description", val, sizeof(val)))
            json_get(msg, "text", val, sizeof(val));
        _snprintf(line, sizeof(line)-1, "[exception] %s", val); line[1199]=0;
        c->conCount++; cdp_append(c->conLog, CDP_LOG_CAP, &c->conLen, line);
    }
    else if (strncmp(meth, "Runtime.consoleAPICalled", 24) == 0) {
        char ty[24]; json_get(msg, "type", ty, sizeof(ty));
        if (strcmp(ty, "error") == 0) {
            json_get(msg, "value", val, sizeof(val));   // first arg (best-effort)
            _snprintf(line, sizeof(line)-1, "[console.error] %s", val); line[1199]=0;
            c->conCount++; cdp_append(c->conLog, CDP_LOG_CAP, &c->conLen, line);
        }
    }
    else if (strncmp(meth, "Log.entryAdded", 14) == 0) {
        char lv[24], src[24];
        json_get(msg, "level", lv, sizeof(lv));
        json_get(msg, "source", src, sizeof(src));
        if (strcmp(lv, "error") == 0 && strcmp(src, "network") != 0) {  // net covered above
            json_get(msg, "text", val, sizeof(val));
            _snprintf(line, sizeof(line)-1, "[log] %s", val); line[1199]=0;
            c->conCount++; cdp_append(c->conLog, CDP_LOG_CAP, &c->conLen, line);
        }
    }
}

// Background reader thread — owns the socket.  Routes the awaited
// command response back to cdp_cmd (via respEvent) and feeds every
// other message to the event classifier.  This is what lets us keep
// CDP domains enabled (event flood) without starving evals.
static DWORD WINAPI cdp_reader(LPVOID param)
{
    CdpConn* c = (CdpConn*)param;
    char* buf = (char*)malloc(262144);
    if (!buf) return 0;
    while (c->running) {
        int total = 0; buf[0] = 0;
        for (;;) {                         // reassemble one (maybe fragmented) message
            DWORD gotb = 0; WINHTTP_WEB_SOCKET_BUFFER_TYPE bt;
            DWORD r = WinHttpWebSocketReceive(c->hWebSocket, buf+total,
                          262144-1-total, &gotb, &bt);
            if (r != NO_ERROR) { free(buf); return 0; }   // socket closed -> exit
            total += gotb; buf[total] = 0;
            if (bt == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE ||
                bt == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE) break;
            if (total >= 262144-1) break;
        }
        EnterCriticalSection(&c->lock);
        int handled = 0;
        if (c->pendingId) {
            char idpat[32]; _snprintf(idpat,sizeof(idpat)-1,"\"id\":%d",c->pendingId); idpat[31]=0;
            const char* m = strstr(buf, idpat);
            if (m) {
                char a = m[strlen(idpat)];
                if (a < '0' || a > '9') {       // exact id (not a prefix)
                    int n = (total < c->pendingCap-1) ? total : c->pendingCap-1;
                    if (c->pendingResp && c->pendingCap > 0) { memcpy(c->pendingResp, buf, n); c->pendingResp[n]=0; }
                    c->pendingLen = n; c->pendingId = 0; handled = 1;
                    SetEvent(c->respEvent);
                }
            }
        }
        if (!handled) cdp_classify_event(c, buf);
        LeaveCriticalSection(&c->lock);
    }
    free(buf);
    return 0;
}

// --- send one CDP command, wait for its response (reader routes it) -
static int cdp_cmd(CdpConn* c, const char* json, int id, char* out, int outlen)
{
    if (!c || !c->hWebSocket) return 0;
    EnterCriticalSection(&c->lock);
    c->pendingId = id; c->pendingResp = out; c->pendingCap = outlen; c->pendingLen = 0;
    ResetEvent(c->respEvent);
    LeaveCriticalSection(&c->lock);

    if (WinHttpWebSocketSend(c->hWebSocket, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
            (PVOID)json, (DWORD)strlen(json)) != NO_ERROR) {
        EnterCriticalSection(&c->lock); c->pendingId = 0; LeaveCriticalSection(&c->lock);
        return 0;
    }
    if (WaitForSingleObject(c->respEvent, 10000) != WAIT_OBJECT_0) {  // 10s
        EnterCriticalSection(&c->lock); c->pendingId = 0; LeaveCriticalSection(&c->lock);
        return 0;
    }
    return c->pendingLen;
}

// ============================================================
// CdpLaunchEdge(url, port, profileDir) → 1 launched, 0 failed.
// Launches Edge with the debug port + a dedicated profile.  Pass
// port 0 to default to 9222.  --remote-allow-origins=* is required
// or the later WebSocket upgrade is refused.
// ============================================================
extern "C" __declspec(dllexport)
int __stdcall CdpLaunchEdge(const char* url, int port, const char* profileDir)
{
    if (port <= 0) port = 9222;
    const char* u  = (url && *url) ? url : "about:blank";
    const char* pd = (profileDir && *profileDir) ? profileDir : "C:\\cf22_cdp";
    cdp_set_want(port, u);                 // CdpConnect attaches to this tab
    char args[1100];
    _snprintf(args, sizeof(args)-1,
        // Open a BLANK window, not the target URL: CdpConnect drives the
        // tab to the URL with Page.navigate.  Loading the URL here too
        // would race that navigate and the aborted in-flight request
        // shows up as a bogus net::ERR_ABORTED network failure.
        " --remote-debugging-port=%d --remote-allow-origins=*"
        " --user-data-dir=\"%s\" --no-first-run --no-default-browser-check"
        " --new-window \"about:blank\"", port, pd);
    args[sizeof(args)-1] = 0;
    (void)u;   // url is recorded via cdp_set_want above; not launched directly

    // Try msedge.exe via App Paths (CreateProcess searches PATH), then
    // the standard install location.
    static const char* exes[] = {
        "msedge.exe",
        "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
        "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
        NULL
    };
    for (int i = 0; exes[i]; ++i) {
        char cmd[1300];
        _snprintf(cmd, sizeof(cmd)-1, "\"%s\"%s", exes[i], args);
        cmd[sizeof(cmd)-1] = 0;
        STARTUPINFOA si = { sizeof(si) };
        PROCESS_INFORMATION pi = {0};
        if (CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
            CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
            return 1;
        }
    }
    return 0;
}

// ============================================================
// CdpConnect(port) → 1 connected, 0 failed.
// Polls /json (Edge needs a moment to expose the page target),
// opens a WebSocket to the first "page" target, enables Runtime.
// ============================================================
extern "C" __declspec(dllexport)
int __stdcall CdpConnect(int port)
{
    if (port <= 0) port = 9222;
    if (cdp_slot_find(port)) return 1;          // already connected

    const char* want = cdp_get_want(port);  // URL to drive the tab to (Page.navigate)
    char* list = (char*)malloc(65536);
    char  wspath[512] = {0};
    int   found = 0;
    for (int tries = 0; tries < 40 && !found; ++tries) {  // ~40 * 250ms = 10s
        int n = cdp_http_get(port, "/json", list, 65536);
        // Prefer the blank window weburl just opened so the tab we drive
        // is the VISIBLE one (not a stale background tab); after ~2s
        // accept any page as a fallback.
        int strict = (tries < 8);
        if (n > 0 && cdp_pick_page_ws(list, wspath, sizeof(wspath),
                                      strict ? "about:blank" : NULL, !strict)) found = 1;
        else Sleep(250);
    }
    free(list);
    if (!found) return 0;

    CdpConn* c = cdp_slot_alloc(port);
    if (!c) return 0;
    if (!cdp_ws_open(c, wspath)) { c->port = 0; return 0; }

    // Start the background reader, THEN enable the event domains so it
    // captures their responses + the events that follow.  Unlike C-1
    // (which avoided enable to keep the socket quiet), the reader
    // thread now drains events into the console/network buckets while
    // cdp_cmd still gets clean responses via the pending-id slot.
    c->hReader = CreateThread(NULL, 0, cdp_reader, c, 0, NULL);

    char resp[8192], msg[128];
    static const char* enables[] = { "Runtime.enable", "Log.enable", "Network.enable", NULL };
    for (int i = 0; enables[i]; ++i) {
        int id = c->nextId++;
        _snprintf(msg, sizeof(msg)-1, "{\"id\":%d,\"method\":\"%s\"}", id, enables[i]); msg[127]=0;
        cdp_cmd(c, msg, id, resp, sizeof(resp));
    }

    // Drive the connected tab to the launched URL.  Robust to which tab
    // we attached to: --new-window can land the page in a tab we never
    // poll (stale instance / forwarded launch / new-tab page), so rather
    // than hunt for it we navigate the target we DO hold and wait for
    // load.  Because Runtime/Log/Network are already enabled, the page's
    // load-time console + network events are captured too.
    if (want && *want) {
        char esc[600]; json_escape(want, esc, sizeof(esc));
        char nav[800];
        int nid = c->nextId++;
        _snprintf(nav, sizeof(nav)-1,
            "{\"id\":%d,\"method\":\"Page.navigate\",\"params\":{\"url\":\"%s\"}}", nid, esc);
        nav[sizeof(nav)-1] = 0;
        cdp_cmd(c, nav, nid, resp, sizeof(resp));
        // Wait until the tab is loaded AND actually showing the target
        // URL.  Checking readyState alone races: right after navigate the
        // PRE-navigation document can still report "complete", so we'd
        // return while the new page is still loading.  Requiring the URL
        // to match too defeats that.
        char js[900];
        _snprintf(js, sizeof(js)-1,
            "document.readyState==='complete' && location.href.indexOf(\"%s\")!==-1", want);
        js[sizeof(js)-1] = 0;
        char jesc[1400]; json_escape(js, jesc, sizeof(jesc));
        for (int i = 0; i < 60; ++i) {            // wait up to ~6s
            int eid = c->nextId++;
            char em[1700];
            _snprintf(em, sizeof(em)-1,
                "{\"id\":%d,\"method\":\"Runtime.evaluate\",\"params\":"
                "{\"expression\":\"%s\",\"returnByValue\":true}}", eid, jesc);
            em[sizeof(em)-1] = 0;
            if (cdp_cmd(c, em, eid, resp, sizeof(resp)) > 0) {
                const char* v = json_after_key(resp, "value");
                if (v && strncmp(v, "true", 4) == 0) break;   // loaded + on target URL
            }
            Sleep(100);
        }
    }
    return 1;
}

// ============================================================
// CdpEval(port, expr, out, outlen) → length of result, or -1.
// Runs JS via Runtime.evaluate(returnByValue) and copies the
// result value into out.  String -> the text; bool/number/null ->
// the token; exception/undefined -> "<exception>"/"<undefined>".
// ============================================================
extern "C" __declspec(dllexport)
int __stdcall CdpEval(int port, const char* expr, char* out, int outlen)
{
    if (port <= 0) port = 9222;
    if (out && outlen) out[0] = 0;
    CdpConn* c = cdp_slot_find(port);
    if (!c) return -1;

    char  esc[8192]; json_escape(expr, esc, sizeof(esc));
    char* msg  = (char*)malloc(strlen(esc) + 256);
    char* resp = (char*)malloc(262144);
    int   id   = c->nextId++;
    sprintf(msg, "{\"id\":%d,\"method\":\"Runtime.evaluate\",\"params\":"
                 "{\"expression\":\"%s\",\"returnByValue\":true,"
                 "\"awaitPromise\":true,\"userGesture\":true}}", id, esc);

    int got = cdp_cmd(c, msg, id, resp, 262144);
    int rv = -1;
    if (got > 0) {
        if (strstr(resp, "\"exceptionDetails\"")) {
            strncpy(out, "<exception>", outlen-1); out[outlen-1]=0;
            rv = (int)strlen(out);
        } else {
            const char* v = json_after_key(resp, "value");
            if (v && *v == '"') {
                rv = json_copy_string(v, out, outlen);
            } else if (v) {                 // number / bool / null token
                int n = 0;
                while (v[n] && v[n] != ',' && v[n] != '}' && n < outlen-1) { out[n]=v[n]; n++; }
                out[n] = 0; rv = n;
            } else {                        // result with no value -> undefined
                strncpy(out, "<undefined>", outlen-1); out[outlen-1]=0;
                rv = (int)strlen(out);
            }
        }
    } else {                                // no matching response came back
        strncpy(out, "<no response>", outlen-1); out[outlen-1]=0;
        rv = -1;
    }
    free(msg); free(resp);
    return rv;
}

// ============================================================
// Teardown.  Closing the WebSocket makes the reader thread's blocking
// WinHttpWebSocketReceive fail, so the thread returns; we then join
// it and free the handles.  WITHOUT this, the reader thread keeps the
// host process (e.g. rundll32) alive and helpers.dll stays locked,
// blocking the next rebuild.  Always call before a test host exits.
// ============================================================
static void cdp_conn_close(CdpConn* c)
{
    if (!c || c->port == 0) return;
    c->running = 0;
    if (c->hWebSocket) {
        WinHttpWebSocketClose(c->hWebSocket, WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS, NULL, 0);
        WinHttpCloseHandle(c->hWebSocket);     // unblocks the reader's Receive
        c->hWebSocket = NULL;
    }
    if (c->hReader) {
        WaitForSingleObject(c->hReader, 3000); // join (reader is exiting)
        CloseHandle(c->hReader); c->hReader = NULL;
    }
    if (c->hConnect)  { WinHttpCloseHandle(c->hConnect);  c->hConnect  = NULL; }
    if (c->hSession)  { WinHttpCloseHandle(c->hSession);  c->hSession  = NULL; }
    if (c->respEvent) { CloseHandle(c->respEvent);        c->respEvent = NULL; }
    DeleteCriticalSection(&c->lock);
    c->port = 0;                               // slot free for reuse
}

extern "C" __declspec(dllexport)
int __stdcall CdpDisconnect(int port)
{
    if (port <= 0) port = 9222;
    CdpConn* c = cdp_slot_find(port);
    if (!c) return 0;
    cdp_conn_close(c);
    return 1;
}

extern "C" __declspec(dllexport)
void __stdcall CdpShutdown(void)
{
    for (int i = 0; i < CDP_MAX_CONN; ++i)
        if (g_cdp[i].port) cdp_conn_close(&g_cdp[i]);
}

// ============================================================
// Self-test reporting.  Each rundll32 self-test appends its verdict
// line ("CDP C-1 PASS ...", etc.) to D:\cf22\cdp_selftest.log so a
// driver (run_selftests.py) can grep the result.  Passing `auto`
// anywhere on the rundll32 command line suppresses the MessageBox, so
// the cycle runs unattended AND rundll32 exits (no DLL lock).
// ============================================================
static void cdp_selftest_log(const char* line)
{
    FILE* f = fopen("D:\\cf22\\cdp_selftest.log", "a");
    if (f) { fputs(line, f); fputc('\n', f); fclose(f); }
}
// Split the rundll32 cmdline into a URL (minus the "auto" word) + the
// auto flag.  Returns 1 if "auto" was present as a whole token.
static int cdp_selftest_args(const char* cmdline, char* urlbuf, int urllen, const char* defurl)
{
    char buf[1024];
    strncpy(buf, cmdline ? cmdline : "", sizeof(buf)-1); buf[sizeof(buf)-1] = 0;
    int autom = 0;
    char* p = buf;
    while ((p = strstr(p, "auto")) != NULL) {
        int wbefore = (p == buf) || (p[-1] == ' ');
        int wafter  = (p[4] == 0)  || (p[4] == ' ');
        if (wbefore && wafter) {
            autom = 1;
            if (p > buf && p[-1] == ' ') p[-1] = 0; else *p = 0;
            break;
        }
        p += 4;
    }
    int n = (int)strlen(buf);
    while (n > 0 && buf[n-1] == ' ') buf[--n] = 0;   // trim trailing spaces
    const char* url = buf[0] ? buf : defurl;
    strncpy(urlbuf, url, urllen-1); urlbuf[urllen-1] = 0;
    return autom;
}
static void cdp_selftest_report(int autom, const char* title, const char* body)
{
    cdp_selftest_log(body);
    if (!autom) MessageBoxA(NULL, body, title, MB_OK | MB_ICONINFORMATION);
}

// ============================================================
// CdpSelfTestRun — rundll32-callable smoke test (no asm needed):
//   rundll32 lib_cf22_h\Release\helpers.dll,CdpSelfTestRun https://example.com
// Launches Edge on 9222 w/ a dedicated profile, connects, waits for
// load, reads location.host + document.title, shows a MessageBox.
// ============================================================
extern "C" __declspec(dllexport)
void CALLBACK CdpSelfTestRun(HWND hwnd, HINSTANCE hinst, LPSTR cmdline, int show)
{
    char url[1024];
    int autom = cdp_selftest_args(cmdline, url, sizeof(url), "https://example.com");
    int port = 9222;
    char msg[2048], host[1024]={0}, title[1024]={0}, ready[64]={0};

    CdpLaunchEdge(url, port, "C:\\cf22_cdp_9222");
    if (!CdpConnect(port)) {
        cdp_selftest_report(autom, "cf22 CDP self-test",
            "CDP C-1 FAIL: CdpConnect failed (port 9222)");
        return;
    }
    for (int i = 0; i < 50; ++i) {          // wait up to ~5s for load
        CdpEval(port, "document.readyState", ready, sizeof(ready));
        if (strcmp(ready, "complete") == 0) break;
        Sleep(100);
    }
    CdpEval(port, "location.host", host, sizeof(host));
    CdpEval(port, "document.title", title, sizeof(title));
    int pass = (host[0] != 0 && title[0] != 0);   // connected + read DOM
    _snprintf(msg, sizeof(msg)-1,
        "CDP C-1 %s on port %d  readyState=%s host=%s title=%s",
        pass ? "PASS" : "FAIL", port, ready, host, title);
    msg[sizeof(msg)-1] = 0;
    CdpShutdown();   // join reader threads so rundll32 can exit + unlock the DLL
    cdp_selftest_report(autom, "cf22 CDP self-test", msg);
}

// ============================================================
// CdpGetConsoleErrors(port, out, outlen) → count of console errors
//   captured since connect/clear (out gets the accumulated lines).
// CdpGetNetworkFailures(port, out, outlen) → same for failed/4xx-5xx
//   network requests.  CdpClearLog(port) resets both (use between
//   tests).  Returns -1 if not connected.
// ============================================================
extern "C" __declspec(dllexport)
int __stdcall CdpGetConsoleErrors(int port, char* out, int outlen)
{
    if (port <= 0) port = 9222;
    if (out && outlen) out[0] = 0;
    CdpConn* c = cdp_slot_find(port);
    if (!c) return -1;
    EnterCriticalSection(&c->lock);
    int cnt = c->conCount;
    if (out && outlen) { int n = (c->conLen < outlen-1) ? c->conLen : outlen-1; memcpy(out, c->conLog, n); out[n]=0; }
    LeaveCriticalSection(&c->lock);
    return cnt;
}
extern "C" __declspec(dllexport)
int __stdcall CdpGetNetworkFailures(int port, char* out, int outlen)
{
    if (port <= 0) port = 9222;
    if (out && outlen) out[0] = 0;
    CdpConn* c = cdp_slot_find(port);
    if (!c) return -1;
    EnterCriticalSection(&c->lock);
    int cnt = c->netCount;
    if (out && outlen) { int n = (c->netLen < outlen-1) ? c->netLen : outlen-1; memcpy(out, c->netLog, n); out[n]=0; }
    LeaveCriticalSection(&c->lock);
    return cnt;
}
extern "C" __declspec(dllexport)
int __stdcall CdpClearLog(int port)
{
    if (port <= 0) port = 9222;
    CdpConn* c = cdp_slot_find(port);
    if (!c) return -1;
    EnterCriticalSection(&c->lock);
    c->conLen = c->conCount = 0; c->conLog[0] = 0;
    c->netLen = c->netCount = 0; c->netLog[0] = 0;
    LeaveCriticalSection(&c->lock);
    return 0;
}

// ============================================================
// CdpC2SelfTestRun — rundll32-callable C-2 smoke test:
//   rundll32 ...\helpers.dll,CdpC2SelfTestRun  [optional url]
// Opens a page on a 2nd profile (port 9223), triggers one console
// error + one failing fetch, waits, then shows the captured console
// errors + network failures.  Proves the event-capture pipeline.
// ============================================================
extern "C" __declspec(dllexport)
void CALLBACK CdpC2SelfTestRun(HWND hwnd, HINSTANCE hinst, LPSTR cmdline, int show)
{
    int port = 9223;
    char url[1024];
    int autom = cdp_selftest_args(cmdline, url, sizeof(url), "about:blank");
    char con[8192]={0}, net[8192]={0}, dummy[256], msg[20000];

    CdpLaunchEdge(url, port, "C:\\cf22_cdp_9223");
    if (!CdpConnect(port)) {
        cdp_selftest_report(autom, "cf22 CDP C-2 self-test",
            "CDP C-2 FAIL: CdpConnect failed (port 9223)");
        return;
    }
    CdpEval(port, "console.error('cf22 test console error')", dummy, sizeof(dummy));
    CdpEval(port, "fetch('https://cf22-no-such-host.invalid/').catch(function(){})",
            dummy, sizeof(dummy));
    Sleep(2500);                         // let the async events land
    int nc = CdpGetConsoleErrors(port, con, sizeof(con));
    int nf = CdpGetNetworkFailures(port, net, sizeof(net));
    int pass = (nc > 0 && nf > 0);
    _snprintf(msg, sizeof(msg)-1,
        "CDP C-2 %s on port %d (console_errors=%d net_failures=%d)\n%s%s",
        pass ? "PASS" : "FAIL", port, nc, nf, con, net);
    msg[sizeof(msg)-1] = 0;
    CdpShutdown();   // join reader threads so rundll32 can exit + unlock the DLL
    cdp_selftest_report(autom, "cf22 CDP C-2 self-test", msg);
}

// ============================================================
// CdpCheckHealth(port, healthJS, out, outlen) → verdict:
//    1 = OK (working), 0 = BROKEN, -1 = DEAD (not connected/no reply).
// The building block for monitoring ("is the page working?").  Evals
// healthJS (a JS boolean; default = page loaded + has a body) and
// reports it together with the accumulated console-error and
// network-failure counts in `out`.  A webwatch loop calls this on a
// timer; the caller decides whether non-zero error counts also mean
// broken for their page.
// ============================================================
extern "C" __declspec(dllexport)
int __stdcall CdpCheckHealth(int port, const char* healthJS, char* out, int outlen)
{
    if (port <= 0) port = 9222;
    if (out && outlen) out[0] = 0;
    CdpConn* c = cdp_slot_find(port);
    if (!c) {
        if (out && outlen) { _snprintf(out, outlen-1, "DEAD: port %d not connected", port); out[outlen-1]=0; }
        return -1;
    }
    const char* hj = (healthJS && *healthJS)
        ? healthJS
        : "document.readyState==='complete' && !!document.body";

    char r[512];
    int n = CdpEval(port, hj, r, sizeof(r));
    int ce, nf;
    EnterCriticalSection(&c->lock); ce = c->conCount; nf = c->netCount; LeaveCriticalSection(&c->lock);

    if (n < 0 || strcmp(r, "<no response>") == 0 || strcmp(r, "<exception>") == 0) {
        if (out && outlen) { _snprintf(out, outlen-1,
            "BROKEN: page not responding (eval=%s) console_err=%d net_fail=%d", r, ce, nf); out[outlen-1]=0; }
        return 0;
    }
    int healthy = (strcmp(r, "true") == 0);
    if (out && outlen) { _snprintf(out, outlen-1,
        "%s: health=%s console_err=%d net_fail=%d", healthy ? "OK" : "BROKEN", r, ce, nf); out[outlen-1]=0; }
    return healthy ? 1 : 0;
}

// ============================================================
// CdpWatchSelfTestRun — rundll32-callable C-3 demo:
//   rundll32 ...\helpers.dll,CdpWatchSelfTestRun  [optional url]
// Connects (port 9224), then takes 3 health snapshots to show the
// verdict change: healthy -> healthy-with-errors -> broken (a health
// expression that requires a missing element).
// ============================================================
extern "C" __declspec(dllexport)
void CALLBACK CdpWatchSelfTestRun(HWND hwnd, HINSTANCE hinst, LPSTR cmdline, int show)
{
    int port = 9224;
    char url[1024];
    int autom = cdp_selftest_args(cmdline, url, sizeof(url), "https://example.com");
    char l1[512]={0}, l2[512]={0}, l3[512]={0}, dummy[256], msg[4096], rs[64];

    CdpLaunchEdge(url, port, "C:\\cf22_cdp_9224");
    if (!CdpConnect(port)) {
        cdp_selftest_report(autom, "cf22 CDP C-3 watch",
            "CDP C-3 FAIL: CdpConnect failed (port 9224)");
        return;
    }
    for (int i = 0; i < 50; ++i) {            // wait for load
        CdpEval(port, "document.readyState", rs, sizeof(rs));
        if (strcmp(rs, "complete") == 0) break;
        Sleep(100);
    }
    int v1 = CdpCheckHealth(port, NULL, l1, sizeof(l1));            // healthy
    CdpEval(port, "console.error('watch test'); "
                  "fetch('https://cf22-bad.invalid/').catch(function(){})",
            dummy, sizeof(dummy));
    Sleep(1500);
    int v2 = CdpCheckHealth(port, NULL, l2, sizeof(l2));            // healthy, errors present
    int v3 = CdpCheckHealth(port, "!!document.querySelector('#cf22-not-here')",
                            l3, sizeof(l3));                       // broken (missing element)
    int pass = (v1 == 1 && v2 == 1 && v3 == 0);  // healthy, healthy, broken

    _snprintf(msg, sizeof(msg)-1,
        "CDP C-3 %s on port %d (v1=%d v2=%d v3=%d)\n"
        "1) initial:          %s\n"
        "2) after errors:     %s\n"
        "3) missing element:  %s",
        pass ? "PASS" : "FAIL", port, v1, v2, v3, l1, l2, l3);
    msg[sizeof(msg)-1] = 0;
    CdpShutdown();
    cdp_selftest_report(autom, "cf22 CDP C-3 watch self-test", msg);
}

// ============================================================
// UncheckAll(hwnd) → count of checkboxes toggled OFF.
// Walks every CheckBox descendant; if state is ON, calls Toggle().
// ============================================================
extern "C" __declspec(dllexport)
int __stdcall UncheckAll(HWND hwnd)
{
    IUIAutomationElement* root = uia_root_for(hwnd);
    if (!root) return -1;
    IUIAutomationElementArray* arr = uia_find_all(root, UIA_CheckBoxControlTypeId);
    int toggled = 0;
    if (arr) {
        int len = 0;
        arr->get_Length(&len);
        for (int i = 0; i < len; ++i) {
            IUIAutomationElement* chk = NULL;
            arr->GetElement(i, &chk);
            if (!chk) continue;
            IUIAutomationTogglePattern* tog = NULL;
            chk->GetCurrentPatternAs(UIA_TogglePatternId,
                                      __uuidof(IUIAutomationTogglePattern),
                                      (void**)&tog);
            if (tog) {
                ToggleState st = ToggleState_Indeterminate;
                if (SUCCEEDED(tog->get_CurrentToggleState(&st))) {
                    if (st == ToggleState_On) {
                        if (SUCCEEDED(tog->Toggle())) toggled++;
                    }
                }
                tog->Release();
            }
            chk->Release();
        }
        arr->Release();
    }
    root->Release();
    return toggled;
}