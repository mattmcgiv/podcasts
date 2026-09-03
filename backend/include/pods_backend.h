#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PodsHandle PodsHandle;

int pods_backend_prepare(const char *live_path, const char *seed_path);
PodsHandle *pods_backend_open(const char *db_path);
int pods_backend_configure(PodsHandle *handle, const char *json);
void pods_backend_close(PodsHandle *handle);
uint8_t *pods_backend_handle(
    PodsHandle *handle,
    const char *method,
    const char *target,
    const char *headers,
    const uint8_t *body,
    size_t body_len,
    int *out_status,
    size_t *out_len
);
void pods_backend_free(uint8_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif
