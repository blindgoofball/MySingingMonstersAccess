#ifndef ACCESSIBILITY_BRIDGE_H
#define ACCESSIBILITY_BRIDGE_H

#include "lua51/lua.h"

/* Load prism.dll from this DLL's folder and pick the best screen reader.
   Returns 1 on success, 0 on failure. */
int InitSpeech(void);

/* Shut down Prism and free the library. */
void ShutdownSpeech(void);

/* Register accessibility Lua globals on the given lua_State:
     a11y_speak(text [, interrupt])
     a11y_silence()
     a11y_is_active()
     a11y_log(text)
   Also speaks the startup announcement. */
void RegisterAccessibilityFunctions(lua_State *L);

/* Speak text through the active screen reader.
   If interrupt is non-zero, cancel any current speech first.
   text is UTF-8. */
void A11Y_Speak(const char *text, int interrupt);

/* Silence current speech. */
void A11Y_Silence(void);

/* Returns 1 if a screen reader is active, 0 otherwise. */
int A11Y_IsActive(void);

/* Log a debug message prefixed with [MSM-A11Y]. */
void A11Y_Log(const char *fmt, ...);

/* Returns the last text passed to A11Y_Speak, or "" if nothing yet.
   The returned pointer is valid until the next A11Y_Speak call. */
const char *A11Y_GetLastSpoken(void);

#endif /* ACCESSIBILITY_BRIDGE_H */
