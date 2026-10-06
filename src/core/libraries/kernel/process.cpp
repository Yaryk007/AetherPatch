// SPDX-FileCopyrightText: Copyright 2025-2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "common/elf_info.h"
#include "common/logging/log.h"
#include "core/emulator_settings.h"
#include "core/file_sys/fs.h"
#include "core/libraries/kernel/orbis_error.h"
#include "core/libraries/kernel/process.h"
#include "core/libraries/libs.h"
#include "core/linker.h"
#ifdef SHADPS4_ENABLE_FEX_GUEST_CPU
#include "core/guest_cpu/guest_callback.h"
#endif

namespace Libraries::Kernel {

s32 PS4_SYSV_ABI sceKernelIsInSandbox() {
    return 1;
}

s32 PS4_SYSV_ABI sceKernelIsNeoMode() {
    static s32 IsNeoMode = -1;
    if (IsNeoMode == -1) {
        IsNeoMode = EmulatorSettings.IsNeo() &&
                    Common::ElfInfo::Instance().GetPSFAttributes().support_neo_mode;
    }
    return IsNeoMode;
}

s32 PS4_SYSV_ABI sceKernelHasNeoMode() {
    return EmulatorSettings.IsNeo();
}

s32 PS4_SYSV_ABI sceKernelGetMainSocId() {
    // These hardcoded values are based on hardware observations.
    // Different models of PS4/PS4 Pro likely return slightly different values.
    LOG_DEBUG(Lib_Kernel, "called");
    if (EmulatorSettings.IsNeo()) {
        return 0x740f30;
    }
    return 0x710f10;
}

s32 PS4_SYSV_ABI sceKernelGetCompiledSdkVersion(s32* ver) {
    if (!ver) {
        return ORBIS_KERNEL_ERROR_EINVAL;
    }
    *ver = Common::ElfInfo::Instance().CompiledSdkVer();
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceKernelGetCpumode() {
    LOG_DEBUG(Lib_Kernel, "called");
    auto& attrs = Common::ElfInfo::Instance().GetPSFAttributes();
    u32 is_cpu6 = attrs.six_cpu_mode.Value();
    u32 is_cpu7 = attrs.seven_cpu_mode.Value();
    if (is_cpu6 == 1 && is_cpu7 == 1) {
        return 2;
    }
    if (is_cpu7 == 1) {
        return 5;
    }
    return 0;
}

s32 PS4_SYSV_ABI sceKernelGetCurrentCpu() {
    LOG_DEBUG(Lib_Kernel, "called");
    return 0;
}

void* PS4_SYSV_ABI sceKernelGetProcParam() {
    auto* linker = Common::Singleton<Core::Linker>::Instance();
    return linker->GetProcParam();
}


// ─── libjbc (homebrew jailbreak library) ────────────────────────────────────
//
// Homebrew such as the PS4 Homebrew Store loads Media/jb.prx (sleirsgoevy's libjbc), looks its
// functions up with sceKernelDlsym, and uses them to escape the sandbox by patching the PS4
// kernel. There is no PS4 kernel here and the app already sees its files freely, so the real
// module would only spin forever. Loading jb.prx instead returns this built-in stand-in, whose
// functions report success; jbc_run_as_root just runs the callback.
namespace {
constexpr s32 kJbcModuleHandle = 0x4A424300; // never a real linker module index

bool IsJbcModule(std::string_view path) {
    const auto slash = path.find_last_of('/');
    const auto name = slash == std::string_view::npos ? path : path.substr(slash + 1);
    return name == "jb.prx" || name == "libjbc.prx" || name == "libjbc.sprx";
}

Core::Loader::SymbolResolver JbcSymbol(const char* name) {
    return {name, name, "libjbc", 1, "libjbc", Core::Loader::SymbolType::Function};
}
} // namespace

s32 PS4_SYSV_ABI jbc_get_cred(void* cred) {
    return 0;
}

s32 PS4_SYSV_ABI jbc_jailbreak_cred(void* cred) {
    return 0;
}

s32 PS4_SYSV_ABI jbc_set_cred(const void* cred) {
    return 0;
}

u64 PS4_SYSV_ABI jbc_get_prison0() {
    return 1;
}

u64 PS4_SYSV_ABI jbc_get_rootvnode() {
    return 1;
}

s32 PS4_SYSV_ABI jbc_mount_in_sandbox(const char* system_path, const char* mnt_name) {
    LOG_INFO(Lib_Kernel, "libjbc: mount {} as {} (no-op, the sandbox is not enforced)",
             system_path ? system_path : "", mnt_name ? mnt_name : "");
    return 0;
}

s32 PS4_SYSV_ABI jbc_unmount_in_sandbox(const char* mnt_name) {
    return 0;
}

// Kernel read/write helpers: nothing to read or write, report failure.
s32 PS4_SYSV_ABI jbc_krw_memcpy(u64 dst, u64 src, u64 size, s32 kind) {
    return -1;
}

u64 PS4_SYSV_ABI jbc_krw_read64(u64 addr, s32 kind) {
    return 0;
}

s32 PS4_SYSV_ABI jbc_krw_write64(u64 addr, s32 kind, u64 value) {
    return -1;
}

u64 PS4_SYSV_ABI jbc_krw_get_td() {
    return 0;
}

s32 PS4_SYSV_ABI jbc_run_as_root(void (*fn)(void*), void* arg, s32 cwd_mode) {
    if (fn == nullptr) {
        return -1;
    }
#ifdef SHADPS4_ENABLE_FEX_GUEST_CPU
    if (AetherPS4::GuestCpu::IsGuestFunctionAddress(reinterpret_cast<const void*>(fn))) {
        AetherPS4::GuestCpu::RunGuestFunctionOrAbort(reinterpret_cast<void*>(fn),
                                                     "jbc_run_as_root", arg);
        return 0;
    }
#endif
    reinterpret_cast<void(PS4_SYSV_ABI*)(void*)>(fn)(arg);
    return 0;
}

// The Store/Itemzflow build of jb.prx adds these two: jailbreak the process / restore the
// sandbox before exiting. Both report success (0).
s32 PS4_SYSV_ABI jbc_jailbreak_me() {
    return 0;
}

s32 PS4_SYSV_ABI jbc_rejail_multi() {
    return 0;
}

void RegisterJbc(Core::Loader::SymbolsResolver* sym) {
    LIB_FUNCTION("jailbreak_me", "libjbc", 1, "libjbc", jbc_jailbreak_me);
    LIB_FUNCTION("rejail_multi", "libjbc", 1, "libjbc", jbc_rejail_multi);
    LIB_FUNCTION("jbc_get_cred", "libjbc", 1, "libjbc", jbc_get_cred);
    LIB_FUNCTION("jbc_jailbreak_cred", "libjbc", 1, "libjbc", jbc_jailbreak_cred);
    LIB_FUNCTION("jbc_set_cred", "libjbc", 1, "libjbc", jbc_set_cred);
    LIB_FUNCTION("jbc_get_prison0", "libjbc", 1, "libjbc", jbc_get_prison0);
    LIB_FUNCTION("jbc_get_rootvnode", "libjbc", 1, "libjbc", jbc_get_rootvnode);
    LIB_FUNCTION("jbc_mount_in_sandbox", "libjbc", 1, "libjbc", jbc_mount_in_sandbox);
    LIB_FUNCTION("jbc_unmount_in_sandbox", "libjbc", 1, "libjbc", jbc_unmount_in_sandbox);
    LIB_FUNCTION("jbc_krw_memcpy", "libjbc", 1, "libjbc", jbc_krw_memcpy);
    LIB_FUNCTION("jbc_krw_read64", "libjbc", 1, "libjbc", jbc_krw_read64);
    LIB_FUNCTION("jbc_krw_write64", "libjbc", 1, "libjbc", jbc_krw_write64);
    LIB_FUNCTION("jbc_krw_get_td", "libjbc", 1, "libjbc", jbc_krw_get_td);
    LIB_FUNCTION("jbc_run_as_root", "libjbc", 1, "libjbc", jbc_run_as_root);
}

s32 PS4_SYSV_ABI sceKernelLoadStartModule(const char* moduleFileName, u64 args, const void* argp,
                                          u32 flags, const void* pOpt, s32* pRes) {
    LOG_INFO(Lib_Kernel, "called filename = {}, args = {}", moduleFileName, args);
    ASSERT(flags == 0);

    if (IsJbcModule(moduleFileName)) {
        LOG_INFO(Lib_Kernel, "Using the built-in libjbc instead of {}", moduleFileName);
        if (pRes != nullptr) {
            *pRes = 0;
        }
        return kJbcModuleHandle;
    }

    auto* mnt = Common::Singleton<Core::FileSys::MntPoints>::Instance();
    auto* linker = Common::Singleton<Core::Linker>::Instance();

    std::filesystem::path path;
    std::string guest_path(moduleFileName);

    s32 handle = -1;

    if (guest_path[0] == '/') {
        // try load /system/common/lib/ +path
        // try load /system/priv/lib/   +path
        path = mnt->GetHostPath(guest_path);
        handle = linker->LoadAndStartModule(path, args, argp, pRes);
        if (handle != -1)
            return handle;
    } else {
        if (!guest_path.contains('/')) {
            path = mnt->GetHostPath("/app0/" + guest_path);
            handle = linker->LoadAndStartModule(path, args, argp, pRes);
            if (handle != -1)
                return handle;
            // if ((flags & 0x10000) != 0)
            //  try load /system/priv/lib/   +basename
            //  try load /system/common/lib/ +basename
        } else {
            path = mnt->GetHostPath(guest_path);
            handle = linker->LoadAndStartModule(path, args, argp, pRes);
            if (handle != -1)
                return handle;
        }
    }

    return ORBIS_KERNEL_ERROR_ENOENT;
}

s32 PS4_SYSV_ABI sceKernelDlsym(s32 handle, const char* symbol, void** addrp) {
    auto* linker = Common::Singleton<Core::Linker>::Instance();
    if (handle == kJbcModuleHandle) {
        const auto* record = linker->GetHLESymbols().FindSymbol(JbcSymbol(symbol));
        if (record == nullptr) {
            LOG_WARNING(Lib_Kernel, "libjbc: {} is not implemented", symbol);
            return ORBIS_KERNEL_ERROR_ESRCH;
        }
        *addrp = reinterpret_cast<void*>(linker->GetCallableAddress(*record));
        return *addrp != nullptr ? ORBIS_OK : ORBIS_KERNEL_ERROR_ESRCH;
    }
    auto* module = linker->GetModule(handle);
    if (module == nullptr) {
        return ORBIS_KERNEL_ERROR_ESRCH;
    }
    *addrp = module->FindByName(symbol);
    if (*addrp == nullptr) {
        return ORBIS_KERNEL_ERROR_ESRCH;
    }
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceKernelGetModuleInfoForUnwind(VAddr addr, s32 flags,
                                                 OrbisModuleInfoForUnwind* info) {
    if (flags >= 3) {
        std::memset(info, 0, sizeof(OrbisModuleInfoForUnwind));
        return ORBIS_KERNEL_ERROR_EINVAL;
    }
    if (!info) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    if (info->st_size < sizeof(OrbisModuleInfoForUnwind)) {
        return ORBIS_KERNEL_ERROR_EINVAL;
    }

    // Find module that contains specified address.
    LOG_INFO(Lib_Kernel, "called addr = {:#x}, flags = {:#x}", addr, flags);
    auto* linker = Common::Singleton<Core::Linker>::Instance();
    auto* module = linker->FindByAddress(addr);
    if (!module) {
        return ORBIS_KERNEL_ERROR_ESRCH;
    }
    const auto mod_info = module->GetModuleInfoEx();

    // Fill in module info.
    std::memset(info, 0, sizeof(OrbisModuleInfoForUnwind));
    info->name = mod_info.name;
    info->eh_frame_hdr_addr = mod_info.eh_frame_hdr_addr;
    info->eh_frame_addr = mod_info.eh_frame_addr;
    info->eh_frame_size = mod_info.eh_frame_size;
    info->seg0_addr = mod_info.segments[0].address;
    info->seg0_size = mod_info.segments[0].size;
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceKernelGetModuleInfoFromAddr(VAddr addr, s32 flags,
                                                Core::OrbisKernelModuleInfoEx* info) {
    if (flags >= 3) {
        std::memset(info, 0, sizeof(Core::OrbisKernelModuleInfoEx));
        return ORBIS_KERNEL_ERROR_EINVAL;
    }
    if (info == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }

    LOG_INFO(Lib_Kernel, "called addr = {:#x}, flags = {:#x}", addr, flags);
    auto* linker = Common::Singleton<Core::Linker>::Instance();
    auto* module = linker->FindByAddress(addr);
    if (!module) {
        return ORBIS_KERNEL_ERROR_ESRCH;
    }

    *info = module->GetModuleInfoEx();
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceKernelGetModuleInfo(s32 handle, Core::OrbisKernelModuleInfo* info) {
    if (info == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    if (info->st_size != sizeof(Core::OrbisKernelModuleInfo)) {
        return ORBIS_KERNEL_ERROR_EINVAL;
    }

    auto* linker = Common::Singleton<Core::Linker>::Instance();
    auto* module = linker->GetModule(handle);
    if (module == nullptr) {
        return ORBIS_KERNEL_ERROR_ESRCH;
    }
    *info = module->GetModuleInfo();
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceKernelGetModuleInfo2(s32 handle, Core::OrbisKernelModuleInfo* info) {
    if (info == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    if (info->st_size != sizeof(Core::OrbisKernelModuleInfo)) {
        return ORBIS_KERNEL_ERROR_EINVAL;
    }

    auto* linker = Common::Singleton<Core::Linker>::Instance();
    auto* module = linker->GetModule(handle);
    if (module == nullptr) {
        return ORBIS_KERNEL_ERROR_ESRCH;
    }
    if (module->IsSystemLib()) {
        return ORBIS_KERNEL_ERROR_EPERM;
    }
    *info = module->GetModuleInfo();
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceKernelGetModuleInfoInternal(s32 handle, Core::OrbisKernelModuleInfoEx* info) {
    if (info == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    if (info->st_size != sizeof(Core::OrbisKernelModuleInfoEx)) {
        return ORBIS_KERNEL_ERROR_EINVAL;
    }

    auto* linker = Common::Singleton<Core::Linker>::Instance();
    auto* module = linker->GetModule(handle);
    if (module == nullptr) {
        return ORBIS_KERNEL_ERROR_ESRCH;
    }
    *info = module->GetModuleInfoEx();
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceKernelGetModuleList(s32* handles, u64 num_array, u64* out_count) {
    if (handles == nullptr || out_count == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }

    auto* linker = Common::Singleton<Core::Linker>::Instance();
    u64 count = 0;
    auto* module = linker->GetModule(count);
    while (module != nullptr && count < num_array) {
        handles[count] = count;
        count++;
        module = linker->GetModule(count);
    }

    if (count == num_array && module != nullptr) {
        return ORBIS_KERNEL_ERROR_ENOMEM;
    }

    *out_count = count;
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceKernelGetModuleList2(s32* handles, u64 num_array, u64* out_count) {
    if (handles == nullptr || out_count == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }

    auto* linker = Common::Singleton<Core::Linker>::Instance();
    u64 id = 0;
    u64 index = 0;
    auto* module = linker->GetModule(id);
    while (module != nullptr && index < num_array) {
        if (!module->IsSystemLib()) {
            handles[index++] = id;
        }
        id++;
        module = linker->GetModule(id);
    }

    if (index == num_array && module != nullptr) {
        return ORBIS_KERNEL_ERROR_ENOMEM;
    }

    *out_count = index;
    return ORBIS_OK;
}

u32 PS4_SYSV_ABI posix_getuid() {
    return 1;
}

s32 PS4_SYSV_ABI exit(s32 status) {
    UNREACHABLE_MSG("Exiting with status code {}", status);
    return 0;
}

void RegisterProcess(Core::Loader::SymbolsResolver* sym) {
    RegisterJbc(sym);
    LIB_FUNCTION("xeu-pV8wkKs", "libkernel", 1, "libkernel", sceKernelIsInSandbox);
    LIB_FUNCTION("WB66evu8bsU", "libkernel", 1, "libkernel", sceKernelGetCompiledSdkVersion);
    LIB_FUNCTION("WslcK1FQcGI", "libkernel", 1, "libkernel", sceKernelIsNeoMode);
    LIB_FUNCTION("rNRtm1uioyY", "libkernel", 1, "libkernel", sceKernelHasNeoMode);
    LIB_FUNCTION("0vTn5IDMU9A", "libkernel", 1, "libkernel", sceKernelGetMainSocId);
    LIB_FUNCTION("VOx8NGmHXTs", "libkernel", 1, "libkernel", sceKernelGetCpumode);
    LIB_FUNCTION("g0VTBxfJyu0", "libkernel", 1, "libkernel", sceKernelGetCurrentCpu);
    LIB_FUNCTION("959qrazPIrg", "libkernel", 1, "libkernel", sceKernelGetProcParam);
    LIB_FUNCTION("wzvqT4UqKX8", "libkernel", 1, "libkernel", sceKernelLoadStartModule);
    LIB_FUNCTION("LwG8g3niqwA", "libkernel", 1, "libkernel", sceKernelDlsym);
    LIB_FUNCTION("RpQJJVKTiFM", "libkernel", 1, "libkernel", sceKernelGetModuleInfoForUnwind);
    LIB_FUNCTION("f7KBOafysXo", "libkernel", 1, "libkernel", sceKernelGetModuleInfoFromAddr);
    LIB_FUNCTION("kUpgrXIrz7Q", "libkernel", 1, "libkernel", sceKernelGetModuleInfo);
    LIB_FUNCTION("QgsKEUfkqMA", "libkernel", 1, "libkernel", sceKernelGetModuleInfo2);
    LIB_FUNCTION("QgsKEUfkqMA", "libkernel_module_info", 1, "libkernel", sceKernelGetModuleInfo2);
    LIB_FUNCTION("HZO7xOos4xc", "libkernel", 1, "libkernel", sceKernelGetModuleInfoInternal);
    LIB_FUNCTION("IuxnUuXk6Bg", "libkernel", 1, "libkernel", sceKernelGetModuleList);
    LIB_FUNCTION("ZzzC3ZGVAkc", "libkernel", 1, "libkernel", sceKernelGetModuleList2);
    LIB_FUNCTION("kg4x8Prhfxw", "libkernel", 1, "libkernel", posix_getuid);
    LIB_FUNCTION("6Z83sYWFlA8", "libkernel", 1, "libkernel", exit);
}

} // namespace Libraries::Kernel
