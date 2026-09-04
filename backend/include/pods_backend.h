/* DEPRECATED as of 1 October 2026. iPhone FFI embedding. Do not review, extend, or append.
 * See ios/DEPRECATED.md. */

#pragma once
#include <stddef.h>
#include <stdint.h>

#if defined(__GNUC__) || defined(__clang__)
#define PODS_IPHONE_DEPRECATED \
  __attribute__((deprecated("The iPhone FFI embedding is deprecated as of 1 October 2026. See ios/DEPRECATED.md.")))
#else
#define PODS_IPHONE_DEPRECATED
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PodsHandle PodsHandle;

PODS_IPHONE_DEPRECATED int pods_backend_prepare(const char *live_path, const char *seed_path);
PODS_IPHONE_DEPRECATED PodsHandle *pods_backend_open(const char *db_path);
PODS_IPHONE_DEPRECATED int pods_backend_configure(PodsHandle *handle, const char *json);
PODS_IPHONE_DEPRECATED void pods_backend_close(PodsHandle *handle);
PODS_IPHONE_DEPRECATED uint8_t *pods_backend_handle(
    PodsHandle *handle,
    const char *method,
    const char *target,
    const char *headers,
    const uint8_t *body,
    size_t body_len,
    int *out_status,
    size_t *out_len
);
PODS_IPHONE_DEPRECATED void pods_backend_free(uint8_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif
