#!/usr/bin/env python3
"""Apply/check the 47ec18e server-side null-allocation bind guard.

Builds on malibridge-mem-budget-patch.py, which also edits common/gen/vkb_gen_server.c:
the pre-state may be pristine (--check) or the memory-budget candidate (apply,
--verify-candidate). Only common/gen/vkb_gen_server.c changes.

Why: when the memory budget refuses vkAllocateMemory the reply carries no allocation, but a
client that ignores the error can still call vkBindBufferMemory / vkBindImageMemory with the
handle it got back (WebKit's animated page did). The generated server dispatch passed that
VK_NULL_HANDLE straight to the vendor driver, which dereferenced it inside libGLES_mali.so and
killed the bridge process with SIGSEGV; niri then saw VK_ERROR_DEVICE_LOST. The handlers below
now refuse a bind whose buffer/image or memory is VK_NULL_HANDLE - and a bind2 whose count does
not match the decoded infos - before the driver is called, answering VK_ERROR_OUT_OF_DEVICE_MEMORY
(what the client's failed allocation already reported) and logging one VKB_WARN per handler.

The client ABI and the wire protocol are unchanged: the reply is the VkResult the handler has
always encoded. server_memory.c, server_instance.c, server_main.c and vkb_server.h keep the
change the memory budget patch made.
"""
import argparse
import hashlib
import subprocess
from pathlib import Path

REVISION = "47ec18eaa9d9f83c359d56ba412a17d61ba59a66"
TARGET = "common/gen/vkb_gen_server.c"
# The files the memory budget patch changes; HEAD must hold these blobs, and the candidate's
# tracked changes are exactly this set (the bind guard edits one of them).
CHAIN = {
    "server/server_memory.c": "cb8578f8610436f5501d2d2d8836431be685f7c8",
    "server/server_instance.c": "823c9c08a4a9ff58c7a6c777c400d3464e16b18c",
    "server/server_main.c": "a9d2359a19c64e556c52b77015ed490ebbd8f31c",
    "server/vkb_server.h": "9a8971817daff04f09602ca6d0a5f6fc82c3b9a6",
    "common/gen/vkb_gen_server.c": "ea6923f2617e10136bf2c84bbbde0993e441a6cc",
}
# Canonical (LF) sha256 of TARGET after malibridge-mem-budget-patch.py; the bind guard only
# applies to that pre-state, and this pins it.
MEM_BUDGET_SHA256 = "8173e4f4d8e6cb51e6104855ba8e4e28176b3be9013df51006f3d08044ecf7bf"


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def canonical(data):
    return data.replace(b"\r\n", b"\n")


def restore_newlines(data, original):
    return data.replace(b"\n", b"\r\n") if b"\r\n" in original else data


# The memory budget patch's two edits to common/gen/vkb_gen_server.c, kept here so --check can
# validate the pristine baseline and --verify-candidate can name the exact candidate. Keep in
# step with patches/malibridge/malibridge-mem-budget-patch.py.
MEM_BUDGET = [
    (
        b"#include \"../vkb_server_iface.h\"\n#include <string.h>",
        b"#include \"../vkb_server_iface.h\"\n#include <string.h>\n\n"
        b"/* server_memory.c: the memory budget's check before a big image is created (the allocation\n"
        b" * that binds it is checked with the client's other allocations). */\n"
        b"extern int vkb_mem_image_budget_current(const VkImageCreateInfo *ci);",
    ),
    (
        b"    if (d->err) { vkb_srv_bad_message(c); return; }\n"
        b"    if (!c->dt->vkCreateImage) { vkb_srv_missing(c, \"vkCreateImage\"); return; }\n"
        b"    VkResult r_ = c->dt->vkCreateImage(device, pCreateInfo, NULL, pImage);",
        b"    if (d->err) { vkb_srv_bad_message(c); return; }\n"
        b"    if (!c->dt->vkCreateImage) { vkb_srv_missing(c, \"vkCreateImage\"); return; }\n"
        b"    if (pCreateInfo && vkb_mem_image_budget_current(pCreateInfo) != 0) {\n"
        b"        VkResult budget_r_ = VK_ERROR_OUT_OF_DEVICE_MEMORY;\n"
        b"        VkImage budget_none_ = VK_NULL_HANDLE;\n"
        b"        vkb_enc_bytes(e, &budget_r_, sizeof(budget_r_));\n"
        b"        vkb_enc_u8(e, pImage != NULL);\n"
        b"        if (pImage) vkb_enc_raw(e, &budget_none_, sizeof(budget_none_));\n"
        b"        return;\n"
        b"    }\n"
        b"    VkResult r_ = c->dt->vkCreateImage(device, pCreateInfo, NULL, pImage);",
    ),
]

