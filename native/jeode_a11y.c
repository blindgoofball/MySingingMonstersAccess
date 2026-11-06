/* ---------------------------------------------------------------------------
   jeode_a11y.c  -  Jeode native-mod entry point for the MSM accessibility mod.

   This REPLACES the old dllmain.c + lua_hook.c injection path. Under Jeode we
   no longer proxy version.dll, hunt luaopen_game's RVA, or install our own
   MinHook detour -- Jeode's winhttp.dll proxy loads us, and its scheduler hook
   marshals our C functions onto the game's Lua thread.

   All the heavy lifting (Prism load, UTF-8->UTF-16, screen-reader output) is
   reused unchanged from accessibility_bridge.c via its public A11Y_* API. The
   only Lua-C-API calls here are stack accessors (luaL_checkstring /
   lua_toboolean / lua_pushboolean) from our statically-linked, ABI-compatible
   lua51 -- the same combo Milestone 1 proved works against the game's L.

   Build target: a11y.dll  ->  copy to  mods/msm-a11y/a11y.dll
   Alongside it in mods/msm-a11y/:  prism.dll (32-bit; InitSpeech loads it
   from the DLL's own folder).
   --------------------------------------------------------------------------- */

#include "jeode/jeode_native.h"
#include "accessibility_bridge.h"
#include "lua51/lua.h"
#include "lua51/lauxlib.h"

#include "minhook/include/MinHook.h"

#include <windows.h>
#include <process.h>
#include <string.h>
#include <stdlib.h>

static const struct JeodeNativeAPI *g_api = NULL;

/* ---------------------------------------------------------------------------
   Ctrl+Shift+A  ->  speak a HUD summary on demand.

   A tiny background thread polls the key combo. It NEVER touches Lua/game
   state itself; on a debounced press it hands the work to Jeode via
   queue_lua(), which runs it on the game's Lua thread at a safe scheduler
   boundary (the same safety principle M1 achieved with a Lua count-hook, but
   Jeode gives it to us for free). The actual reads live in init.lua's
   shared.a11y.announceHud, so we can iterate them without rebuilding this DLL.
   --------------------------------------------------------------------------- */

#define KEY_DOWN(vk)        (GetAsyncKeyState(vk) & 0x8000)
#define HOTKEY_POLL_MS      10
/* Keys that act (Enter, Escape, arrows that drag, Ctrl+Shift commands) keep a
   long debounce so a bounce can't press twice. Moving keys (Tab, Shift+Tab,
   Home, End) only move focus, so fast typists get every press, and
   holding Tab or Shift+Tab repeats like it does in Windows. */
#define HOTKEY_DEBOUNCE_MS  250
#define MOVE_DEBOUNCE_MS    40
#define REPEAT_DELAY_MS     400
#define REPEAT_EVERY_MS     90

static HANDLE        g_hotkeyThread  = NULL;
static volatile LONG g_hotkeyRunning = 0;

/* Only fire when the game window is in the foreground, so keys typed into some
   other app don't drive the screen reader / press MSM buttons. */
static int game_is_foreground(void)
{
    HWND fg = GetForegroundWindow();
    DWORD pid = 0;
    if (!fg) return 0;
    GetWindowThreadProcessId(fg, &pid);
    return pid == GetCurrentProcessId();
}

/* Hotkey actions. Each maps to a global exposed by init.lua (via
   jeode.registerGlobal) and runs on the game thread through queue_lua -- a safe
   frame boundary. Nav handlers are silent when no real popup is open, so plain
   Tab/Enter during normal play are harmless no-ops. */
enum { HK_HUD = 0, HK_NAV_NEXT, HK_NAV_PREV, HK_ACTIVATE, HK_MENU, HK_TUTORIAL, HK_TUTSTEP, HK_DUMP, HK_OBJECTS, HK_LEFT, HK_RIGHT, HK_UP, HK_DOWN, HK_WHATNOW, HK_ESCAPE, HK_BACKSPACE, HK_POI_PREV, HK_POI_NEXT, HK_SPOT_PREV, HK_SPOT_NEXT, HK_CAMERA, HK_HOME, HK_END, HK_COUNT };

