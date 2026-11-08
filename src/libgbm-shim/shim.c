#define _GNU_SOURCE
#include <gbm.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>

static void *real;
static FILE *lf;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static const char *REAL_LIB = "/opt/mesa-kopper-retire-42194036783/candidate/usr/lib/libgbm.so.1.0.0";

static void init_real(void) {
    real = dlopen(REAL_LIB, RTLD_NOW | RTLD_LOCAL);
    lf = fopen("/opt/gbm-spike/shim.log", "a");
    if (lf) setvbuf(lf, NULL, _IOLBF, 0);
    if (lf) fprintf(lf, "# shim init pid=%d real=%p err=%s\n", (int)getpid(), real, real ? "ok" : dlerror());
}
static void *sym(const char *name) {
    pthread_once(&once, init_real);
    return real ? dlsym(real, name) : NULL;
}
#define LOG(...) do { pthread_once(&once, init_real); if (lf) { fprintf(lf, "[%d] ", (int)getpid()); fprintf(lf, __VA_ARGS__); fprintf(lf, "\n"); } } while (0)

/* ---- logging helpers ---- */
static void log_bo(const char *who, struct gbm_bo *bo, void *(*get_prop)(void *)) { (void)who; (void)bo; (void)get_prop; }

/* ---- device ---- */
struct gbm_device *gbm_create_device(int fd) {
    typedef struct gbm_device *(*F)(int);
    F f = (F)sym("gbm_create_device");
    struct gbm_device *d = f ? f(fd) : NULL;
    LOG("CALL gbm_create_device(fd=%d) -> %p", fd, (void*)d);
    return d;
}
void gbm_device_destroy(struct gbm_device *d) {
    typedef void (*F)(struct gbm_device*);
    F f = (F)sym("gbm_device_destroy");
    LOG("CALL gbm_device_destroy(%p)", (void*)d);
    if (f) f(d);
}
int gbm_device_get_fd(struct gbm_device *d) {
    typedef int (*F)(struct gbm_device*);
    F f = (F)sym("gbm_device_get_fd");
    int r = f ? f(d) : -1;
    LOG("CALL gbm_device_get_fd(%p) -> %d", (void*)d, r);
    return r;
}
const char *gbm_device_get_backend_name(struct gbm_device *d) {
    typedef const char *(*F)(struct gbm_device*);
    F f = (F)sym("gbm_device_get_backend_name");
    const char *r = f ? f(d) : NULL;
    LOG("CALL gbm_device_get_backend_name(%p) -> %s", (void*)d, r ? r : "(null)");
    return r;
}
int gbm_device_is_format_supported(struct gbm_device *d, uint32_t format, uint32_t flags) {
    typedef int (*F)(struct gbm_device*, uint32_t, uint32_t);
    F f = (F)sym("gbm_device_is_format_supported");
    int r = f ? f(d, format, flags) : 0;
    LOG("CALL gbm_device_is_format_supported(format=0x%x flags=0x%x) -> %d", format, flags, r);
    return r;
}
int gbm_device_get_format_modifier_plane_count(struct gbm_device *d, uint32_t format, uint64_t modifier) {
    typedef int (*F)(struct gbm_device*, uint32_t, uint64_t);
    if (modifier != 0) {
        LOG("CALL gbm_device_get_format_modifier_plane_count(format=0x%x modifier=0x%llx) -> 0 (LINEAR-only shim)", format, (unsigned long long)modifier);
        return 0;
    }
    F f = (F)sym("gbm_device_get_format_modifier_plane_count");
    int r = f ? f(d, format, modifier) : 0;
    LOG("CALL gbm_device_get_format_modifier_plane_count(format=0x%x modifier=0x%llx) -> %d", format, (unsigned long long)modifier, r);
    return r;
}

/* Force every allocation onto DRM_FORMAT_MOD_LINEAR: Chrome otherwise picks an
 * AFBC modifier from the 88 the real Mesa libgbm offers on xring_drm, and
 * zink/MaliBridge cannot import that as a dma-buf (EGL_BAD_ALLOC, 0x3003). */
