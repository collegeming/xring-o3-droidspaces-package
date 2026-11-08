#!/usr/bin/env python3
"""Apply/check the isolated 47ec18e server-side AFBC export-metadata candidate.

Port of ASEbrahim/MaliBridge e7ee6be, "server: make a dma-buf import of a
compressed export ask for the export's size" (PR #71), to the 47ec18e server
tree this kit builds. Upstream also carries host-side unit tests and a document
(host/*, tests/dbmeta_unit.c, docs/afbc-dmabuf-import.md); they are not part of
the server binary and are not ported here.

server/server_dmabuf_meta.c and server/server_dmabuf_meta.h are added verbatim,
and server/server_emu_layer.c remembers an export's shape, modifier and plane
layout so a dma-buf import that passes that layout back is made at the export's
modifier instead of LINEAR. The root CMakeLists.txt globs server/*.c, so the
added source compiles without a build-file change.

The upstream patch is kept unmodified for reference as
patches/malibridge/afbc/0001-afbc-export-metadata.patch; it is based on 3cd7a2b
and does not apply to 47ec18e, which is why the port lives here.
"""
import argparse
import hashlib
import subprocess
from pathlib import Path

REVISION = "47ec18eaa9d9f83c359d56ba412a17d61ba59a66"
BLOBS = {
    "server/server_emu_layer.c": "45c808f2ad0910cd6db335e874c7248f6f924b3d",
}
NEW_FILES = (
    "server/server_dmabuf_meta.c",
    "server/server_dmabuf_meta.h",
)


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def canonical(data):
    return data.replace(b"\r\n", b"\n")


def blob_hash(data):
    data = canonical(data)
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


META_H = r'''/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 ASEbrahim and MaliBridge contributors
 *
 * MaliBridge - server side (bionic on the device, glibc for host tests).
 *
 * The dma-buf exports this server made, as far as an importer can name them: a small register of
 * shape (format, extent, mips, layers), the modifier the driver chose, and the one plane layout
 * vkGetImageSubresourceLayout gave for it. A dma-buf import that passes such a layout back is that
 * export's consumer, whatever modifier it names (server_emu_layer.c).
 */
#ifndef VKB_SERVER_DMABUF_META_H
#define VKB_SERVER_DMABUF_META_H

#include <vulkan/vulkan.h>

typedef struct {
    VkFormat format;
    uint32_t width, height, mips, layers;
    uint64_t modifier;           /* the driver's DRM format modifier (0: DRM_FORMAT_MOD_LINEAR) */
    VkSubresourceLayout layout;  /* the exporter's vkGetImageSubresourceLayout answer */
} vkb_meta_shape;

/* Remembers an export's shape and layout (the register keeps the newest few dozen). */
void vkb_meta_note(const vkb_meta_shape *s);

/* The modifier of an export whose shape and plane layout `s` carries, 0 where there is none.
 * `s->modifier` is ignored: an importer that names the LINEAR modifier while passing a compressed
 * export's layout is the case this answers. A zero size in `s->layout` matches any size. */
uint64_t vkb_meta_match(const vkb_meta_shape *s);

/* Forgets everything (the unit test). */
void vkb_meta_reset(void);

#endif
'''