static const char *const g_hkLua[HK_COUNT] = {
    /* HK_HUD (Ctrl+Shift+A) */
    "if type(a11y_announceHud)=='function' then a11y_announceHud() "
    "elseif type(a11y_speak)=='function' then a11y_speak('HUD reader not registered',true) end",
    /* HK_NAV_NEXT (Tab) */
    "if type(a11y_navNext)=='function' then a11y_navNext() end",
    /* HK_NAV_PREV (Shift+Tab) */
    "if type(a11y_navPrev)=='function' then a11y_navPrev() end",
    /* HK_ACTIVATE (Enter) */
    "if type(a11y_navActivate)=='function' then a11y_navActivate() end",
    /* HK_MENU (Ctrl+Shift+M) -- toggle the Places menu */
    "if type(a11y_menu)=='function' then a11y_menu() end",
    /* HK_TUTORIAL (Ctrl+Shift+Enter) -- advance a tutorial speech step */
    "if type(a11y_tutorialContinue)=='function' then a11y_tutorialContinue() end",
    /* HK_TUTSTEP (Ctrl+Shift+T) -- announce current tutorial step (+ description) */
    "if type(a11y_tutorial_announce)=='function' then a11y_tutorial_announce() "
    "elseif type(a11y_tutorial_step)=='function' then local s,m=a11y_tutorial_step() "
    "if s and s>=0 then a11y_speak('step '..(s+1)..' of '..m,true) else a11y_speak('No tutorial active',true) end end",
    /* HK_DUMP (Ctrl+Shift+D) -- diagnostic UI tree dump to accessibility.log */
    "if type(a11y_dump)=='function' then a11y_dump() end",
    /* HK_OBJECTS (Ctrl+Shift+O) -- list island structures and monsters to select */
    "if type(a11y_objects)=='function' then a11y_objects() end",
    /* HK_LEFT/RIGHT/UP/DOWN (arrows) -- move the object being placed; no-op otherwise */
    "if type(a11y_arrow)=='function' then a11y_arrow(-1,0) end",
    "if type(a11y_arrow)=='function' then a11y_arrow(1,0) end",
    "if type(a11y_arrow)=='function' then a11y_arrow(0,-1) end",
    "if type(a11y_arrow)=='function' then a11y_arrow(0,1) end",
    /* HK_WHATNOW (Ctrl+Shift+W) -- what's ready + current goals */
    "if type(a11y_whatnow)=='function' then a11y_whatnow() end",
    /* HK_ESCAPE / HK_BACKSPACE -- go back: close, cancel, no, deselect */
    "if type(a11y_back)=='function' then a11y_back('escape') end",
    "if type(a11y_back)=='function' then a11y_back('backspace') end",
    /* HK_POI_PREV / HK_POI_NEXT ([ and ]) -- while placing, jump next to an object */
    "if type(a11y_poi)=='function' then a11y_poi(-1) end",
    "if type(a11y_poi)=='function' then a11y_poi(1) end",
    /* HK_SPOT_PREV / HK_SPOT_NEXT (comma, period) -- next free spot near the chosen object */
    "if type(a11y_spot)=='function' then a11y_spot(-1) end",
    "if type(a11y_spot)=='function' then a11y_spot(1) end",
    /* HK_CAMERA (Ctrl+Shift+C) -- put the camera back on the island's default view */
    "if type(a11y_camera)=='function' then a11y_camera() end",
    /* HK_HOME / HK_END -- first / last item of the current list */
    "if type(a11y_navEdge)=='function' then a11y_navEdge(-1) end",
    "if type(a11y_navEdge)=='function' then a11y_navEdge(1) end",
};

static unsigned __stdcall HotkeyProc(void *param)
{
    int   prev[HK_COUNT];
    DWORD last[HK_COUNT];
    DWORD since[HK_COUNT];
    int   i;
    (void)param;

    for (i = 0; i < HK_COUNT; i++) { prev[i] = 0; last[i] = 0; since[i] = 0; }

    A11Y_Log("Hotkey thread started (Ctrl+Shift+A = HUD; Tab/Shift+Tab/Enter = nav)");

    while (InterlockedCompareExchange(&g_hotkeyRunning, 1, 1)) {
        int ctrl  = KEY_DOWN(VK_CONTROL) ? 1 : 0;
        int shift = KEY_DOWN(VK_SHIFT)   ? 1 : 0;
        DWORD now = GetTickCount();

        int down[HK_COUNT];
        down[HK_HUD]      = ctrl && shift && KEY_DOWN('A');
        down[HK_MENU]     = ctrl && shift && KEY_DOWN('M');
        down[HK_TUTORIAL] = ctrl && shift && KEY_DOWN(VK_RETURN);
        down[HK_TUTSTEP]  = ctrl && shift && KEY_DOWN('T');
        down[HK_DUMP]     = ctrl && shift && KEY_DOWN('D');
        down[HK_OBJECTS]  = ctrl && shift && KEY_DOWN('O');
        down[HK_LEFT]     = !ctrl && !shift && KEY_DOWN(VK_LEFT);
        down[HK_RIGHT]    = !ctrl && !shift && KEY_DOWN(VK_RIGHT);
        down[HK_UP]       = !ctrl && !shift && KEY_DOWN(VK_UP);
        down[HK_DOWN]     = !ctrl && !shift && KEY_DOWN(VK_DOWN);
        down[HK_WHATNOW]  = ctrl && shift && KEY_DOWN('W');
        down[HK_NAV_PREV] = shift && !ctrl && KEY_DOWN(VK_TAB);
        down[HK_NAV_NEXT] = !shift && !ctrl && KEY_DOWN(VK_TAB);
        down[HK_ACTIVATE] = !shift && !ctrl && KEY_DOWN(VK_RETURN);
        down[HK_ESCAPE]    = !shift && !ctrl && KEY_DOWN(VK_ESCAPE);
        down[HK_BACKSPACE] = !shift && !ctrl && KEY_DOWN(VK_BACK);
        down[HK_POI_PREV]  = !shift && !ctrl && KEY_DOWN(VK_OEM_4);
        down[HK_POI_NEXT]  = !shift && !ctrl && KEY_DOWN(VK_OEM_6);
        down[HK_SPOT_PREV] = !shift && !ctrl && KEY_DOWN(VK_OEM_COMMA);
        down[HK_SPOT_NEXT] = !shift && !ctrl && KEY_DOWN(VK_OEM_PERIOD);
        down[HK_CAMERA]    = ctrl && shift && KEY_DOWN('C');
        down[HK_HOME]      = !shift && !ctrl && KEY_DOWN(VK_HOME);
        down[HK_END]       = !shift && !ctrl && KEY_DOWN(VK_END);

        for (i = 0; i < HK_COUNT; i++) {
            /* Brackets and comma/period drag the object while placing: not here. */
            int moving = i == HK_NAV_NEXT || i == HK_NAV_PREV || i == HK_HOME || i == HK_END;
            int repeats = i == HK_NAV_NEXT || i == HK_NAV_PREV;
            DWORD debounce = moving ? MOVE_DEBOUNCE_MS : HOTKEY_DEBOUNCE_MS;
            int fire = 0;
            if (down[i] && !prev[i]) {
                since[i] = now;
                fire = (now - last[i]) >= debounce;
            } else if (down[i] && repeats && (now - since[i]) >= REPEAT_DELAY_MS &&
                       (now - last[i]) >= REPEAT_EVERY_MS) {
                fire = 1;
            }
            if (fire) {
                last[i] = now;
                if (game_is_foreground() && g_api && g_api->is_lua_ready()) {
                    if (i == HK_HUD) A11Y_Log("Ctrl+Shift+A -> HUD announce");
                    g_api->queue_lua(g_hkLua[i], "=a11y_hotkey");
                }
            }
            prev[i] = down[i];
        }
        Sleep(HOTKEY_POLL_MS);
    }

    A11Y_Log("Hotkey thread exiting");
    return 0;
}

