/*
 * libdrmfake.so - LD_PRELOAD shim that presents the xring primary node
 * (/dev/dri/card0) as a DRM device that also owns a render node, so that
 * WebKitGTK's drmMainDevice() (drmGetDevices2 + DRM_NODE_RENDER bit test)
 * reports a non-null DRMDevice. Everything else is forwarded to libdrm.
 *
 * Test-only. Never installed into the container's library path.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xf86drm.h>

#define FAKE_PRIMARY "/dev/dri/card0"
#define FAKE_RENDER  "/dev/dri/card0"

typedef int  (*drm_get_devices2_fn)(uint32_t, drmDevicePtr[], int);
typedef int  (*drm_get_devices_fn)(drmDevicePtr[], int);
typedef void (*drm_free_devices_fn)(drmDevicePtr[], int);

static drm_get_devices2_fn real_get_devices2;
static drm_get_devices_fn  real_get_devices;
static drm_free_devices_fn real_free_devices;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static FILE *lf;

static pthread_mutex_t reg_lock = PTHREAD_MUTEX_INITIALIZER;
static drmDevicePtr reg[64];
static int reg_n;

static void shim_init(void)
{
    void *h = dlopen("libdrm.so.2", RTLD_NOW | RTLD_LOCAL);
    if (h) {
        real_get_devices2 = (drm_get_devices2_fn)dlsym(h, "drmGetDevices2");
        real_get_devices  = (drm_get_devices_fn)dlsym(h, "drmGetDevices");
        real_free_devices = (drm_free_devices_fn)dlsym(h, "drmFreeDevices");
    }
    const char *path = getenv("LIBDRM_SHIM_LOG");
    if (!path || !*path)
        path = "/tmp/libdrm-shim.log";
    lf = fopen(path, "a");
    if (lf)
        setvbuf(lf, NULL, _IOLBF, 0);
    if (lf)
        fprintf(lf, "# libdrmfake init pid=%d real=%p get2=%p\n",
                (int)getpid(), h, (void *)real_get_devices2);
}

static void logmsg(const char *fmt, ...)
{
    pthread_once(&once, shim_init);
    if (!lf)
        return;
    va_list ap;
    va_start(ap, fmt);
    fprintf(lf, "[%d] ", (int)getpid());
    vfprintf(lf, fmt, ap);
    fputc('\n', lf);
    va_end(ap);
}

static drmDevicePtr fake_device(void)
{
    drmDevicePtr d = calloc(1, sizeof(*d));
    if (!d)
        return NULL;
    char **nodes = calloc(DRM_NODE_MAX, sizeof(char *));
    if (!nodes) {
        free(d);
        return NULL;
    }
    nodes[DRM_NODE_PRIMARY] = strdup(FAKE_PRIMARY);
    nodes[DRM_NODE_RENDER]  = strdup(FAKE_RENDER);
    if (!nodes[DRM_NODE_PRIMARY] || !nodes[DRM_NODE_RENDER]) {
        free(nodes[DRM_NODE_PRIMARY]);
        free(nodes[DRM_NODE_RENDER]);
        free(nodes);
        free(d);
        return NULL;
    }
    d->nodes = nodes;
    d->available_nodes = (1 << DRM_NODE_PRIMARY) | (1 << DRM_NODE_RENDER);
    d->bustype = DRM_BUS_PLATFORM;

    /* libdrm's drmDevicesEqual() memcmp()s businfo by bustype; Mesa EGL calls
     * it from _eglDeviceRefreshList(), so these must never be NULL. */
    drmPlatformBusInfoPtr bus = calloc(1, sizeof(*bus));
    if (bus) {
        snprintf(bus->fullname, sizeof(bus->fullname), "%s", "platform:xring-dpu");
        d->businfo.platform = bus;
    }
    drmPlatformDeviceInfoPtr dinfo = calloc(1, sizeof(*dinfo));
    if (dinfo) {
        dinfo->compatible = calloc(2, sizeof(char *));
        if (dinfo->compatible)
            dinfo->compatible[0] = strdup("xring,dpu-kms");
        d->deviceinfo.platform = dinfo;
    }
    return d;
}

static void register_ours(drmDevicePtr d)
{
    pthread_mutex_lock(&reg_lock);
    if (reg_n < (int)(sizeof(reg) / sizeof(reg[0])))
        reg[reg_n++] = d;
    pthread_mutex_unlock(&reg_lock);
}

static int take_ours(drmDevicePtr d)
{
    int found = 0;
    pthread_mutex_lock(&reg_lock);
    for (int i = 0; i < reg_n; i++) {
        if (reg[i] == d) {
            reg[i] = reg[--reg_n];
            found = 1;
            break;
        }
    }
    pthread_mutex_unlock(&reg_lock);
    return found;
}

static void free_fake(drmDevicePtr d)
{
    if (!d)
        return;
    if (d->nodes) {
        for (int i = 0; i < DRM_NODE_MAX; i++)
            free(d->nodes[i]);
        free(d->nodes);
    }
    free(d->businfo.platform);
    if (d->deviceinfo.platform) {
        if (d->deviceinfo.platform->compatible) {
            for (char **c = d->deviceinfo.platform->compatible; *c; c++)
                free(*c);
            free(d->deviceinfo.platform->compatible);
        }
        free(d->deviceinfo.platform);
    }
    free(d);
}

int drmGetDevices2(uint32_t flags, drmDevicePtr devices[], int max_devices)
{
    pthread_once(&once, shim_init);
    (void)flags;
    if (!devices || max_devices < 1) {
        logmsg("drmGetDevices2(count-only) -> 1");
        return 1;
    }
    drmDevicePtr d = fake_device();
    if (!d)
        return -ENOMEM;
    devices[0] = d;
    register_ours(d);
    logmsg("drmGetDevices2 -> 1 fake {primary=%s render=%s available=0x%x}",
           FAKE_PRIMARY, FAKE_RENDER, d->available_nodes);
    return 1;
}

int drmGetDevices(drmDevicePtr devices[], int max_devices)
{
    pthread_once(&once, shim_init);
    if (!devices || max_devices < 1)
        return 1;
    drmDevicePtr d = fake_device();
    if (!d)
        return -ENOMEM;
    devices[0] = d;
    register_ours(d);
    logmsg("drmGetDevices -> 1 fake");
    return 1;
}

void drmFreeDevices(drmDevicePtr devices[], int count)
{
    pthread_once(&once, shim_init);
    if (!devices)
        return;
    drmDevicePtr others[64];
    int n = 0;
    for (int i = 0; i < count; i++) {
        drmDevicePtr d = devices[i];
        if (d && take_ours(d))
            free_fake(d);
        else if (n < (int)(sizeof(others) / sizeof(others[0])))
            others[n++] = d;
    }
    if (n && real_free_devices)
        real_free_devices(others, n);
}
