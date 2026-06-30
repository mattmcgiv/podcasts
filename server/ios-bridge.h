#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PodsIosRuntime PodsIosRuntime;

PodsIosRuntime *pods_ios_start(
    const char *database_path,
    const char *bind_addr,
    const char *podcastindex_key,
    const char *podcastindex_secret,
    const char *podcastindex_base
);

void pods_ios_stop(PodsIosRuntime *handle);

#ifdef __cplusplus
}
#endif