/* ---------------------------------------------------------------------------
   Mouse drag (a11y_drag). Placing or moving an object is a drag in the game.
   The drag runs on its own thread with small sleeps, so the game sees the
   press, the movement and the release across separate frames, like a real
   drag, instead of all at once.
   --------------------------------------------------------------------------- */
#define DRAG_STEPS     8
#define DRAG_STEP_MS   16
#define DRAG_HOLD_MS   50

typedef struct { double fx1, fy1, fx2, fy2; } DragJob;
static volatile LONG g_dragBusy = 0;

static int client_point(HWND hwnd, double fx, double fy, POINT *pt)
{
    RECT rc;
    if (!GetClientRect(hwnd, &rc)) return 0;
    pt->x = (LONG)(rc.right * fx);
    pt->y = (LONG)(rc.bottom * fy);
    return ClientToScreen(hwnd, pt);
}

static unsigned __stdcall DragProc(void *param)
{
    DragJob job = *(DragJob *)param;
    HWND hwnd = GetForegroundWindow();
    DWORD pid = 0;
    POINT a, b, saved;
    int i;
    free(param);

    if (hwnd) GetWindowThreadProcessId(hwnd, &pid);
    if (!hwnd || pid != GetCurrentProcessId() ||
        !client_point(hwnd, job.fx1, job.fy1, &a) || !client_point(hwnd, job.fx2, job.fy2, &b)) {
        InterlockedExchange(&g_dragBusy, 0);
        return 0;
    }
    GetCursorPos(&saved);
    SetCursorPos(a.x, a.y);
    Sleep(DRAG_STEP_MS);
    mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
    Sleep(DRAG_HOLD_MS);
    for (i = 1; i <= DRAG_STEPS; i++) {
        SetCursorPos(a.x + (b.x - a.x) * i / DRAG_STEPS, a.y + (b.y - a.y) * i / DRAG_STEPS);
        mouse_event(MOUSEEVENTF_MOVE, 0, 0, 0, 0);
        Sleep(DRAG_STEP_MS);
    }
    Sleep(DRAG_HOLD_MS);
    mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
    Sleep(DRAG_STEP_MS);
    SetCursorPos(saved.x, saved.y);
    A11Y_Log("drag (%ld,%ld) -> (%ld,%ld)", a.x, a.y, b.x, b.y);
    InterlockedExchange(&g_dragBusy, 0);
    return 0;
}

/* a11y_drag(fx1, fy1, fx2, fy2) -> true if started. Fractions of the client
   area, 0..1. Returns false while a previous drag is still running. */
static int JEODE_CALL j_a11y_drag(void *L)
{
    lua_State *ls = (lua_State *)L;
    DragJob *job;
    HANDLE th;
    if (InterlockedCompareExchange(&g_dragBusy, 1, 0) != 0) { lua_pushboolean(ls, 0); return 1; }
    job = (DragJob *)malloc(sizeof(DragJob));
    if (!job) { InterlockedExchange(&g_dragBusy, 0); lua_pushboolean(ls, 0); return 1; }
    job->fx1 = lua_tonumber(ls, 1); job->fy1 = lua_tonumber(ls, 2);
    job->fx2 = lua_tonumber(ls, 3); job->fy2 = lua_tonumber(ls, 4);
    th = (HANDLE)_beginthreadex(NULL, 0, DragProc, job, 0, NULL);
    if (!th) { free(job); InterlockedExchange(&g_dragBusy, 0); lua_pushboolean(ls, 0); return 1; }
    CloseHandle(th);
    lua_pushboolean(ls, 1);
    return 1;
}

/* a11y_press_escape() -- a real Escape key press, so Backspace gets the game's
   own Escape handling first. Held long enough for the hotkey poll to see it,
   which then runs the mod's Escape fallback as for a typed Escape. */
static unsigned __stdcall EscapeProc(void *param)
{
    INPUT in[1];
    (void)param;
    memset(in, 0, sizeof(in));
    in[0].type = INPUT_KEYBOARD;
    in[0].ki.wVk = VK_ESCAPE;
    in[0].ki.wScan = (WORD)MapVirtualKeyA(VK_ESCAPE, MAPVK_VK_TO_VSC);
    SendInput(1, in, sizeof(INPUT));
    Sleep(HOTKEY_POLL_MS * 3);
    in[0].ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(1, in, sizeof(INPUT));
    return 0;
}

static int JEODE_CALL j_a11y_press_escape(void *L)
{
    lua_State *ls = (lua_State *)L;
    HANDLE th = (HANDLE)_beginthreadex(NULL, 0, EscapeProc, NULL, 0, NULL);
    if (th) CloseHandle(th);
    lua_pushboolean(ls, th ? 1 : 0);
    return 1;
}

/* ---------------------------------------------------------------------------
   Lua C functions exposed to the game via Jeode's register_global.

   Signature required by Jeode: int (__cdecl *)(void *L). lua_CFunction from
   our lua51 is also __cdecl and takes lua_State*, so the void* is just cast.
   --------------------------------------------------------------------------- */

/* a11y_speak(text [, interrupt]) */
static int JEODE_CALL j_a11y_speak(void *L)
{
    lua_State *ls = (lua_State *)L;
    const char *text = luaL_checkstring(ls, 1);
    int interrupt = lua_toboolean(ls, 2);
    A11Y_Speak(text, interrupt);
    return 0;
}

/* a11y_silence() */
static int JEODE_CALL j_a11y_silence(void *L)
{
    (void)L;
    A11Y_Silence();
    return 0;
}