LOG_INCLUDE = (
    b"#include <string.h>\n",
    b"#include <string.h>\n"
    b"#include \"vkb_log.h\"\n",
)

BIND_BUFFER = (
    b"    if (d->err) { vkb_srv_bad_message(c); return; }\n"
    b"    if (!c->dt->vkBindBufferMemory) { vkb_srv_missing(c, \"vkBindBufferMemory\"); return; }\n"
    b"    VkResult r_ = c->dt->vkBindBufferMemory(device, buffer, memory, memoryOffset);\n"
    b"    vkb_enc_bytes(e, &r_, sizeof(r_));\n"
    b"}\n",
    b"    if (d->err) { vkb_srv_bad_message(c); return; }\n"
    b"    if (!c->dt->vkBindBufferMemory) { vkb_srv_missing(c, \"vkBindBufferMemory\"); return; }\n"
    b"    if (!buffer || memory == VK_NULL_HANDLE) {\n"
    b"        /* The allocation was refused (the memory budget) and the client bound the handle it got\n"
    b"         * back anyway: the driver would dereference a null VkDeviceMemory and crash. */\n"
    b"        VKB_ONCE(VKB_LOG_WARN, \"vkBindBufferMemory: buffer 0x%llx, memory 0x%llx is VK_NULL_HANDLE (the allocation was \"\n"
    b"                 \"refused, probably by the memory budget); the driver is not called, VK_ERROR_OUT_OF_DEVICE_MEMORY\",\n"
    b"                 (unsigned long long)(uintptr_t)buffer, (unsigned long long)(uintptr_t)memory);\n"
    b"        VkResult guard_r_ = VK_ERROR_OUT_OF_DEVICE_MEMORY;\n"
    b"        vkb_enc_bytes(e, &guard_r_, sizeof(guard_r_));\n"
    b"        return;\n"
    b"    }\n"
    b"    VkResult r_ = c->dt->vkBindBufferMemory(device, buffer, memory, memoryOffset);\n"
    b"    vkb_enc_bytes(e, &r_, sizeof(r_));\n"
    b"}\n",
)

