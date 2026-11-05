#include "accessibility_bridge.h"
#include "lua51/lua.h"
#include "lua51/lauxlib.h"

#include <windows.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "prism_api.h"

/* -----------------------------------------------------------------------
   Prism (screen-reader abstraction), loaded at runtime from the mod folder.
   One prism.dll talks to NVDA, JAWS, System Access, Narrator (UIA) and SAPI
   itself: no per-reader client DLLs.
   ----------------------------------------------------------------------- */

static HMODULE       g_hPrism    = NULL;
static PrismContext *g_ctx       = NULL;
static PrismBackend *g_backend   = NULL;
static int           g_useOutput = 1;   /* output() = speech + braille; some backends lack it */
static DWORD         g_lastRedetect = 0;

static pfn_prism_config_init           p_config_init;
static pfn_prism_init                  p_init;
static pfn_prism_shutdown              p_shutdown;
static pfn_prism_registry_count        p_registry_count;
static pfn_prism_registry_acquire_best p_acquire_best;
static pfn_prism_backend_name          p_backend_name;
static pfn_prism_backend_initialize    p_backend_initialize;
static pfn_prism_backend_output        p_backend_output;
static pfn_prism_backend_speak         p_backend_speak;
static pfn_prism_backend_stop          p_backend_stop;
static pfn_prism_error_string          p_error_string;

/* -----------------------------------------------------------------------
   Last-spoken cache for repeat (Ctrl+0)
   ----------------------------------------------------------------------- */

#define LAST_SPOKEN_BUF_SIZE 1024
static char g_lastSpoken[LAST_SPOKEN_BUF_SIZE] = "";

/* -----------------------------------------------------------------------
   Debug logging (OutputDebugString + accessibility.log file)
   ----------------------------------------------------------------------- */

static FILE *g_logFile = NULL;

static void EnsureLogFile(void)
{
    if (g_logFile) return;
    g_logFile = fopen("accessibility.log", "a");
    if (g_logFile) {
        fprintf(g_logFile, "\n--- Session start ---\n");
        fflush(g_logFile);
    }
}

void A11Y_Log(const char *fmt, ...)
{
    char buf[1024];
    va_list ap;
    SYSTEMTIME st;

    strcpy(buf, "[MSM-A11Y] ");

    va_start(ap, fmt);
    vsnprintf(buf + 11, sizeof(buf) - 11, fmt, ap);
    va_end(ap);

    OutputDebugStringA(buf);

    /* Also write to log file */
    EnsureLogFile();
    if (g_logFile) {
        GetLocalTime(&st);
        fprintf(g_logFile, "[%02d:%02d:%02d.%03d] %s\n",
                st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
                buf + 11);  /* Skip the [MSM-A11Y] prefix, timestamp is enough */
        fflush(g_logFile);
    }
}

/* -----------------------------------------------------------------------
   Speech init / shutdown
   ----------------------------------------------------------------------- */

/* Resolve the directory that THIS dll was loaded from, so prism.dll is
   loaded from our own folder rather than the game's. */
static int GetOwnDir(wchar_t *out, size_t n)
{
    HMODULE hSelf = NULL;
    wchar_t path[MAX_PATH];
    wchar_t *slash;

    if (!GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
            GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            (LPCWSTR)&GetOwnDir, &hSelf)) {
        return 0;
    }
    if (!GetModuleFileNameW(hSelf, path, MAX_PATH)) return 0;
    slash = wcsrchr(path, L'\\');
    if (!slash) return 0;
    *slash = L'\0';
    wcsncpy(out, path, n);
    out[n - 1] = L'\0';
    return 1;
}

static int Bind(void **target, const char *name)
{
    *target = (void *)GetProcAddress(g_hPrism, name);
    if (!*target) A11Y_Log("prism.dll is missing %s", name);
    return *target != NULL;
}

/* Pick the best available reader. Prism polls availability in the
   background, so asking again finds a screen reader started after the game. */
static int Redetect(void)
{
    PrismBackend *best;
    PrismError err;
    const char *name;

    if (!g_ctx) return 0;
    g_lastRedetect = GetTickCount();
    best = p_acquire_best(g_ctx);
    if (!best) {
        g_backend = NULL;
        return 0;
    }
    if (best == g_backend) return 1;
    /* acquire_best hands back a shared backend that may already be set up;
       ALREADY_INITIALIZED is not a failure. */
    err = p_backend_initialize(best);
    if (err != PRISM_OK && err != PRISM_ERROR_ALREADY_INITIALIZED) {
        A11Y_Log("Prism backend initialize failed: %s",
                 p_error_string ? p_error_string(err) : "error");
        return 0;
    }
    g_backend = best;
    g_useOutput = 1;
    name = p_backend_name(best);
    A11Y_Log("Prism speaking through: %s", name ? name : "unknown");
    return 1;
}