/* a11y_is_active() -> boolean */
static int JEODE_CALL j_a11y_is_active(void *L)
{
    lua_State *ls = (lua_State *)L;
    lua_pushboolean(ls, A11Y_IsActive());
    return 1;
}

/* a11y_log(text) */
static int JEODE_CALL j_a11y_log(void *L)
{
    lua_State *ls = (lua_State *)L;
    const char *text = luaL_checkstring(ls, 1);
    A11Y_Log("Lua: %s", text);
    return 0;
}

/* a11y_click_fraction(fx, fy) : a left click at (fx,fy) of the game window's
   client area, 0..1 (island taps, C++-drawn tutorial dialogs). Done on its own
   thread with short pauses, like a11y_drag: moving the cursor, pressing,
   releasing and moving it back in one instant raced Windows' input thread,
   and on slower PCs the click landed wherever the real mouse was (a friend's
   Nursery tap in the tutorial never hit). Only fires if the game is
   foreground; skipped while a drag is running. */
#define CLICK_SETTLE_MS 30
#define CLICK_HOLD_MS   50

typedef struct { double fx, fy; } ClickJob;

static unsigned __stdcall ClickProc(void *param)
{
    ClickJob job = *(ClickJob *)param;
    HWND hwnd = GetForegroundWindow();
    DWORD pid = 0;
    POINT pt, saved;
    free(param);

    if (hwnd) GetWindowThreadProcessId(hwnd, &pid);
    if (!hwnd || pid != GetCurrentProcessId() || !client_point(hwnd, job.fx, job.fy, &pt)) {
        InterlockedExchange(&g_dragBusy, 0);
        return 0;
    }
    GetCursorPos(&saved);
    SetCursorPos(pt.x, pt.y);
    Sleep(CLICK_SETTLE_MS);
    mouse_event(MOUSEEVENTF_MOVE, 0, 0, 0, 0);
    Sleep(CLICK_SETTLE_MS);
    mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
    Sleep(CLICK_HOLD_MS);
    mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
    Sleep(CLICK_HOLD_MS);
    SetCursorPos(saved.x, saved.y);
    A11Y_Log("click_fraction (%.2f,%.2f) -> screen (%ld,%ld)", job.fx, job.fy, pt.x, pt.y);
    InterlockedExchange(&g_dragBusy, 0);
    return 0;
}

static int JEODE_CALL j_a11y_click_fraction(void *L)
{
    lua_State *ls = (lua_State *)L;
    ClickJob *job;
    HANDLE th;
    if (InterlockedCompareExchange(&g_dragBusy, 1, 0) != 0) {
        A11Y_Log("click_fraction skipped: a drag or click is still running");
        return 0;
    }
    job = (ClickJob *)malloc(sizeof(ClickJob));
    if (!job) { InterlockedExchange(&g_dragBusy, 0); return 0; }
    job->fx = lua_tonumber(ls, 1);
    job->fy = lua_tonumber(ls, 2);
    th = (HANDLE)_beginthreadex(NULL, 0, ClickProc, job, 0, NULL);
    if (!th) { free(job); InterlockedExchange(&g_dragBusy, 0); return 0; }
    CloseHandle(th);
    return 0;
}

/* ---------------------------------------------------------------------------
   Tutorial step reader  (from Ghidra RE -- see memory tutorial-re).

   FUN_00cfdb70 (RVA 0x8fdb70) returns the tutorial manager for the current
   State (island = WorldContext+0x320). manager+4 = current step index; the
   virtual method at vtable+0xA0 returns the max step count. We resolve the
   getter by prologue signature (fast) or a pattern scan of .text (survives
   minor updates), then call it ON THE GAME THREAD (via queue_lua) so game
   state isn't mid-mutation. All reads are SEH-guarded -> never crash.
   --------------------------------------------------------------------------- */

/* Tutorial manager getter, game 5.5.0 (Ghidra re-analysis 2026-07-21).
   Re-derive on each game update: find the tutorialActive Lua binding, the
   function it calls is this getter. RVA + signature below are 5.5.0-specific. */
#define TUT_GETTER_RVA 0x963170u
/* Bytes at getter+5 (position-independent, no relocations): the
   mov ecx,[eax+0x5C]; mov eax,[ecx+4]; cmp eax,2 sequence. */
static const unsigned char TUT_SIG[] = { 0x8B,0x48,0x5C,0x8B,0x41,0x04,0x83,0xF8,0x02 };

typedef void *(__cdecl *get_tut_mgr_fn)(void);
/* vtable+0xA0 virtual (thiscall, 0 args). __fastcall(ecx=this, edx=dummy) is
   ABI-identical and avoids MSVC's C-mode __thiscall-on-typedef restriction --
   same trick Jeode's call stubs use. */
typedef int(__fastcall *tut_maxstep_fn)(void *ecx, void *edx);
static get_tut_mgr_fn g_getTutMgr = NULL;

static int get_text_range(uintptr_t base, uintptr_t *start, size_t *size)
{
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)base;
    IMAGE_NT_HEADERS *nt;
    IMAGE_SECTION_HEADER *sec;
    int i;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
    nt = (IMAGE_NT_HEADERS *)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return 0;
    sec = IMAGE_FIRST_SECTION(nt);
    for (i = 0; i < nt->FileHeader.NumberOfSections; i++) {
        if (memcmp(sec[i].Name, ".text", 5) == 0) {
            *start = base + sec[i].VirtualAddress;
            *size  = sec[i].Misc.VirtualSize;
            return 1;
        }
    }
    return 0;
}

/* mask: 'x' = must match, '?' = wildcard (relocated / variable bytes). */
static uintptr_t pattern_scan(uintptr_t start, size_t size,
                              const unsigned char *pat, const char *mask, size_t patlen)
{
    size_t i, j;
    if (size < patlen) return 0;
    for (i = 0; i + patlen <= size; i++) {
        const unsigned char *p = (const unsigned char *)(start + i);
        for (j = 0; j < patlen; j++) {
            if (mask[j] == 'x' && p[j] != pat[j]) break;
        }
        if (j == patlen) return start + i;
    }
    return 0;
}