BIND_BUFFER2 = (
    b"    uint32_t bindInfoCount;\n"
    b"    vkb_dec_bytes(d, &bindInfoCount, sizeof(bindInfoCount));\n"
    b"    const VkBindBufferMemoryInfo *pBindInfos;\n"
    b"    if (vkb_dec_u8(d)) {\n"
    b"        uint32_t n_ = vkb_dec_u32(d);\n"
    b"        VkBindBufferMemoryInfo *a_ = (VkBindBufferMemoryInfo *)vkb_dec_alloc(d, (size_t)n_ * sizeof(VkBindBufferMemoryInfo));\n"
    b"        for (uint32_t i_ = 0; a_ && i_ < n_; i_++) vkb_dec_VkBindBufferMemoryInfo(d, &a_[i_]);\n"
    b"        pBindInfos = a_;\n"
    b"    } else {\n"
    b"        pBindInfos = NULL;\n"
    b"    }\n"
    b"    if (d->err) { vkb_srv_bad_message(c); return; }\n"
    b"    if (!c->dt->vkBindBufferMemory2) { vkb_srv_missing(c, \"vkBindBufferMemory2\"); return; }\n"
    b"    VkResult r_ = c->dt->vkBindBufferMemory2(device, bindInfoCount, pBindInfos);\n",
    b"    uint32_t bindInfoCount;\n"
    b"    vkb_dec_bytes(d, &bindInfoCount, sizeof(bindInfoCount));\n"
    b"    const VkBindBufferMemoryInfo *pBindInfos;\n"
    b"    uint32_t guard_decoded_ = 0;\n"
    b"    if (vkb_dec_u8(d)) {\n"
    b"        uint32_t n_ = vkb_dec_u32(d);\n"
    b"        VkBindBufferMemoryInfo *a_ = (VkBindBufferMemoryInfo *)vkb_dec_alloc(d, (size_t)n_ * sizeof(VkBindBufferMemoryInfo));\n"
    b"        for (uint32_t i_ = 0; a_ && i_ < n_; i_++) vkb_dec_VkBindBufferMemoryInfo(d, &a_[i_]);\n"
    b"        pBindInfos = a_;\n"
    b"        guard_decoded_ = n_;\n"
    b"    } else {\n"
    b"        pBindInfos = NULL;\n"
    b"    }\n"
    b"    if (d->err) { vkb_srv_bad_message(c); return; }\n"
    b"    if (!c->dt->vkBindBufferMemory2) { vkb_srv_missing(c, \"vkBindBufferMemory2\"); return; }\n"
    b"    if (bindInfoCount > guard_decoded_) {\n"
    b"        /* A count the decoder did not fill: reading the array for the driver would be out of\n"
    b"         * bounds in this process first. */\n"
    b"        VKB_ONCE(VKB_LOG_WARN, \"vkBindBufferMemory2: %u bind infos but %u decoded; the driver is not called, \"\n"
    b"                 \"VK_ERROR_OUT_OF_DEVICE_MEMORY\", (unsigned)bindInfoCount, (unsigned)guard_decoded_);\n"
    b"        VkResult guard_r_ = VK_ERROR_OUT_OF_DEVICE_MEMORY;\n"
    b"        vkb_enc_bytes(e, &guard_r_, sizeof(guard_r_));\n"
    b"        return;\n"
    b"    }\n"
    b"    for (uint32_t i_ = 0; i_ < bindInfoCount; i_++) {\n"
    b"        /* Any refused allocation makes the whole call fail before the driver sees a null handle. */\n"
    b"        if (!pBindInfos[i_].buffer || pBindInfos[i_].memory == VK_NULL_HANDLE) {\n"
    b"            VKB_ONCE(VKB_LOG_WARN, \"vkBindBufferMemory2: bind info %u names a null buffer 0x%llx or memory 0x%llx (the \"\n"
    b"                     \"allocation was refused, probably by the memory budget); the driver is not called, \"\n"
    b"                     \"VK_ERROR_OUT_OF_DEVICE_MEMORY\", (unsigned)i_,\n"
    b"                     (unsigned long long)(uintptr_t)pBindInfos[i_].buffer,\n"
    b"                     (unsigned long long)(uintptr_t)pBindInfos[i_].memory);\n"
    b"            VkResult guard_r_ = VK_ERROR_OUT_OF_DEVICE_MEMORY;\n"
    b"            vkb_enc_bytes(e, &guard_r_, sizeof(guard_r_));\n"
    b"            return;\n"
    b"        }\n"
    b"    }\n"
    b"    VkResult r_ = c->dt->vkBindBufferMemory2(device, bindInfoCount, pBindInfos);\n",
)

BIND_IMAGE = (
    b"    if (d->err) { vkb_srv_bad_message(c); return; }\n"
    b"    if (!c->dt->vkBindImageMemory) { vkb_srv_missing(c, \"vkBindImageMemory\"); return; }\n"
    b"    VkResult r_ = c->dt->vkBindImageMemory(device, image, memory, memoryOffset);\n"
    b"    vkb_enc_bytes(e, &r_, sizeof(r_));\n"
    b"}\n",
    b"    if (d->err) { vkb_srv_bad_message(c); return; }\n"
    b"    if (!c->dt->vkBindImageMemory) { vkb_srv_missing(c, \"vkBindImageMemory\"); return; }\n"
    b"    if (!image || memory == VK_NULL_HANDLE) {\n"
    b"        /* Same refused-allocation bind as vkBindBufferMemory, on an image. */\n"
    b"        VKB_ONCE(VKB_LOG_WARN, \"vkBindImageMemory: image 0x%llx, memory 0x%llx is VK_NULL_HANDLE (the allocation was \"\n"
    b"                 \"refused, probably by the memory budget); the driver is not called, VK_ERROR_OUT_OF_DEVICE_MEMORY\",\n"
    b"                 (unsigned long long)(uintptr_t)image, (unsigned long long)(uintptr_t)memory);\n"
    b"        VkResult guard_r_ = VK_ERROR_OUT_OF_DEVICE_MEMORY;\n"
    b"        vkb_enc_bytes(e, &guard_r_, sizeof(guard_r_));\n"
    b"        return;\n"
    b"    }\n"
    b"    VkResult r_ = c->dt->vkBindImageMemory(device, image, memory, memoryOffset);\n"
    b"    vkb_enc_bytes(e, &r_, sizeof(r_));\n"
    b"}\n",
)