META_C = r'''/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 ASEbrahim and MaliBridge contributors
 *
 * MaliBridge - server side (bionic on the device, glibc for host tests).
 *
 * Why this register exists (Mali-G2-Ultra-NX MC16, driver r56, 2026-11-08): Zink exported a
 * 1668x2173 BGRA8 dma-buf at DRM-modifier tiling. The driver chose the AFBC modifier
 * 0x0820000000000101 and gave it 3,760,128 bytes (1728x2176 at 8bpp, the 16x16 superblocks'
 * payload), and vkGetImageSubresourceLayout answered offset 0, rowPitch 27,648 (108 superblocks
 * x 256 bytes), size 3,760,128. The same process then imported the dma-buf into an image that
 * named the LINEAR modifier (0) with that rowPitch: Mali's explicit-layout path read the pitch
 * as a pixel row's and asked 27,648 x 2172 + 6,672 = 60,058,128 bytes of a 3,760,128-byte
 * dma-buf, and vkAllocateMemory failed with VK_ERROR_INVALID_EXTERNAL_HANDLE (-1000072003);
 * Zink gave up on the surface and Gecko fell back to wl_shm. An explicit image at the AFBC
 * modifier with the full layout is refused outright (VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_
 * PLANE_LAYOUT_EXT); at that modifier with the rowPitch alone it is laid out exactly as the
 * export (3,760,128 bytes, same layout).
 *
 * No API the server answers can tell an importer the modifier when its caller names LINEAR, so
 * the layout is what identifies the export. The register holds the few dozen newest exports:
 * a layout that matches one is that export's, and the image can be made at the export's modifier
 * without the explicit plane layout (server_emu_layer.c, import_modifier_rescue).
 */
#include "server_dmabuf_meta.h"

#include <pthread.h>
#include <string.h>

#define META_SHAPES 64

static struct {
    pthread_mutex_t lock;
    vkb_meta_shape s[META_SHAPES];
    unsigned next;
} meta = {.lock = PTHREAD_MUTEX_INITIALIZER};

void vkb_meta_note(const vkb_meta_shape *s)
{
    if (!s || !s->width || !s->height || !s->layout.rowPitch) return;
    pthread_mutex_lock(&meta.lock);
    meta.s[meta.next++ % META_SHAPES] = *s;
    pthread_mutex_unlock(&meta.lock);
}

uint64_t vkb_meta_match(const vkb_meta_shape *s)
{
    uint64_t mod = 0;
    if (!s || !s->width || !s->height || !s->layout.rowPitch) return 0;
    pthread_mutex_lock(&meta.lock);
    /* newest first: a later export of the same shape is the one an importer has seen */
    for (unsigned i = 0; i < META_SHAPES; i++) {
        const vkb_meta_shape *e = &meta.s[(meta.next + META_SHAPES - 1 - i) % META_SHAPES];
        if (!e->width) continue;
        if (e->format != s->format || e->width != s->width || e->height != s->height || e->mips != s->mips ||
            e->layers != s->layers)
            continue;
        if (e->layout.offset != s->layout.offset || e->layout.rowPitch != s->layout.rowPitch) continue;
        if (s->layout.size && e->layout.size != s->layout.size) continue;
        if (!e->modifier) continue; /* a LINEAR export: the importer's LINEAR is the truth */
        mod = e->modifier;
        break;
    }
    pthread_mutex_unlock(&meta.lock);
    return mod;
}

void vkb_meta_reset(void)
{
    pthread_mutex_lock(&meta.lock);
    memset(meta.s, 0, sizeof(meta.s));
    meta.next = 0;
    pthread_mutex_unlock(&meta.lock);
}
'''

# server_emu_layer.c, before emu_CreateImage: the shape of an import that names an
# explicit modifier, and the note an export's image leaves for the importers after it.
HELPERS = r'''/* The shape and one-plane layout of a dma-buf import that names an explicit DRM modifier. */
static int import_meta_shape(const VkImageCreateInfo *ci, vkb_meta_shape *q)
{
    if (ci->tiling != VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT || ci->imageType != VK_IMAGE_TYPE_2D || ci->mipLevels != 1 ||
        ci->arrayLayers != 1 || ci->samples != VK_SAMPLE_COUNT_1_BIT)
        return 0;
    int dmabuf = 0, found = 0;
    for (const VkBaseInStructure *b = ci->pNext; b; b = b->pNext) {
        if (b->sType == VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO)
            dmabuf |= (((const VkExternalMemoryImageCreateInfo *)b)->handleTypes & VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT) != 0;
        if (b->sType == VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT) {
            const VkImageDrmFormatModifierExplicitCreateInfoEXT *x = (const void *)b;
            if (x->drmFormatModifierPlaneCount != 1 || !x->pPlaneLayouts) return 0;
            *q = (vkb_meta_shape){ci->format, ci->extent.width, ci->extent.height, ci->mipLevels, ci->arrayLayers,
                                  x->drmFormatModifier, x->pPlaneLayouts[0]};
            found = 1;
        }
    }
    return dmabuf && found;
}

/* Remembers a dma-buf export's shape, chosen modifier and plane layout (server_dmabuf_meta.c). */
static void export_meta_note(VkDevice device, VkImage image, const VkImageCreateInfo *ci)
{
    if (ci->tiling != VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT) return;
    const vkb_dispatch *real = vkb_emu_real();
    VkImageDrmFormatModifierPropertiesEXT mp = {VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT};
    if (!real->vkGetImageDrmFormatModifierPropertiesEXT ||
        real->vkGetImageDrmFormatModifierPropertiesEXT(device, image, &mp) != VK_SUCCESS || !mp.drmFormatModifier)
        return;
    VkImageSubresource sub = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0};
    VkSubresourceLayout l = {0};
    real->vkGetImageSubresourceLayout(device, image, &sub, &l);
    vkb_meta_shape s = {ci->format, ci->extent.width, ci->extent.height, ci->mipLevels, ci->arrayLayers, mp.drmFormatModifier, l};
    vkb_meta_note(&s);
}

'''