static get_tut_mgr_fn resolve_tut_getter(void)
{
    uintptr_t base, cand, ts = 0, found;
    size_t tsz = 0;
    /* A1 ?? ?? ?? ?? 8B 48 5C 8B 41 04 83 F8 02 75 ?? 6A 00 68 ?? ?? ?? ?? 68 ?? ?? ?? ?? 6A 00 51 E8 */
    static const unsigned char PAT[] = {
        0xA1,0,0,0,0, 0x8B,0x48,0x5C,0x8B,0x41,0x04,0x83,0xF8,0x02,0x75,0,
        0x6A,0x00,0x68,0,0,0,0,0x68,0,0,0,0,0x6A,0x00,0x51,0xE8 };
    static const char MASK[] = "x????xxxxxxxxxx?xxx????x????xxxx";

    if (g_getTutMgr) return g_getTutMgr;
    base = (uintptr_t)GetModuleHandleA(NULL);
    if (!base) return NULL;
    A11Y_Log("resolve_tut_getter: exe base=0x%p", (void *)base);

    cand = base + TUT_GETTER_RVA;
    if (!IsBadReadPtr((void *)cand, 16)) {
        const unsigned char *b = (const unsigned char *)cand;
        A11Y_Log("bytes @ base+0x%x: %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X",
                 (unsigned)TUT_GETTER_RVA, b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13]);
    } else {
        A11Y_Log("bytes @ base+0x%x: NOT READABLE", (unsigned)TUT_GETTER_RVA);
    }

    if (!IsBadReadPtr((void *)(cand + 5), sizeof(TUT_SIG)) &&
        memcmp((void *)(cand + 5), TUT_SIG, sizeof(TUT_SIG)) == 0) {
        g_getTutMgr = (get_tut_mgr_fn)cand;
        A11Y_Log("tutorial getter at RVA 0x%x (verified)", (unsigned)TUT_GETTER_RVA);
        return g_getTutMgr;
    }
    if (get_text_range(base, &ts, &tsz)) {
        A11Y_Log(".text @ 0x%p size 0x%x", (void *)ts, (unsigned)tsz);
        found = pattern_scan(ts, tsz, PAT, MASK, sizeof(PAT));
        if (found) {
            g_getTutMgr = (get_tut_mgr_fn)found;
            A11Y_Log("tutorial getter via pattern at 0x%p (RVA 0x%x)",
                     (void *)found, (unsigned)(found - base));
            return g_getTutMgr;
        }
        A11Y_Log("pattern not found in .text");
    } else {
        A11Y_Log("get_text_range FAILED");
    }
    A11Y_Log("tutorial getter NOT found (game updated?)");
    return NULL;
}

