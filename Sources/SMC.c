#include "SMC.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint32_t UInt32;
typedef uint16_t UInt16;
typedef struct { char major, minor, build, reserved[1]; UInt16 release; } SMCVers;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } SMCKeyInfo;
typedef unsigned char SMCBytes[32];
typedef struct {
    UInt32 key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    char result, status, data8;
    UInt32 data32;
    SMCBytes bytes;
} SMCKeyData;

enum { kSMCIndex = 2, kSMCReadKeyInfo = 9, kSMCReadBytes = 5 };

static io_connect_t g_conn;

static UInt32 fourcc(const char *s) {
    return ((UInt32)s[0] << 24) | ((UInt32)s[1] << 16) | ((UInt32)s[2] << 8) | (UInt32)s[3];
}

static int smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t outsz = sizeof(*out);
    return IOConnectCallStructMethod(g_conn, kSMCIndex, in, sizeof(*in), out, &outsz);
}

static int smc_read(const char *key, void *buf, int buflen, UInt32 *type_out, UInt32 *size_out) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = fourcc(key);
    in.data8 = kSMCReadKeyInfo;
    if (smc_call(&in, &out) != KERN_SUCCESS) return -1;
    UInt32 sz = out.keyInfo.dataSize;
    if (size_out) *size_out = sz;
    if (type_out) *type_out = out.keyInfo.dataType;
    in.keyInfo.dataSize = sz;
    in.data8 = kSMCReadBytes;
    memset(&out, 0, sizeof(out));
    if (smc_call(&in, &out) != KERN_SUCCESS) return -1;
    int n = (int)sz;
    if (n > buflen) n = buflen;
    memcpy(buf, out.bytes, (size_t)n);
    return n;
}

int pulse_smc_init(void) {
    if (g_conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS ? 0 : -1;
}

void pulse_smc_shutdown(void) {
    if (g_conn) {
        IOServiceClose(g_conn);
        g_conn = 0;
    }
}

int pulse_smc_fans(float *rpm, float *maxrpm, int cap) {
    if (!g_conn || cap <= 0) return 0;
    unsigned char nbuf = 0;
    if (smc_read("FNum", &nbuf, 1, NULL, NULL) < 0) return 0;
    int n = nbuf;
    if (n > cap) n = cap;
    for (int i = 0; i < n; i++) {
        char k[5] = { 'F', (char)('0' + i), 'A', 'c', 0 };
        float v = 0;
        smc_read(k, &v, 4, NULL, NULL);
        rpm[i] = v;
        k[2] = 'M'; k[3] = 'x';
        v = 0;
        smc_read(k, &v, 4, NULL, NULL);
        maxrpm[i] = v > 1 ? v : 8000;
    }
    return n;
}

int pulse_smc_temps(char *names32, float *celsius, int cap) {
    static const struct { const char *key; const char *name; } keys[] = {
        {"Tp01", "CPU"},
        {"Tp05", "CPU"},
        {"Tp09", "CPU E"},
        {"Tp0b", "CPU E"},
        {"Tg0P", "GPU"},
        {"Ts0P", "Skin"},
        {"TB1T", "Battery"},
        {"TB2T", "Battery"},
        {"TW0P", "Airport"},
        {"TH0x", "NAND"},
        {"Th0H", "Heatsink"},
        {NULL, NULL}
    };
    if (!g_conn || cap <= 0) return 0;
    int n = 0;
    for (int i = 0; keys[i].key && n < cap; i++) {
        float v = 0;
        uint32_t type = 0;
        unsigned char raw[8] = {0};
        int got = smc_read(keys[i].key, raw, 8, &type, NULL);
        if (got < 1) continue;
        if (type == fourcc("flt ") || type == fourcc("flt")) {
            memcpy(&v, raw, 4);
        } else if (got >= 2) {
            v = ((int16_t)((raw[0] << 8) | raw[1])) / 256.0f;
        }
        if (v < 15 || v > 115) continue;
        snprintf(names32 + n * 32, 32, "%s", keys[i].name);
        celsius[n] = v;
        n++;
    }
    return n;
}

#include <libproc.h>
#include <stdio.h>
#include <sys/resource.h>

int pulse_pid_energy_nj(int pid, uint64_t *nanojoules) {
    struct rusage_info_v6 ru;
    memset(&ru, 0, sizeof(ru));
    if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ru) != 0) return -1;
    *nanojoules = ru.ri_energy_nj;
    return 0;
}

int pulse_pid_footprint(int pid, uint64_t *bytes) {
    struct rusage_info_v6 ru;
    memset(&ru, 0, sizeof(ru));
    if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ru) != 0) return -1;
    *bytes = ru.ri_phys_footprint ? ru.ri_phys_footprint : ru.ri_resident_size;
    return 0;
}