int InitSpeech(void)
{
    wchar_t ownDir[MAX_PATH];
    wchar_t full[MAX_PATH];
    PrismConfig cfg;
    int ok = 1;

    if (!GetOwnDir(ownDir, MAX_PATH)) {
        A11Y_Log("Could not resolve own module directory");
        return 0;
    }
    _snwprintf(full, MAX_PATH, L"%s\\prism.dll", ownDir);
    full[MAX_PATH - 1] = L'\0';

    /* Altered search path: Prism's own folder is searched for anything it loads. */
    g_hPrism = LoadLibraryExW(full, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!g_hPrism) {
        A11Y_Log("Failed to load prism.dll (error %lu)", GetLastError());
        return 0;
    }

    ok &= Bind((void **)&p_config_init,        "prism_config_init");
    ok &= Bind((void **)&p_init,               "prism_init");
    ok &= Bind((void **)&p_shutdown,           "prism_shutdown");
    ok &= Bind((void **)&p_acquire_best,       "prism_registry_acquire_best");
    ok &= Bind((void **)&p_backend_name,       "prism_backend_name");
    ok &= Bind((void **)&p_backend_initialize, "prism_backend_initialize");
    ok &= Bind((void **)&p_backend_output,     "prism_backend_output");
    ok &= Bind((void **)&p_backend_speak,      "prism_backend_speak");
    ok &= Bind((void **)&p_backend_stop,       "prism_backend_stop");
    /* Optional, diagnostics only. */
    p_registry_count = (pfn_prism_registry_count)GetProcAddress(g_hPrism, "prism_registry_count");
    p_error_string   = (pfn_prism_error_string)GetProcAddress(g_hPrism, "prism_error_string");
    if (!ok) {
        FreeLibrary(g_hPrism);
        g_hPrism = NULL;
        return 0;
    }

    cfg = p_config_init();
    cfg.version = PRISM_CONFIG_VERSION;
    g_ctx = p_init(&cfg);
    if (!g_ctx) {
        A11Y_Log("prism_init failed");
        FreeLibrary(g_hPrism);
        g_hPrism = NULL;
        return 0;
    }
    if (p_registry_count)
        A11Y_Log("Prism ready, %u backends registered", (unsigned)p_registry_count(g_ctx));

    if (!Redetect()) A11Y_Log("No screen reader found yet; will keep looking");
    return 1;
}

void ShutdownSpeech(void)
{
    /* The backend belongs to the context; shutting the context releases it. */
    g_backend = NULL;
    if (g_ctx && p_shutdown) p_shutdown(g_ctx);
    g_ctx = NULL;
    if (g_hPrism) {
        FreeLibrary(g_hPrism);
        g_hPrism = NULL;
        A11Y_Log("Prism unloaded");
    }

    if (g_logFile) {
        fprintf(g_logFile, "--- Session end ---\n");
        fclose(g_logFile);
        g_logFile = NULL;
    }
}

/* -----------------------------------------------------------------------
   Public API
   ----------------------------------------------------------------------- */

void A11Y_Speak(const char *text, int interrupt)
{
    if (!text || !*text) return;

    /* Cache the text for repeat */
    strncpy(g_lastSpoken, text, LAST_SPOKEN_BUF_SIZE - 1);
    g_lastSpoken[LAST_SPOKEN_BUF_SIZE - 1] = '\0';

    /* No reader yet (started after the game, or restarted): look again, at
       most every 3 seconds. */
    if (!g_backend && g_ctx && GetTickCount() - g_lastRedetect > 3000) Redetect();
    if (!g_backend) {
        A11Y_Log("Speak (no screen reader): %s", text);
        return;
    }

    if (g_useOutput) {
        if (p_backend_output(g_backend, text, interrupt ? true : false) == PRISM_OK) {
            A11Y_Log("Speak: %s", text);
            return;
        }
        g_useOutput = 0;
    }
    if (p_backend_speak(g_backend, text, interrupt ? true : false) != PRISM_OK) {
        /* The reader may have closed: drop it so the next call redetects. */
        g_backend = NULL;
        A11Y_Log("Speak failed: %s", text);
        return;
    }
    A11Y_Log("Speak: %s", text);
}

const char *A11Y_GetLastSpoken(void)
{
    return g_lastSpoken;
}

void A11Y_Silence(void)
{
    if (g_backend && p_backend_stop) (void)p_backend_stop(g_backend);
}

int A11Y_IsActive(void)
{
    return g_backend != NULL;
}

/* -----------------------------------------------------------------------
   Lua C functions
   ----------------------------------------------------------------------- */

/* a11y_speak(text [, interrupt]) */
static int l_a11y_speak(lua_State *L)
{
    const char *text = luaL_checkstring(L, 1);
    int interrupt = lua_toboolean(L, 2);
    A11Y_Speak(text, interrupt);
    return 0;
}

/* a11y_silence() */
static int l_a11y_silence(lua_State *L)
{
    (void)L;
    A11Y_Silence();
    return 0;
}

/* a11y_is_active() -> boolean */
static int l_a11y_is_active(lua_State *L)
{
    lua_pushboolean(L, A11Y_IsActive());
    return 1;
}

/* a11y_log(text) */
static int l_a11y_log(lua_State *L)
{
    const char *text = luaL_checkstring(L, 1);
    A11Y_Log("Lua: %s", text);
    return 0;
}

/* -----------------------------------------------------------------------
   Registration
   ----------------------------------------------------------------------- */

void RegisterAccessibilityFunctions(lua_State *L)
{
    A11Y_Log("Registering accessibility Lua functions...");

    lua_pushcfunction(L, l_a11y_speak);
    lua_setglobal(L, "a11y_speak");

    lua_pushcfunction(L, l_a11y_silence);
    lua_setglobal(L, "a11y_silence");

    lua_pushcfunction(L, l_a11y_is_active);
    lua_setglobal(L, "a11y_is_active");

    lua_pushcfunction(L, l_a11y_log);
    lua_setglobal(L, "a11y_log");

    A11Y_Log("Lua functions registered: a11y_speak, a11y_silence, a11y_is_active, a11y_log");

    /* Speak startup announcement */
    A11Y_Speak("My Singing Monsters accessibility mod loaded", 0);
}
