// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

// libc functions that retail games get from the libc.prx they ship in sce_module/, but that
// homebrew (OpenOrbis-built apps such as the PS4 Homebrew Store) imports from the system's
// libSceLibcInternal instead. Without these they resolved to "return 0" stubs: memmove that
// moves nothing, opendir that returns NULL, fprintf to stderr that crashes on a NULL FILE.

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <vector>

#include <common/va_ctx.h>
#include "common/logging/log.h"
#include "core/libraries/kernel/file_system.h"
#include "core/libraries/kernel/kernel.h"
#include "core/libraries/kernel/posix_error.h"
#include "core/libraries/libc_internal/libc_internal_homebrew.h"
#include "core/libraries/libc_internal/libc_internal_io.h"
#include "core/libraries/libs.h"
#include "printf.h"

namespace Libraries::LibcInternal {

namespace {

// stdin/stdout/stderr as the guest sees them. Only the handle matters to the functions below.
OrbisFILE g_std_files[3] = {};
OrbisFILE* g_stdinp = &g_std_files[0];
OrbisFILE* g_stdoutp = &g_std_files[1];
OrbisFILE* g_stderrp = &g_std_files[2];

void InitStdFiles() {
    for (s32 i = 0; i < 3; i++) {
        g_std_files[i]._Handle = i;
        g_std_files[i]._Idx = static_cast<u8>(i);
        g_std_files[i]._Mode = 0x80;
    }
}

// Writes formatted text to a guest FILE: the console for stdout/stderr, the file otherwise.
s32 WriteToStream(OrbisFILE* stream, const char* text, s32 length) {
    if (stream == nullptr) {
        *Kernel::__Error() = POSIX_EBADF;
        return -1;
    }
    if (stream->_Handle == 1 || stream->_Handle == 2) {
        std::fwrite(text, 1, static_cast<size_t>(length), stream->_Handle == 1 ? stdout : stderr);
        return length;
    }
    const s64 written = Kernel::sceKernelWrite(stream->_Handle, text, static_cast<u64>(length));
    return written < 0 ? -1 : static_cast<s32>(written);
}

// FreeBSD DIR, private to these functions: getdents output is handed back one entry at a time.
struct OrbisDir {
    s32 fd;
    std::vector<char> buffer;
    s64 position;
    s64 length;
};

} // namespace

// ─── stdio ───────────────────────────────────────────────────────────────────

s32 PS4_SYSV_ABI internal_vfprintf(OrbisFILE* stream, const char* format, Common::VaList* arg) {
    std::vector<char> buffer(4096);
    const s32 length = vsnprintf_ctx(buffer.data(), buffer.size(), format, arg);
    const s32 clamped = std::min<s32>(length, static_cast<s32>(buffer.size()) - 1);
    return WriteToStream(stream, buffer.data(), clamped) < 0 ? -1 : length;
}

s32 PS4_SYSV_ABI internal_fprintf(VA_ARGS) {
    VA_CTX(ctx);
    auto* stream = vaArgPtr<OrbisFILE>(&ctx.va_list);
    const char* format = vaArgPtr<const char>(&ctx.va_list);
    return internal_vfprintf(stream, format, &ctx.va_list);
}

// ─── memory / strings ────────────────────────────────────────────────────────

void* PS4_SYSV_ABI internal_memmove(void* dest, const void* src, u64 n) {
    return std::memmove(dest, src, n);
}

const void* PS4_SYSV_ABI internal_memchr(const void* s, s32 c, u64 n) {
    return std::memchr(s, c, n);
}

u64 PS4_SYSV_ABI internal_strnlen(const char* s, u64 maxlen) {
    return ::strnlen(s, maxlen);
}

s32 PS4_SYSV_ABI internal_strerror_r(s32 errnum, char* buf, u64 buflen) {
    if (buf == nullptr || buflen == 0) {
        return POSIX_ERANGE;
    }
    const char* message = std::strerror(errnum);
    std::strncpy(buf, message, buflen - 1);
    buf[buflen - 1] = '\0';
    return std::strlen(message) >= buflen ? POSIX_ERANGE : 0;
}

s32 PS4_SYSV_ABI internal_atoi(const char* s) {
    return std::atoi(s);
}

s32 PS4_SYSV_ABI internal_isdigit(s32 c) {
    return std::isdigit(c & 0xff) ? 1 : 0;
}

s32 PS4_SYSV_ABI internal_islower(s32 c) {
    return std::islower(c & 0xff) ? 1 : 0;
}

s32 PS4_SYSV_ABI internal_isspace(s32 c) {
    return std::isspace(c & 0xff) ? 1 : 0;
}

s32 PS4_SYSV_ABI internal_isxdigit(s32 c) {
    return std::isxdigit(c & 0xff) ? 1 : 0;
}

// PS4 wchar_t is 16 bits.
u16* PS4_SYSV_ABI internal_wmemset(u16* s, u16 c, u64 n) {
    for (u64 i = 0; i < n; i++) {
        s[i] = c;
    }
    return s;
}

// FreeBSD struct tm: the nine int fields match the host's, followed by tm_gmtoff and tm_zone.
struct OrbisTm {
    s32 tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst;
    s64 tm_gmtoff;
    const char* tm_zone;
};

u64 PS4_SYSV_ABI internal_strftime(char* s, u64 max, const char* format, const OrbisTm* t) {
    if (s == nullptr || format == nullptr || t == nullptr || max == 0) {
        return 0;
    }
    std::tm host{};
    host.tm_sec = t->tm_sec;
    host.tm_min = t->tm_min;
    host.tm_hour = t->tm_hour;
    host.tm_mday = t->tm_mday;
    host.tm_mon = t->tm_mon;
    host.tm_year = t->tm_year;
    host.tm_wday = t->tm_wday;
    host.tm_yday = t->tm_yday;
    host.tm_isdst = t->tm_isdst;
    return std::strftime(s, max, format, &host);
}

// ─── directories ─────────────────────────────────────────────────────────────

OrbisDir* PS4_SYSV_ABI internal_opendir(const char* path) {
    const s32 fd = Kernel::posix_open(path, Kernel::ORBIS_KERNEL_O_DIRECTORY, 0);
    if (fd < 0) {
        return nullptr; // posix_open already set errno
    }
    return new OrbisDir{fd, std::vector<char>(0x10000), 0, 0};
}

Kernel::OrbisKernelDirent* PS4_SYSV_ABI internal_readdir(OrbisDir* dir) {
    if (dir == nullptr) {
        *Kernel::__Error() = POSIX_EBADF;
        return nullptr;
    }
    while (true) {
        if (dir->position >= dir->length) {
            dir->length = Kernel::posix_getdents(dir->fd, dir->buffer.data(), dir->buffer.size());
            dir->position = 0;
            if (dir->length <= 0) {
                return nullptr; // end of directory (or error, with errno set)
            }
        }
        auto* entry = reinterpret_cast<Kernel::OrbisKernelDirent*>(dir->buffer.data() + dir->position);
        if (entry->d_reclen == 0) {
            dir->length = 0;
            return nullptr;
        }
        dir->position += entry->d_reclen;
        if (entry->d_fileno != 0 || entry->d_namlen != 0) {
            return entry;
        }
    }
}

s32 PS4_SYSV_ABI internal_closedir(OrbisDir* dir) {
    if (dir == nullptr) {
        *Kernel::__Error() = POSIX_EBADF;
        return -1;
    }
    const s32 result = Kernel::posix_close(dir->fd);
    delete dir;
    return result;
}

// ─── runtime startup / teardown ──────────────────────────────────────────────

// Called by OpenOrbis' crt before main with the environment block; nothing to set up here.
void PS4_SYSV_ABI internal__init_env() {}

// Runs a DSO's atexit handlers on unload. Modules are never unloaded mid-process here.
void PS4_SYSV_ABI internal___cxa_finalize(void* dso) {}

// Implemented elsewhere in libc_internal but previously registered only under the "libc"
// alias that games' bundled libc.prx imports use; homebrew imports them from
// libSceLibcInternal, so they are registered under both names below.
char* PS4_SYSV_ABI internal_strcpy(char* dest, const char* src);
size_t PS4_SYSV_ABI internal_wcslen(const u16* str);
OrbisFILE* PS4_SYSV_ABI internal_freopen(const char* path, const char* mode, OrbisFILE* file);
float PS4_SYSV_ABI internal_fmaxf(float x, float y);
double PS4_SYSV_ABI internal_fmin(double x, double y);
float PS4_SYSV_ABI internal_fminf(float x, float y);
double PS4_SYSV_ABI internal_fmod(double x, double y);
float PS4_SYSV_ABI internal_fmodf(float x, float y);
float PS4_SYSV_ABI internal_frexpf(float x, int* exp);
double PS4_SYSV_ABI internal_ldexp(double x, int exp);
float PS4_SYSV_ABI internal_ldexpf(float x, int exp);
double PS4_SYSV_ABI internal_modf(double x, double* iptr);
float PS4_SYSV_ABI internal_roundf(float x);

void RegisterlibSceLibcInternalHomebrew(Core::Loader::SymbolsResolver* sym) {
    InitStdFiles();
    for (const char* lib : {"libSceLibcInternal", "libc"}) {
        LIB_FUNCTION("fffwELXNVFA", lib, 1, lib, internal_fprintf);
        LIB_FUNCTION("pDBDcY6uLSA", lib, 1, lib, internal_vfprintf);
        LIB_FUNCTION("+P6FRGH4LfA", lib, 1, lib, internal_memmove);
        LIB_FUNCTION("8u8lPzUEq+U", lib, 1, lib, internal_memchr);
        LIB_FUNCTION("5jNubw4vlAA", lib, 1, lib, internal_strnlen);
        LIB_FUNCTION("RBcs3uut1TA", lib, 1, lib, internal_strerror_r);
        LIB_FUNCTION("fPxypibz2MY", lib, 1, lib, internal_atoi);
        LIB_FUNCTION("JWBr5N8zyNE", lib, 1, lib, internal_isdigit);
        LIB_FUNCTION("KqYTqtSfGos", lib, 1, lib, internal_islower);
        LIB_FUNCTION("wazw2x2m3DQ", lib, 1, lib, internal_isspace);
        LIB_FUNCTION("srzSVSbKn7M", lib, 1, lib, internal_isxdigit);
        LIB_FUNCTION("ay3uROQAc5A", lib, 1, lib, internal_opendir);
        LIB_FUNCTION("lybyyKtP54c", lib, 1, lib, internal_readdir);
        LIB_FUNCTION("XepdqehVYe4", lib, 1, lib, internal_closedir);
        LIB_FUNCTION("bzQExy189ZI", lib, 1, lib, internal__init_env);
        LIB_FUNCTION("H2e8t5ScQGc", lib, 1, lib, internal___cxa_finalize);
        LIB_FUNCTION("Al8MZJh-4hM", lib, 1, lib, internal_wmemset);
        LIB_FUNCTION("Av3zjWi64Kw", lib, 1, lib, internal_strftime);
        LIB_OBJ("bgAcsbcEznc", lib, 1, lib, &g_stdinp);
        LIB_OBJ("zqJhBxAKfsc", lib, 1, lib, &g_stdoutp);
        LIB_OBJ("as8Od-tH1BI", lib, 1, lib, &g_stderrp);
    }
    const char* lib = "libSceLibcInternal";
    LIB_FUNCTION("kiZSXIWd9vg", lib, 1, lib, internal_strcpy);
    LIB_FUNCTION("WkkeywLJcgU", lib, 1, lib, internal_wcslen);
    LIB_FUNCTION("gkWgn0p1AfU", lib, 1, lib, internal_freopen);
    LIB_FUNCTION("Lyx2DzUL7Lc", lib, 1, lib, internal_fmaxf);
    LIB_FUNCTION("iU0z6SdUNbI", lib, 1, lib, internal_fmin);
    LIB_FUNCTION("uVRcM2yFdP4", lib, 1, lib, internal_fminf);
    LIB_FUNCTION("pKwslsMUmSk", lib, 1, lib, internal_fmod);
    LIB_FUNCTION("88Vv-AzHVj8", lib, 1, lib, internal_fmodf);
    LIB_FUNCTION("aaDMGGkXFxo", lib, 1, lib, internal_frexpf);
    LIB_FUNCTION("JrwFIMzKNr0", lib, 1, lib, internal_ldexp);
    LIB_FUNCTION("kn0yiYeExgA", lib, 1, lib, internal_ldexpf);
    LIB_FUNCTION("0WMHDb5Dt94", lib, 1, lib, internal_modf);
    LIB_FUNCTION("DDHG1a6+3q0", lib, 1, lib, internal_roundf);
}

} // namespace Libraries::LibcInternal
