#ifndef MSM_PRISM_API_H
#define MSM_PRISM_API_H

/* The part of Prism's C API this mod uses, transcribed from upstream
   include/prism.h v0.18.3 (https://github.com/ethindp/prism, MPL-2.0).

   Copied rather than included so prism.dll is loaded at runtime from the mod
   folder: a statically imported DLL would be searched for next to the game's
   exe, not in mods\msm-a11y\.

   PrismConfig must match upstream exactly: prism_config_init returns it by
   value, which on x86 means a hidden return pointer sized from this struct. */

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

typedef struct PrismContext  PrismContext;
typedef struct PrismBackend  PrismBackend;
typedef struct PrismRegistry PrismRegistry;
typedef uint64_t             PrismBackendId;

/* Upstream declaration order; these are the values the DLL returns. */
typedef int PrismError;
enum {
    PRISM_OK = 0,
    PRISM_ERROR_NOT_INITIALIZED,
    PRISM_ERROR_INVALID_PARAM,
    PRISM_ERROR_NOT_IMPLEMENTED,
    PRISM_ERROR_NO_VOICES,
    PRISM_ERROR_VOICE_NOT_FOUND,
    PRISM_ERROR_SPEAK_FAILURE,
    PRISM_ERROR_MEMORY_FAILURE,
    PRISM_ERROR_RANGE_OUT_OF_BOUNDS,
    PRISM_ERROR_INTERNAL,
    PRISM_ERROR_NOT_SPEAKING,
    PRISM_ERROR_NOT_PAUSED,
    PRISM_ERROR_ALREADY_PAUSED,
    PRISM_ERROR_INVALID_UTF8,
    PRISM_ERROR_INVALID_OPERATION,
    PRISM_ERROR_ALREADY_INITIALIZED,
    PRISM_ERROR_BACKEND_NOT_AVAILABLE,
    PRISM_ERROR_UNKNOWN
};

typedef void (__cdecl *PrismAvailabilityCallback)(void *userdata, PrismBackendId backend,
                                                  const char *name, bool available);
typedef void (__cdecl *PrismAvailabilityBaselineCallback)(void *userdata);

typedef struct {
    uint8_t                           version;
    PrismRegistry                    *registry;
    PrismAvailabilityCallback         availability_callback;
    void                             *availability_userdata;
    uint32_t                          availability_poll_interval_ms;
    uint32_t                          availability_debounce_samples;
    uint32_t                          availability_backoff_max_ms;
    bool                              availability_auto_power_manage;
    PrismAvailabilityBaselineCallback availability_baseline_callback;
} PrismConfig;

#define PRISM_CONFIG_VERSION 4

typedef PrismConfig   (__cdecl *pfn_prism_config_init)(void);
typedef PrismContext *(__cdecl *pfn_prism_init)(PrismConfig *cfg);
typedef void          (__cdecl *pfn_prism_shutdown)(PrismContext *ctx);
typedef size_t        (__cdecl *pfn_prism_registry_count)(PrismContext *ctx);
typedef PrismBackend *(__cdecl *pfn_prism_registry_acquire_best)(PrismContext *ctx);
typedef const char   *(__cdecl *pfn_prism_backend_name)(PrismBackend *backend);
typedef PrismError    (__cdecl *pfn_prism_backend_initialize)(PrismBackend *backend);
typedef PrismError    (__cdecl *pfn_prism_backend_output)(PrismBackend *backend, const char *text, bool interrupt);
typedef PrismError    (__cdecl *pfn_prism_backend_speak)(PrismBackend *backend, const char *text, bool interrupt);
typedef PrismError    (__cdecl *pfn_prism_backend_stop)(PrismBackend *backend);
typedef const char   *(__cdecl *pfn_prism_error_string)(PrismError err);

#endif