BIND_IMAGE2 = (
    b"    uint32_t bindInfoCount;\n"
    b"    vkb_dec_bytes(d, &bindInfoCount, sizeof(bindInfoCount));\n"
    b"    const VkBindImageMemoryInfo *pBindInfos;\n"
    b"    if (vkb_dec_u8(d)) {\n"
    b"        uint32_t n_ = vkb_dec_u32(d);\n"
    b"        VkBindImageMemoryInfo *a_ = (VkBindImageMemoryInfo *)vkb_dec_alloc(d, (size_t)n_ * sizeof(VkBindImageMemoryInfo));\n"
    b"        for (uint32_t i_ = 0; a_ && i_ < n_; i_++) vkb_dec_VkBindImageMemoryInfo(d, &a_[i_]);\n"
    b"        pBindInfos = a_;\n"
    b"    } else {\n"
    b"        pBindInfos = NULL;\n"
    b"    }\n"
    b"    if (d->err) { vkb_srv_bad_message(c); return; }\n"
    b"    if (!c->dt->vkBindImageMemory2) { vkb_srv_missing(c, \"vkBindImageMemory2\"); return; }\n"
    b"    VkResult r_ = c->dt->vkBindImageMemory2(device, bindInfoCount, pBindInfos);\n",
    b"    uint32_t bindInfoCount;\n"
    b"    vkb_dec_bytes(d, &bindInfoCount, sizeof(bindInfoCount));\n"
    b"    const VkBindImageMemoryInfo *pBindInfos;\n"
    b"    uint32_t guard_decoded_ = 0;\n"
    b"    if (vkb_dec_u8(d)) {\n"
    b"        uint32_t n_ = vkb_dec_u32(d);\n"
    b"        VkBindImageMemoryInfo *a_ = (VkBindImageMemoryInfo *)vkb_dec_alloc(d, (size_t)n_ * sizeof(VkBindImageMemoryInfo));\n"
    b"        for (uint32_t i_ = 0; a_ && i_ < n_; i_++) vkb_dec_VkBindImageMemoryInfo(d, &a_[i_]);\n"
    b"        pBindInfos = a_;\n"
    b"        guard_decoded_ = n_;\n"
    b"    } else {\n"
    b"        pBindInfos = NULL;\n"
    b"    }\n"
    b"    if (d->err) { vkb_srv_bad_message(c); return; }\n"
    b"    if (!c->dt->vkBindImageMemory2) { vkb_srv_missing(c, \"vkBindImageMemory2\"); return; }\n"
    b"    if (bindInfoCount > guard_decoded_) {\n"
    b"        VKB_ONCE(VKB_LOG_WARN, \"vkBindImageMemory2: %u bind infos but %u decoded; the driver is not called, \"\n"
    b"                 \"VK_ERROR_OUT_OF_DEVICE_MEMORY\", (unsigned)bindInfoCount, (unsigned)guard_decoded_);\n"
    b"        VkResult guard_r_ = VK_ERROR_OUT_OF_DEVICE_MEMORY;\n"
    b"        vkb_enc_bytes(e, &guard_r_, sizeof(guard_r_));\n"
    b"        return;\n"
    b"    }\n"
    b"    for (uint32_t i_ = 0; i_ < bindInfoCount; i_++) {\n"
    b"        if (!pBindInfos[i_].image || pBindInfos[i_].memory == VK_NULL_HANDLE) {\n"
    b"            VKB_ONCE(VKB_LOG_WARN, \"vkBindImageMemory2: bind info %u names a null image 0x%llx or memory 0x%llx (the \"\n"
    b"                     \"allocation was refused, probably by the memory budget); the driver is not called, \"\n"
    b"                     \"VK_ERROR_OUT_OF_DEVICE_MEMORY\", (unsigned)i_,\n"
    b"                     (unsigned long long)(uintptr_t)pBindInfos[i_].image,\n"
    b"                     (unsigned long long)(uintptr_t)pBindInfos[i_].memory);\n"
    b"            VkResult guard_r_ = VK_ERROR_OUT_OF_DEVICE_MEMORY;\n"
    b"            vkb_enc_bytes(e, &guard_r_, sizeof(guard_r_));\n"
    b"            return;\n"
    b"        }\n"
    b"    }\n"
    b"    VkResult r_ = c->dt->vkBindImageMemory2(device, bindInfoCount, pBindInfos);\n",
)