# server_emu_layer.c, after the lm_import line: the import made at the export's modifier.
IMPORT = r'''    /* A dma-buf import that passes back a layout an export of this server reported, while naming
     * the LINEAR modifier (or an explicit layout the driver's path inflates): the export is
     * compressed (AFBC), and Mali reads its superblock row pitch as a pixel row's. 1668x2173 BGRA8
     * asked 27,648 x 2172 + 6,672 = 60,058,128 bytes of a 3,760,128-byte dma-buf and failed with
     * VK_ERROR_INVALID_EXTERNAL_HANDLE (Zink then lost the surface; Gecko fell back to wl_shm).
     * Made at the export's modifier alone, the driver lays the image out as the exporter's and
     * the layout it answers is the one the app passed (server_dmabuf_meta.c). */
    VkImageDrmFormatModifierListCreateInfoEXT meta_list = {
        VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT, NULL, 1, NULL};
    uint64_t meta_mod = 0;
    VkBaseOutStructure *meta_expl = NULL;
    vkb_meta_shape meta_q;
    if ((e->flags & VKB_EMU_DMABUF_EXPORT) && !linear_mod && import_meta_shape(ci, &meta_q) &&
        (meta_mod = vkb_meta_match(&meta_q)) != 0 &&
        (meta_expl = vkb_emu_chain_take(ci, VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT))) {
        meta_list.pNext = ci->pNext;
        meta_list.pDrmFormatModifiers = &meta_mod;
        ci->pNext = (const void *)&meta_list;
        lm_import = 0; /* not a linear image: the LINEAR-the-driver-lays-out fallback does not apply */
        static int told;
        if (__atomic_fetch_add(&told, 1, __ATOMIC_RELAXED) < 8)
            VKB_INFO("dma-buf import image (format %d %ux%u): its layout (offset %llu, row pitch %llu, size %llu) is the "
                     "dma-buf export's; made at modifier 0x%llx without the explicit plane layout",
                     ci->format, ci->extent.width, ci->extent.height, (unsigned long long)meta_q.layout.offset,
                     (unsigned long long)meta_q.layout.rowPitch, (unsigned long long)meta_q.layout.size,
                     (unsigned long long)meta_mod);
    } else {
        meta_mod = 0;
    }
'''

# server_emu_layer.c, after the first driver_create_image call: the app's own request again.
RETRY = r'''    if (r != VK_SUCCESS && meta_mod) {
        /* What the app asked again, and the retries it has always had. */
        ci->pNext = (const void *)meta_expl;
        meta_mod = 0;
        r = driver_create_image(device, ci, pAllocator, pImage);
    }
'''

HEADER_ANCHOR = b'#include "server_emu.h"\n#include "vkb_emu_formats.h"\n'
HEADER_NEW = b'#include "server_emu.h"\n#include "server_dmabuf_meta.h"\n#include "vkb_emu_formats.h"\n'
CREATE_ANCHOR = b'static VKAPI_ATTR VkResult VKAPI_CALL emu_CreateImage(VkDevice device, const VkImageCreateInfo *pCreateInfo,\n'
LM_ANCHOR = b'    if (lm_import && linear_mod_refused(e->dev, ci)) linear_mod = linear_import_plain(ci, VK_SUCCESS);\n'
CREATE_CALL_R = b'    VkResult r = driver_create_image(device, ci, pAllocator, pImage);\n'
CREATE_CALL_IF = b'    if (r != VK_SUCCESS && (lm_candidate || lm_import) && !linear_mod) {\n'
CREATE_CALL_ANCHOR = CREATE_CALL_R + CREATE_CALL_IF
NOTE_ANCHOR = (
    b'                VKB_INFO("dma-buf image %llx (pid %d): format %d %ux%u tiling %d usage 0x%x flags 0x%x", '
    b'(unsigned long long)(uintptr_t)*pImage,\n'
    b'                         t && t->proc ? t->proc->pid : 0, ci->format, ci->extent.width, ci->extent.height, '
    b'ci->tiling, ci->usage, ci->flags);\n'
    b'                break;\n'
)
NOTE = b'                export_meta_note(device, *pImage, ci);\n'


