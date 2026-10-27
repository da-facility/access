#include <stddef.h>
#include <stdint.h>

int32_t access_share_start(const char *dir);
void access_share_frame(const uint8_t *y, size_t y_stride, const uint8_t *uv,
                        size_t uv_stride, size_t width, size_t height);
void access_share_stop(void);