GUARD = [LOG_INCLUDE, BIND_BUFFER, BIND_BUFFER2, BIND_IMAGE, BIND_IMAGE2]


def replace_once(data, old, new, what):
    if data.count(old) != 1:
        raise SystemExit("%s: anchor missing or duplicated" % what)
    return data.replace(old, new)


def mem_budget(data):
    for old, new in MEM_BUDGET:
        data = replace_once(data, old, new, TARGET + " (memory budget)")
    return data


def guard(data):
    data = replace_once(data, *LOG_INCLUDE, TARGET + " (log include)")
    data = replace_once(data, *BIND_BUFFER, TARGET + " (vkBindBufferMemory)")
    data = replace_once(data, *BIND_BUFFER2, TARGET + " (vkBindBufferMemory2)")
    data = replace_once(data, *BIND_IMAGE, TARGET + " (vkBindImageMemory)")
    data = replace_once(data, *BIND_IMAGE2, TARGET + " (vkBindImageMemory2)")
    return data


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
    for name, expected in CHAIN.items():
        recorded = git(root, "rev-parse", "HEAD:" + name)
        if recorded != expected:
            raise SystemExit("Unexpected committed blob: " + name)
    pristine = subprocess.check_output(["git", "-C", str(root), "show", "HEAD:" + TARGET])
    budgeted = mem_budget(canonical(pristine))
    if hashlib.sha256(budgeted).hexdigest() != MEM_BUDGET_SHA256:
        raise SystemExit("The memory-budget pre-state of " + TARGET + " does not match its recorded sha256")
    expected = guard(budgeted)
    path = root / TARGET
    have = canonical(path.read_bytes())
    changes = sorted(git(root, "diff", "--name-only", "HEAD").splitlines())
    if args.check:
        if have != canonical(pristine):
            raise SystemExit("Baseline is not pristine: " + TARGET)
        if changes:
            raise SystemExit("Unexpected tracked changes: " + repr(changes))
        print(TARGET, "git-blob=" + CHAIN[TARGET], "sha256=" + hashlib.sha256(pristine).hexdigest())
        print("Verified pristine baseline; the bind guard applies on top of the memory budget candidate "
              "(post-memory-budget sha256=" + MEM_BUDGET_SHA256 + ")")
        return
    if args.verify_candidate:
        if have != expected:
            raise SystemExit("Candidate content mismatch: " + TARGET)
        if changes != sorted(CHAIN):
            raise SystemExit("Unexpected tracked changes in the candidate: " + repr(changes))
        print(TARGET, "candidate sha256=" + hashlib.sha256(expected).hexdigest())
        print("Verified the exact server-side null bind guard (memory budget included)")
        return
    if have == expected:
        if changes != sorted(CHAIN):
            raise SystemExit("Unexpected tracked changes: " + repr(changes))
        print(TARGET, "already candidate (sha256=" + hashlib.sha256(have).hexdigest() + ")")
        print("Applied the server-side null bind guard (already present)")
        return
    if have != budgeted:
        if have == canonical(pristine):
            raise SystemExit("The memory budget patch is not applied; apply malibridge-mem-budget-patch.py first")
        raise SystemExit("Working tree is neither the memory-budget candidate nor this candidate: " + TARGET)
    path.write_bytes(restore_newlines(expected, path.read_bytes()))
    changes = git(root, "diff", "--name-only", "HEAD").splitlines()
    if sorted(changes) != sorted(CHAIN):
        raise SystemExit("Unexpected tracked changes: " + repr(changes))
    print(TARGET, "patched (memory budget, sha256=" + hashlib.sha256(path.read_bytes()).hexdigest() + ")")
    print("Applied the server-side null bind guard: a bind naming VK_NULL_HANDLE is refused with "
          "VK_ERROR_OUT_OF_DEVICE_MEMORY before the driver is called")


if __name__ == "__main__":
    main()