static struct gbm_bo *create_linear(struct gbm_device *d, uint32_t w, uint32_t h, uint32_t format, uint32_t flags) {
    static const uint64_t lin = 0;
    typedef struct gbm_bo *(*F2)(struct gbm_device*, uint32_t, uint32_t, uint32_t, const uint64_t*, unsigned, uint32_t);
    F2 f2 = (F2)sym("gbm_bo_create_with_modifiers2");
    if (f2) return f2(d, w, h, format, &lin, 1, flags);
    typedef struct gbm_bo *(*F1)(struct gbm_device*, uint32_t, uint32_t, uint32_t, const uint64_t*, unsigned);
    F1 f1 = (F1)sym("gbm_bo_create_with_modifiers");
    if (f1) return f1(d, w, h, format, &lin, 1);
    typedef struct gbm_bo *(*F0)(struct gbm_device*, uint32_t, uint32_t, uint32_t, uint32_t);
    F0 f0 = (F0)sym("gbm_bo_create");
    return f0 ? f0(d, w, h, format, flags) : NULL;
}

/* ---- bo create ---- */
static void log_new_bo(const char *who, struct gbm_bo *bo, uint32_t format, int w, int h) {
    if (!bo) { LOG("CALL %s(format=0x%x %dx%d) -> NULL", who, format, w, h); return; }
    int fd = -1;
    typedef int (*GFD)(struct gbm_bo*);
    GFD gfd = (GFD)sym("gbm_bo_get_fd");
    if (gfd) { fd = gfd(bo); if (fd >= 0) close(fd); }
    LOG("CALL %s(format=0x%x %dx%d) -> bo=%p stride=%u mod=0x%llx planes=%d fd=%d",
        who, format, w, h, (void*)bo, gbm_bo_get_stride(bo), (unsigned long long)gbm_bo_get_modifier(bo), gbm_bo_get_plane_count(bo), fd);
}
struct gbm_bo *gbm_bo_create(struct gbm_device *d, uint32_t w, uint32_t h, uint32_t format, uint32_t flags) {
    struct gbm_bo *bo = create_linear(d, w, h, format, flags);
    log_new_bo("gbm_bo_create[linear]", bo, format, w, h);
    return bo;
}
struct gbm_bo *gbm_bo_create_with_modifiers(struct gbm_device *d, uint32_t w, uint32_t h, uint32_t format, const uint64_t *mods, unsigned count) {
    char mb[512]; int off = 0;
    for (unsigned i = 0; i < count && i < 16 && off < 480; i++) off += snprintf(mb+off, sizeof(mb)-off, "0x%llx,", (unsigned long long)mods[i]);
    struct gbm_bo *bo = create_linear(d, w, h, format, GBM_BO_USE_RENDERING|GBM_BO_USE_SCANOUT);
    log_new_bo("gbm_bo_create_with_modifiers[linear]", bo, format, w, h);
    LOG("    offered_mods[%u]=%s", count, mb);
    return bo;
}
struct gbm_bo *gbm_bo_create_with_modifiers2(struct gbm_device *d, uint32_t w, uint32_t h, uint32_t format, const uint64_t *mods, unsigned count, uint32_t flags) {
    struct gbm_bo *bo = create_linear(d, w, h, format, flags);
    log_new_bo("gbm_bo_create_with_modifiers2[linear]", bo, format, w, h);
    char mb[512]; int off = 0;
    for (unsigned i = 0; i < count && i < 16 && off < 480; i++) off += snprintf(mb+off, sizeof(mb)-off, "0x%llx,", (unsigned long long)mods[i]);
    LOG("    offered_mods[%u]=%s flags=0x%x", count, mb, flags);
    return bo;
}
struct gbm_bo *gbm_bo_import(struct gbm_device *d, uint32_t type, void *buffer, uint32_t flags) {
    typedef struct gbm_bo *(*F)(struct gbm_device*, uint32_t, void*, uint32_t);
    F f = (F)sym("gbm_bo_import");
    struct gbm_bo *bo = f ? f(d, type, buffer, flags) : NULL;
    LOG("CALL gbm_bo_import(type=0x%x buf=%p flags=0x%x) -> %p", type, buffer, flags, (void*)bo);
    if (bo) LOG("    imported: format=0x%x %ux%u stride=%u mod=0x%llx", gbm_bo_get_format(bo), gbm_bo_get_width(bo), gbm_bo_get_height(bo), gbm_bo_get_stride(bo), (unsigned long long)gbm_bo_get_modifier(bo));
    return bo;
}
void gbm_bo_destroy(struct gbm_bo *bo) {
    typedef void (*F)(struct gbm_bo*);
    F f = (F)sym("gbm_bo_destroy");
    LOG("CALL gbm_bo_destroy(%p)", (void*)bo);
    if (f) f(bo);
}
struct gbm_device *gbm_bo_get_device(struct gbm_bo *bo) {
    typedef struct gbm_device *(*F)(struct gbm_bo*);
    F f = (F)sym("gbm_bo_get_device");
    struct gbm_device *r = f ? f(bo) : NULL;
    LOG("CALL gbm_bo_get_device(%p) -> %p", (void*)bo, (void*)r);
    return r;
}
uint32_t gbm_bo_get_width(struct gbm_bo *bo) { typedef uint32_t (*F)(struct gbm_bo*); F f=(F)sym("gbm_bo_get_width"); uint32_t r=f?f(bo):0; LOG("CALL gbm_bo_get_width(%p) -> %u",(void*)bo,r); return r; }
uint32_t gbm_bo_get_height(struct gbm_bo *bo) { typedef uint32_t (*F)(struct gbm_bo*); F f=(F)sym("gbm_bo_get_height"); uint32_t r=f?f(bo):0; LOG("CALL gbm_bo_get_height(%p) -> %u",(void*)bo,r); return r; }
uint32_t gbm_bo_get_format(struct gbm_bo *bo) { typedef uint32_t (*F)(struct gbm_bo*); F f=(F)sym("gbm_bo_get_format"); uint32_t r=f?f(bo):0; LOG("CALL gbm_bo_get_format(%p) -> 0x%x",(void*)bo,r); return r; }
uint32_t gbm_bo_get_stride(struct gbm_bo *bo) { typedef uint32_t (*F)(struct gbm_bo*); F f=(F)sym("gbm_bo_get_stride"); uint32_t r=f?f(bo):0; LOG("CALL gbm_bo_get_stride(%p) -> %u",(void*)bo,r); return r; }
uint32_t gbm_bo_get_offset(struct gbm_bo *bo, int plane) { typedef uint32_t (*F)(struct gbm_bo*, int); F f=(F)sym("gbm_bo_get_offset"); uint32_t r=f?f(bo,plane):0; LOG("CALL gbm_bo_get_offset(%p,%d) -> %u",(void*)bo,plane,r); return r; }
uint64_t gbm_bo_get_modifier(struct gbm_bo *bo) { typedef uint64_t (*F)(struct gbm_bo*); F f=(F)sym("gbm_bo_get_modifier"); uint64_t r=f?f(bo):0; LOG("CALL gbm_bo_get_modifier(%p) -> 0x%llx",(void*)bo,(unsigned long long)r); return r; }
int gbm_bo_get_plane_count(struct gbm_bo *bo) { typedef int (*F)(struct gbm_bo*); F f=(F)sym("gbm_bo_get_plane_count"); int r=f?f(bo):0; LOG("CALL gbm_bo_get_plane_count(%p) -> %d",(void*)bo,r); return r; }
uint32_t gbm_bo_get_stride_for_plane(struct gbm_bo *bo, int plane) { typedef uint32_t (*F)(struct gbm_bo*, int); F f=(F)sym("gbm_bo_get_stride_for_plane"); uint32_t r=f?f(bo,plane):0; LOG("CALL gbm_bo_get_stride_for_plane(%p,%d) -> %u",(void*)bo,plane,r); return r; }
int gbm_bo_get_fd(struct gbm_bo *bo) { typedef int (*F)(struct gbm_bo*); F f=(F)sym("gbm_bo_get_fd"); int r=f?f(bo):-1; LOG("CALL gbm_bo_get_fd(%p) -> %d",(void*)bo,r); return r; }
int gbm_bo_get_fd_for_plane(struct gbm_bo *bo, int plane) { typedef int (*F)(struct gbm_bo*, int); F f=(F)sym("gbm_bo_get_fd_for_plane"); int r=f?f(bo,plane):-1; LOG("CALL gbm_bo_get_fd_for_plane(%p,%d) -> %d",(void*)bo,plane,r); return r; }
union gbm_bo_handle gbm_bo_get_handle(struct gbm_bo *bo) { typedef union gbm_bo_handle (*F)(struct gbm_bo*); F f=(F)sym("gbm_bo_get_handle"); union gbm_bo_handle r; if (f) r=f(bo); else r.u64=0; LOG("CALL gbm_bo_get_handle(%p) -> 0x%llx",(void*)bo,(unsigned long long)r.u64); return r; }
union gbm_bo_handle gbm_bo_get_handle_for_plane(struct gbm_bo *bo, int plane) { typedef union gbm_bo_handle (*F)(struct gbm_bo*, int); F f=(F)sym("gbm_bo_get_handle_for_plane"); union gbm_bo_handle r; if (f) r=f(bo,plane); else r.u64=0; LOG("CALL gbm_bo_get_handle_for_plane(%p,%d) -> 0x%llx",(void*)bo,plane,(unsigned long long)r.u64); return r; }
void *gbm_bo_map(struct gbm_bo *bo, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t flags, uint32_t *stride, void **map_data) {
    typedef void *(*F)(struct gbm_bo*, uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t*,void**);
    F f=(F)sym("gbm_bo_map"); void *r=f?f(bo,x,y,w,h,flags,stride,map_data):NULL;
    LOG("CALL gbm_bo_map(%p,%u,%u,%u,%u,0x%x) -> %p",(void*)bo,x,y,w,h,flags,r); return r;
}
void gbm_bo_unmap(struct gbm_bo *bo, void *map_data) { typedef void (*F)(struct gbm_bo*, void*); F f=(F)sym("gbm_bo_unmap"); LOG("CALL gbm_bo_unmap(%p,%p)",(void*)bo,map_data); if(f)f(bo,map_data); }
int gbm_bo_write(struct gbm_bo *bo, const void *buf, size_t count) { typedef int (*F)(struct gbm_bo*, const void*, size_t); F f=(F)sym("gbm_bo_write"); int r=f?f(bo,buf,count):-1; LOG("CALL gbm_bo_write(%p,%zu) -> %d",(void*)bo,count,r); return r; }
void *gbm_bo_get_user_data(struct gbm_bo *bo) { typedef void *(*F)(struct gbm_bo*); F f=(F)sym("gbm_bo_get_user_data"); void *r=f?f(bo):NULL; LOG("CALL gbm_bo_get_user_data(%p) -> %p",(void*)bo,r); return r; }
void gbm_bo_set_user_data(struct gbm_bo *bo, void *data, void (*destroy)(struct gbm_bo*, void*)) { typedef void (*F)(struct gbm_bo*, void*, void*); F f=(F)sym("gbm_bo_set_user_data"); LOG("CALL gbm_bo_set_user_data(%p,%p)",(void*)bo,data); if(f)f(bo,data,(void*)destroy); }
uint32_t gbm_bo_get_bpp(struct gbm_bo *bo) { typedef uint32_t (*F)(struct gbm_bo*); F f=(F)sym("gbm_bo_get_bpp"); uint32_t r=f?f(bo):0; LOG("CALL gbm_bo_get_bpp(%p) -> %u",(void*)bo,r); return r; }