/* Fills *step (0-based) and *maxstep; returns 1 on success. Game-thread only. */
static int read_tutorial_step(int *step, int *maxstep)
{
    get_tut_mgr_fn fn = resolve_tut_getter();
    int ok = 0;
    if (!fn) return 0;
    /* The getter does  mov eax,[global]; mov ecx,[eax+0x5C]; mov eax,[ecx+4].
       Before the tutorial exists (login, loading) [eax+0x5C] is NULL and the
       getter faults inside the exe. __try doesn't save us there: the game's
       crash reporter sees the fault first and kills the process. So walk the
       same two pointers here and only call when both are valid. */
    {
        const unsigned char *code = (const unsigned char *)fn;
        void **global, *g, *sub;
        if (IsBadReadPtr(code, 5) || code[0] != 0xA1) return 0;
        global = *(void ***)(code + 1);
        if (IsBadReadPtr(global, sizeof(void *))) return 0;
        g = *global;
        if (!g || IsBadReadPtr((char *)g + 0x5C, sizeof(void *))) return 0;
        sub = *(void **)((char *)g + 0x5C);
        if (!sub || IsBadReadPtr((char *)sub + 4, sizeof(int))) return 0;
    }
    __try {
        void *mgr = fn();
        if (mgr && !IsBadReadPtr(mgr, 8)) {
            int cur = *(int *)((char *)mgr + 4);
            void **vt = *(void ***)mgr;
            if (!IsBadReadPtr(vt, 0xA4)) {
                tut_maxstep_fn mf = (tut_maxstep_fn)vt[0xA0 / 4];
                int mx = mf(mgr, NULL);
                *step = cur;
                *maxstep = mx;
                ok = 1;
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        ok = 0;
    }
    return ok;
}

/* a11y_tutorial_step() -> (step, max) : returns the 0-based current tutorial
   step index and the max step count to Lua (which adds a human description and
   speaks it). step = -1 means no tutorial active. Runs on the game thread. */
static int JEODE_CALL j_a11y_tutorial_step(void *L)
{
    lua_State *ls = (lua_State *)L;
    int step = -1, mx = 0;
    if (read_tutorial_step(&step, &mx) && mx > 0 && step >= 0 && step < mx) {
        lua_pushinteger(ls, step);
        lua_pushinteger(ls, mx);
    } else {
        lua_pushinteger(ls, -1);
        lua_pushinteger(ls, 0);
    }
    return 2;
}

/* ---------------------------------------------------------------------------
   Tutorial popup text hook.

   The game shows every tutorial speech popup through one member function
   (5.7.2: RVA 0x8ac080, found in Ghidra via the "popup_tutorial" string):
       void __thiscall ShowTutorialPopup(std::string *title, std::string *text,
                                         char flag, int spriteName, int sheetName)
   It writes title/text into the popup's Text components from C++, which the
   Lua "text" property never reflects. So we hook it, copy the two strings,
   and tell init.lua (a11y_onTutorialPopup) to speak them.
   --------------------------------------------------------------------------- */

/* MSVC x86 std::string: 16-byte SSO buffer or heap pointer, then size, capacity. */
typedef struct {
    union { char buf[16]; char *ptr; } u;
    size_t size;
    size_t cap;
} MsvcString;

typedef void(__fastcall *show_tut_popup_fn)(void *ecx, void *edx, MsvcString *title,
                                             MsvcString *text, int flag, int p5, int p6);

static show_tut_popup_fn g_origShowTutPopup = NULL;
static char          g_tutTitle[1024];
static char          g_tutText[2048];
static volatile LONG g_tutSeq = 0;

static void copy_msvc_string(const MsvcString *s, char *out, size_t outsz)
{
    out[0] = '\0';
    __try {
        const char *p;
        size_t n;
        if (!s) return;
        p = (s->cap > 15) ? s->u.ptr : s->u.buf;
        n = s->size;
        if (n >= outsz) n = outsz - 1;
        memcpy(out, p, n);
        out[n] = '\0';
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        out[0] = '\0';
    }
}

static void __fastcall hk_show_tut_popup(void *ecx, void *edx, MsvcString *title,
                                         MsvcString *text, int flag, int p5, int p6)
{
    copy_msvc_string(title, g_tutTitle, sizeof(g_tutTitle));
    copy_msvc_string(text, g_tutText, sizeof(g_tutText));
    InterlockedIncrement(&g_tutSeq);
    A11Y_Log("tutorial popup: title='%s' text='%s'", g_tutTitle, g_tutText);

    g_origShowTutPopup(ecx, edx, title, text, flag, p5, p6);

    if (g_api)
        g_api->queue_lua("if type(a11y_onTutorialPopup)=='function' then a11y_onTutorialPopup() end",
                         "=a11y_tutpopup");
}

/* a11y_tutorial_popup_text() -> title, text, seq  (seq bumps on every popup) */
static int JEODE_CALL j_a11y_tutorial_popup_text(void *L)
{
    lua_State *ls = (lua_State *)L;
    lua_pushstring(ls, g_tutTitle);
    lua_pushstring(ls, g_tutText);
    lua_pushinteger(ls, (lua_Integer)g_tutSeq);
    return 3;
}

static void install_tutorial_popup_hook(void)
{
    /* Bytes right after the SEH prologue; unique in the 5.7.2 exe. The function
       starts 0x2A bytes before them (55 8B EC 6A FF 68 ...). */
    static const unsigned char PAT[] = {
        0x8B,0xF9,0x8B,0x45,0x0C,0x0F,0x57,0xC0,0x8B,0x75,0x08,
        0x8B,0x8F,0xAC,0x00,0x00,0x00,0x89,0x45,0xC8 };
    static const char MASK[] = "xxxxxxxxxxxxxxxxxxxx";
    static const unsigned char PROLOGUE[] = { 0x55,0x8B,0xEC,0x6A,0xFF,0x68 };
    uintptr_t base = (uintptr_t)GetModuleHandleA(NULL), ts = 0, hit, fn;
    size_t tsz = 0;
    MH_STATUS st;

    if (!base || !get_text_range(base, &ts, &tsz)) { A11Y_Log("tut popup hook: no .text"); return; }
    hit = pattern_scan(ts, tsz, PAT, MASK, sizeof(PAT));
    if (!hit) { A11Y_Log("tut popup hook: pattern not found (game updated?)"); return; }
    if (pattern_scan(hit + 1, tsz - (hit + 1 - ts), PAT, MASK, sizeof(PAT))) {
        A11Y_Log("tut popup hook: pattern not unique, refusing to hook"); return;
    }
    fn = hit - 0x2A;
    if (memcmp((void *)fn, PROLOGUE, sizeof(PROLOGUE)) != 0) {
        A11Y_Log("tut popup hook: prologue mismatch at RVA 0x%x", (unsigned)(fn - base)); return;
    }

    st = MH_Initialize();
    if (st != MH_OK && st != MH_ERROR_ALREADY_INITIALIZED) { A11Y_Log("tut popup hook: MH_Initialize %d", st); return; }
    st = MH_CreateHook((LPVOID)fn, (LPVOID)hk_show_tut_popup, (LPVOID *)&g_origShowTutPopup);
    if (st != MH_OK) { A11Y_Log("tut popup hook: MH_CreateHook %d", st); return; }
    st = MH_EnableHook((LPVOID)fn);
    if (st != MH_OK) { A11Y_Log("tut popup hook: MH_EnableHook %d", st); return; }
    A11Y_Log("tut popup hook installed at RVA 0x%x", (unsigned)(fn - base));
}

/* ---------------------------------------------------------------------------
   Grid tile of a world object (a11y_entity_tile).
   Each GameEntity keeps its tile in the variables "pos_x" / "pos_y", read by
   two tiny generated getters: __thiscall int(GameEntity*), which do
   GetInt("pos_x", 0) on the entity's variable table at +0x3C. Lua can't reach
   those variables, so we call the getters. Found without hardcoded addresses:
   locate the 8-byte string literal "pos_x\0\0\0", then the getter that loads
   it (A1 <addr> 0F 57 C0 8B 49 3C); the function starts shortly before.
   --------------------------------------------------------------------------- */
typedef int(__fastcall *pos_getter_fn)(void *ecx, void *edx);
static pos_getter_fn g_posX = NULL, g_posY = NULL;

/* SWIG's Lua userdata block: { swig_type_info *type; int own; void *ptr; }. */
typedef struct { const char *name; } SwigTypeInfoHead;
typedef struct { SwigTypeInfoHead *type; int own; void *ptr; } SwigLuaUserdata;

/* First match of pat after address `after` (0 = from the start), in .text
   (textOnly=1) or in the other readable sections (textOnly=0). */
static uintptr_t find_in_sections(uintptr_t base, const unsigned char *pat, size_t len, int textOnly, uintptr_t after)
{
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    IMAGE_SECTION_HEADER *sec = IMAGE_FIRST_SECTION(nt);
    char mask[32];
    int i;
    if (len >= sizeof(mask)) return 0;
    memset(mask, 'x', len); mask[len] = 0;
    for (i = 0; i < nt->FileHeader.NumberOfSections; i++) {
        int isText = memcmp(sec[i].Name, ".text", 5) == 0;
        uintptr_t hit;
        if (textOnly != isText) continue;
        uintptr_t start = base + sec[i].VirtualAddress, end = start + sec[i].Misc.VirtualSize;
        if (!(sec[i].Characteristics & IMAGE_SCN_MEM_READ)) continue;
        if (after >= end) continue;
        if (after >= start) start = after + 1;
        hit = pattern_scan(start, end - start, pat, mask, len);
        if (hit) return hit;
    }
    return 0;
}

static pos_getter_fn resolve_pos_getter(uintptr_t base, const char *name5)
{
    static const unsigned char PROLOGUE[] = { 0x53, 0x8B, 0xDC, 0x83, 0xEC, 0x08 };
    unsigned char lit[8] = { 0 }, code[11];
    uintptr_t str, hit, fn;
    int tries = 0;
    memcpy(lit, name5, 5);
    code[0] = 0xA1;
    code[5] = 0x0F; code[6] = 0x57; code[7] = 0xC0; code[8] = 0x8B; code[9] = 0x49; code[10] = 0x3C;
    /* The literal may appear more than once: use the copy the getter loads. */
    hit = 0;
    for (str = find_in_sections(base, lit, sizeof(lit), 0, 0); str && tries < 32;
         str = find_in_sections(base, lit, sizeof(lit), 0, str), tries++) {
        memcpy(code + 1, &str, 4);
        hit = find_in_sections(base, code, sizeof(code), 1, 0);
        if (hit) break;
    }
    if (!hit) { A11Y_Log("tile: getter for '%s' not found (%d literal copies)", name5, tries); return NULL; }
    /* The function starts a little before that load: 0x3C bytes in 5.7.2,
       0x3D in 5.7.4. Search back for the prologue right after the 0xCC
       padding between functions, so small compiler changes don't break it. */
    fn = 0;
    {
        uintptr_t k;
        for (k = 0x20; k <= 0x80; k++) {
            uintptr_t at = hit - k;
            if (memcmp((void *)at, PROLOGUE, sizeof(PROLOGUE)) == 0 && *(unsigned char *)(at - 1) == 0xCC) {
                fn = at;
                break;
            }
        }
    }
    if (!fn) {
        A11Y_Log("tile: getter for '%s' prologue not found before RVA 0x%x", name5, (unsigned)(hit - base));
        return NULL;
    }
    A11Y_Log("tile: '%s' getter at RVA 0x%x", name5, (unsigned)(fn - base));
    return (pos_getter_fn)fn;
}

static void resolve_tile_getters(void)
{
    uintptr_t base = (uintptr_t)GetModuleHandleA(NULL);
    if (!base) return;
    g_posX = resolve_pos_getter(base, "pos_x");
    g_posY = resolve_pos_getter(base, "pos_y");
}

/* a11y_entity_tile(entity) -> x, y   (nil if unavailable) */
static int JEODE_CALL j_a11y_entity_tile(void *L)
{
    lua_State *ls = (lua_State *)L;
    static int loggedType = 0;
    SwigLuaUserdata *ud;
    int x = 0, y = 0, ok = 0;
    if (!g_posX || !g_posY || !lua_isuserdata(ls, 1)) return 0;
    ud = (SwigLuaUserdata *)lua_touserdata(ls, 1);
    if (!ud || !ud->ptr) return 0;
    __try {
        if (!loggedType) {
            loggedType = 1;
            A11Y_Log("tile: first entity type '%s'", (ud->type && ud->type->name) ? ud->type->name : "?");
        }
        x = g_posX(ud->ptr, NULL);
        y = g_posY(ud->ptr, NULL);
        ok = 1;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        A11Y_Log("tile: exception reading entity tile");
    }
    if (!ok) return 0;
    lua_pushinteger(ls, (lua_Integer)x);
    lua_pushinteger(ls, (lua_Integer)y);
    return 2;
}

/* ---------------------------------------------------------------------------
   Live tile of the object being moved.
   pos_x / pos_y only change when a move is confirmed. While dragging, the
   tile lives on the WorldContext: game.isSelectedObjectPlaceable reads it as
     mov edx,[eax+0x284] ; mov ebx,[eax+0x280]   (y, x in 5.7.2)
   just before its "isSelectedObjectPlaceable" error-message push. Find that
   push, then the pair of mov reg,[reg+disp32] whose displacements differ by 4.
   --------------------------------------------------------------------------- */
static DWORD g_moveTileX = 0;   /* offsets into WorldContext; 0 = unresolved */

static void resolve_move_tile(void)
{
    static const char NAME[] = "isSelectedObjectPlaceable";
    uintptr_t base = (uintptr_t)GetModuleHandleA(NULL);
    uintptr_t str, push;
    unsigned char code[5];
    unsigned char *p, *start;
    if (!base) return;
    str = find_in_sections(base, (const unsigned char *)NAME, sizeof(NAME), 0, 0);  /* includes the NUL */
    if (!str) { A11Y_Log("movetile: name string not found"); return; }
    code[0] = 0x68; memcpy(code + 1, &str, 4);
    push = find_in_sections(base, code, sizeof(code), 1, 0);
    if (!push) { A11Y_Log("movetile: string push not found"); return; }
    start = (unsigned char *)push - 0x200;
    for (p = start; p + 12 <= (unsigned char *)push; p++) {
        DWORD a, b;
        if (p[0] != 0x8B || (p[1] & 0xC0) != 0x80 || p[6] != 0x8B || (p[7] & 0xC0) != 0x80) continue;
        memcpy(&a, p + 2, 4); memcpy(&b, p + 8, 4);
        if (a == b + 4 && b >= 0x40 && b < 0x4000) {
            g_moveTileX = b;
            A11Y_Log("movetile: x at WorldContext+0x%x, y at +0x%x", (unsigned)b, (unsigned)a);
            return;
        }
    }
    A11Y_Log("movetile: field reads not found");
}

/* a11y_move_tile(worldContext) -> x, y   (nil if unavailable) */
static int JEODE_CALL j_a11y_move_tile(void *L)
{
    lua_State *ls = (lua_State *)L;
    SwigLuaUserdata *ud;
    int x = 0, y = 0, ok = 0;
    if (!g_moveTileX || !lua_isuserdata(ls, 1)) return 0;
    ud = (SwigLuaUserdata *)lua_touserdata(ls, 1);
    if (!ud || !ud->ptr) return 0;
    __try {
        x = *(int *)((char *)ud->ptr + g_moveTileX);
        y = *(int *)((char *)ud->ptr + g_moveTileX + 4);
        ok = 1;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        A11Y_Log("movetile: exception reading WorldContext");
    }
    if (!ok) return 0;
    lua_pushinteger(ls, (lua_Integer)x);
    lua_pushinteger(ls, (lua_Integer)y);
    return 2;
}

/* a11y_set_move_tile(worldContext, x, y) -> true on success.
   Lua writes a tile, asks game.isSelectedObjectPlaceable(), and writes the old
   tile back in the same call, so no frame ever draws the probe position. */
static int JEODE_CALL j_a11y_set_move_tile(void *L)
{
    lua_State *ls = (lua_State *)L;
    SwigLuaUserdata *ud;
    int x, y, ok = 0;
    if (!g_moveTileX || !lua_isuserdata(ls, 1)) return 0;
    ud = (SwigLuaUserdata *)lua_touserdata(ls, 1);
    if (!ud || !ud->ptr) return 0;
    x = (int)lua_tonumber(ls, 2);
    y = (int)lua_tonumber(ls, 3);
    __try {
        *(int *)((char *)ud->ptr + g_moveTileX) = x;
        *(int *)((char *)ud->ptr + g_moveTileX + 4) = y;
        ok = 1;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        A11Y_Log("movetile: exception writing WorldContext");
    }
    lua_pushboolean(ls, ok);
    return 1;
}

/* ---------------------------------------------------------------------------
   Jeode native-mod ABI
   --------------------------------------------------------------------------- */

JEODE_EXPORT int JEODE_CALL jeode_native_init(const struct JeodeNativeAPI *api)
{
    if (!api || api->api_version != JEODE_NATIVE_API_VERSION) {
        /* Nonzero -> Jeode logs the mismatch and unloads us. */
        return 1;
    }
    g_api = api;

    api->log("msm-a11y", "native init");
    api->log("msm-a11y", api->game_version ? api->game_version : "(no game version)");

    /* Load prism.dll from our own mod folder.
       Independent of the Lua state, so it's fine to do it here at load time. */
    if (!InitSpeech()) {
        /* Non-fatal: register the globals anyway so init.lua still binds; the
           a11y_* calls just become no-ops (A11Y_Speak guards on no backend). */
        api->log("msm-a11y", "Prism init FAILED - speech disabled, continuing");
    }

    /* These register into the game's Lua state (queued until it's ready). */
    api->register_global("a11y_speak",     j_a11y_speak);
    api->register_global("a11y_silence",   j_a11y_silence);
    api->register_global("a11y_is_active", j_a11y_is_active);
    api->register_global("a11y_log",       j_a11y_log);
    api->register_global("a11y_click_fraction", j_a11y_click_fraction);
    api->register_global("a11y_drag", j_a11y_drag);
    api->register_global("a11y_press_escape", j_a11y_press_escape);
    api->register_global("a11y_tutorial_step",  j_a11y_tutorial_step);
    api->register_global("a11y_tutorial_popup_text", j_a11y_tutorial_popup_text);
    api->register_global("a11y_entity_tile", j_a11y_entity_tile);
    api->register_global("a11y_move_tile", j_a11y_move_tile);
    api->register_global("a11y_set_move_tile", j_a11y_set_move_tile);
    install_tutorial_popup_hook();
    resolve_tile_getters();
    resolve_move_tile();
    api->log("msm-a11y", "registered a11y_* globals");

    /* Optional: if init.lua can't see the native globals from the mod sandbox
       (see the note in init.lua), uncomment to stitch them into the game _G so
       patched game closures resolve them. Runs on the game Lua thread.
       api->queue_lua(
           "_G.a11y = { speak = a11y_speak, silence = a11y_silence,"
           " is_active = a11y_is_active, log = a11y_log }",
           "=msm_a11y_bridge"); */

    /* Arm the on-demand HUD hotkey (Ctrl+Shift+A). */
    InterlockedExchange(&g_hotkeyRunning, 1);
    g_hotkeyThread = (HANDLE)_beginthreadex(NULL, 0, HotkeyProc, NULL, 0, NULL);
    if (g_hotkeyThread) {
        api->log("msm-a11y", "HUD hotkey armed: Ctrl+Shift+A");
    } else {
        InterlockedExchange(&g_hotkeyRunning, 0);
        api->log("msm-a11y", "failed to start HUD hotkey thread");
    }

    /* Speaks immediately via Prism, no Lua needed - our "we're alive" signal. */
    A11Y_Speak("My Singing Monsters accessibility mod loaded via Jeode. Press control shift A for status.", 0);
    return 0;
}

JEODE_EXPORT void JEODE_CALL jeode_native_shutdown(void)
{
    if (g_api) g_api->log("msm-a11y", "native shutdown");

    if (g_hotkeyThread) {
        InterlockedExchange(&g_hotkeyRunning, 0);
        WaitForSingleObject(g_hotkeyThread, 2000);
        CloseHandle(g_hotkeyThread);
        g_hotkeyThread = NULL;
    }

    ShutdownSpeech();
    g_api = NULL;
}