def replace_once(data, old, new, what):
    if data.count(old) != 1:
        raise SystemExit("%s: anchor missing or duplicated" % what)
    return data.replace(old, new)


def apply_layer(data):
    data = replace_once(data, HEADER_ANCHOR, HEADER_NEW, "server_emu_layer.c include")
    data = replace_once(data, CREATE_ANCHOR, HELPERS.encode() + CREATE_ANCHOR, "server_emu_layer.c helpers")
    data = replace_once(data, LM_ANCHOR, IMPORT.encode() + LM_ANCHOR, "server_emu_layer.c import")
    data = replace_once(data, CREATE_CALL_ANCHOR, CREATE_CALL_R + RETRY.encode() + CREATE_CALL_IF,
                        "server_emu_layer.c retry")
    note = NOTE_ANCHOR.replace(b"                break;\n", NOTE + b"                break;\n")
    data = replace_once(data, NOTE_ANCHOR, note, "server_emu_layer.c export note")
    return data


APPLY = {
    "server/server_emu_layer.c": apply_layer,
}
NEW_CONTENT = {
    "server/server_dmabuf_meta.h": META_H,
    "server/server_dmabuf_meta.c": META_C,
}


def candidate(data, name):
    newline = b"\r\n" if b"\r\n" in data else b"\n"
    data = canonical(data)
    data = APPLY[name](data)
    return data.replace(b"\n", newline)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source", type=Path)
    ap.add_argument("--check", action="store_true", help="Validate pristine baseline without writing")
    ap.add_argument("--verify-candidate", action="store_true", help="Validate exactly the expected candidate without writing")
    args = ap.parse_args()
    if args.check and args.verify_candidate:
        ap.error("Select at most one check mode")
    root = args.source.resolve()
    if git(root, "rev-parse", "HEAD") != REVISION:
        raise SystemExit("Refusing source revision other than " + REVISION)
    for name, expected in BLOBS.items():
        recorded = git(root, "rev-parse", "HEAD:" + name)
        if recorded != expected:
            raise SystemExit("Unexpected committed blob: " + name)
        data = (root / name).read_bytes()
        if args.verify_candidate:
            pristine = subprocess.check_output(["git", "-C", str(root), "show", "HEAD:" + name])
            if canonical(data) != canonical(candidate(pristine, name)):
                raise SystemExit("Candidate content mismatch: " + name)
        elif blob_hash(data) != expected:
            raise SystemExit("Working-tree blob differs from baseline: " + name)
        print(name, "git-blob=" + recorded, "sha256=" + hashlib.sha256(data).hexdigest())
    for name in NEW_FILES:
        path = root / name
        expected = NEW_CONTENT[name].encode()
        if args.verify_candidate:
            if not path.is_file():
                raise SystemExit("Candidate is missing the new file: " + name)
            if canonical(path.read_bytes()) != expected:
                raise SystemExit("Candidate content mismatch: " + name)
            print(name, "sha256=" + hashlib.sha256(expected).hexdigest())
        elif path.exists():
            raise SystemExit("Baseline already holds the new file: " + name)
    changes = sorted(git(root, "diff", "--name-only", "HEAD").splitlines())
    if args.check:
        if changes:
            raise SystemExit("Unexpected tracked changes: " + repr(changes))
    elif args.verify_candidate:
        if "server/server_emu_layer.c" not in changes:
            raise SystemExit("Candidate does not change server/server_emu_layer.c")
        untracked = sorted(git(root, "ls-files", "--others", "--exclude-standard").splitlines())
        if untracked != sorted(NEW_FILES):
            raise SystemExit("Unexpected untracked files: " + repr(untracked))
    else:
        for name in NEW_FILES:
            (root / name).write_bytes(NEW_CONTENT[name].encode())
        for name in BLOBS:
            path = root / name
            path.write_bytes(candidate(path.read_bytes(), name))
        print("Applied server dma-buf export metadata candidate: a compressed export's dma-buf import is made at the export's modifier")
        return
    print("Verified", "candidate" if args.verify_candidate else "pristine baseline")


if __name__ == "__main__":
    main()