/* surface: Chrome's Wayland path does not use these, but the EGL/GBM
 * initialization path in the out-of-process GPU process may resolve them. */
struct gbm_surface *gbm_surface_create(struct gbm_device *d, uint32_t w, uint32_t h, uint32_t format, uint32_t flags) {
    typedef struct gbm_surface *(*F)(struct gbm_device*, uint32_t, uint32_t, uint32_t, uint32_t);
    F f=(F)sym("gbm_surface_create"); struct gbm_surface *r=f?f(d,w,h,format,flags):NULL;
    LOG("CALL gbm_surface_create(%ux%u fmt=0x%x flags=0x%x) -> %p",w,h,format,flags,(void*)r); return r;
}
struct gbm_surface *gbm_surface_create_with_modifiers(struct gbm_device *d, uint32_t w, uint32_t h, uint32_t format, const uint64_t *mods, unsigned count) {
    typedef struct gbm_surface *(*F)(struct gbm_device*, uint32_t, uint32_t, uint32_t, const uint64_t*, unsigned);
    F f=(F)sym("gbm_surface_create_with_modifiers"); struct gbm_surface *r=f?f(d,w,h,format,mods,count):NULL;
    LOG("CALL gbm_surface_create_with_modifiers(%ux%u fmt=0x%x n=%u) -> %p",w,h,format,count,(void*)r); return r;
}
struct gbm_surface *gbm_surface_create_with_modifiers2(struct gbm_device *d, uint32_t w, uint32_t h, uint32_t format, const uint64_t *mods, unsigned count, uint32_t flags) {
    typedef struct gbm_surface *(*F)(struct gbm_device*, uint32_t, uint32_t, uint32_t, const uint64_t*, unsigned, uint32_t);
    F f=(F)sym("gbm_surface_create_with_modifiers2"); struct gbm_surface *r=f?f(d,w,h,format,mods,count,flags):NULL;
    LOG("CALL gbm_surface_create_with_modifiers2(%ux%u fmt=0x%x n=%u flags=0x%x) -> %p",w,h,format,count,flags,(void*)r); return r;
}
void gbm_surface_destroy(struct gbm_surface *s) { typedef void (*F)(struct gbm_surface*); F f=(F)sym("gbm_surface_destroy"); LOG("CALL gbm_surface_destroy(%p)",(void*)s); if(f)f(s); }
int gbm_surface_has_free_buffers(struct gbm_surface *s) { typedef int (*F)(struct gbm_surface*); F f=(F)sym("gbm_surface_has_free_buffers"); int r=f?f(s):0; LOG("CALL gbm_surface_has_free_buffers(%p) -> %d",(void*)s,r); return r; }
struct gbm_bo *gbm_surface_lock_front_buffer(struct gbm_surface *s) { typedef struct gbm_bo *(*F)(struct gbm_surface*); F f=(F)sym("gbm_surface_lock_front_buffer"); struct gbm_bo *r=f?f(s):NULL; LOG("CALL gbm_surface_lock_front_buffer(%p) -> %p",(void*)s,(void*)r); return r; }
void gbm_surface_release_buffer(struct gbm_surface *s, struct gbm_bo *bo) { typedef void (*F)(struct gbm_surface*, struct gbm_bo*); F f=(F)sym("gbm_surface_release_buffer"); LOG("CALL gbm_surface_release_buffer(%p,%p)",(void*)s,(void*)bo); if(f)f(s,bo); }
char *gbm_format_get_name(uint32_t format, struct gbm_format_name_desc *desc) { typedef char *(*F)(uint32_t, struct gbm_format_name_desc*); F f=(F)sym("gbm_format_get_name"); char *r=f?f(format,desc):NULL; LOG("CALL gbm_format_get_name(0x%x) -> %s",format,r?r:"(null)"); return r; }

__attribute__((destructor)) static void shim_fini(void) {
    LOG("# shim fini pid=%d", (int)getpid());
}
