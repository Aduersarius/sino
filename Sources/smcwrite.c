/* sino-smcwrite — root LaunchDaemon. Whitelist FnMd/FnTg only. */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <Security/Security.h>
#include <bsm/libbsm.h>
#include <copyfile.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <mach/mach.h>
#include <math.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include "SMC.h"

#define DEST "/Library/PrivilegedHelperTools/com.lov3u.sino.smcwrite"
#define PLIST "/Library/LaunchDaemons/com.lov3u.sino.smcwrite.plist"
#define SOCK "/var/run/com.lov3u.sino.smcwrite.sock"
#define LABEL "com.lov3u.sino.smcwrite"
#define ALLOWED_APP_DIR "/Applications/Sino.app"
#define ALLOWED_EXE_PATH "/Applications/Sino.app/Contents/MacOS/Sino"
#define ALLOWED_BUNDLE_ID "com.lov3u.sino"
#define MAX_FANS 4

extern char **environ;

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

enum { kSMCIndex = 2, kSMCReadKeyInfo = 9, kSMCReadBytes = 5, kSMCWriteBytes = 6 };

static io_connect_t g_conn;
static int g_listen = -1;

static UInt32 fourcc(const char *s) {
    return ((UInt32)(unsigned char)s[0] << 24) |
           ((UInt32)(unsigned char)s[1] << 16) |
           ((UInt32)(unsigned char)s[2] << 8) |
           (UInt32)(unsigned char)s[3];
}

static int smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t outsz = sizeof(*out);
    return IOConnectCallStructMethod(g_conn, kSMCIndex, in, sizeof(*in), out, &outsz);
}

static int smc_read(const char *key, void *buf, int buflen) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = fourcc(key);
    in.data8 = kSMCReadKeyInfo;
    if (smc_call(&in, &out) != KERN_SUCCESS) return -1;
    UInt32 sz = out.keyInfo.dataSize;
    if (sz > sizeof(out.bytes)) sz = sizeof(out.bytes);
    in.keyInfo.dataSize = sz;
    in.data8 = kSMCReadBytes;
    memset(&out, 0, sizeof(out));
    if (smc_call(&in, &out) != KERN_SUCCESS) return -1;
    int n = (int)sz;
    if (n > buflen) n = buflen;
    if (n < 0) n = 0;
    memcpy(buf, out.bytes, (size_t)n);
    return n;
}

static int is_allowed_write_key(const char *key) {
    if (strcmp(key, "Ftst") == 0) return 1;
    if (key[0] == 'F' && key[1] >= '0' && key[1] <= '3') {
        if ((key[2] == 'M' && key[3] == 'd' && key[4] == 0) ||
            (key[2] == 'm' && key[3] == 'd' && key[4] == 0) ||
            (key[2] == 'T' && key[3] == 'g' && key[4] == 0)) {
            return 1;
        }
    }
    return 0;
}

static int smc_write(const char *key, const void *buf, UInt32 sz) {
    if (!is_allowed_write_key(key)) return -1;
    SMCKeyData in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = fourcc(key);
    in.data8 = kSMCReadKeyInfo;
    if (smc_call(&in, &out) != KERN_SUCCESS) return -1;
    if (out.keyInfo.dataSize != sz) return -1;
    UInt32 dataType = out.keyInfo.dataType;

    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = fourcc(key);
    in.data8 = kSMCWriteBytes;
    in.keyInfo.dataSize = sz;
    in.keyInfo.dataType = dataType;
    memcpy(in.bytes, buf, sz > 32 ? 32 : sz);
    return smc_call(&in, &out) == KERN_SUCCESS ? 0 : -1;
}

static int fan_count(void) {
    unsigned char n = 0;
    if (smc_read("FNum", &n, 1) < 1) return 0;
    if (n > MAX_FANS) n = MAX_FANS;
    return n;
}

static void key_for(int i, char a, char b, char out[5]) {
    out[0] = 'F';
    out[1] = (char)('0' + i);
    out[2] = a;
    out[3] = b;
    out[4] = 0;
}

static void auto_all(void) {
    int n = fan_count();
    unsigned char z = 0;
    for (int i = 0; i < n; i++) {
        char k[5];
        key_for(i, 'M', 'd', k);
        smc_write(k, &z, 1);
        key_for(i, 'm', 'd', k);
        smc_write(k, &z, 1);
    }
    smc_write("Ftst", &z, 1);
}

static int set_fan(int i, float rpm) {
    if (!isfinite(rpm)) return -1;
    int n = fan_count();
    if (i < 0 || i >= n) return -1;
    char k[5];
    float mn = 2000.0f, mx = 6800.0f, v = 0.0f;
    key_for(i, 'M', 'n', k);
    if (smc_read(k, &v, 4) == 4 && isfinite(v) && v > 500.0f && v < 20000.0f) mn = v;
    key_for(i, 'M', 'x', k);
    if (smc_read(k, &v, 4) == 4 && isfinite(v) && v > mn && v < 20000.0f) mx = v;
    if (rpm < mn) rpm = mn;
    if (rpm > mx) rpm = mx;

    unsigned char md = 1;
    key_for(i, 'M', 'd', k);
    int rc = smc_write(k, &md, 1);
    if (rc != 0) {
        key_for(i, 'm', 'd', k);
        rc = smc_write(k, &md, 1);
    }
    if (rc != 0) {
        unsigned char one = 1;
        smc_write("Ftst", &one, 1);
        for (int r = 0; r < 6; r++) {
            usleep(50000);
            key_for(i, 'M', 'd', k);
            if ((rc = smc_write(k, &md, 1)) == 0) break;
            key_for(i, 'm', 'd', k);
            if ((rc = smc_write(k, &md, 1)) == 0) break;
        }
    }
    if (rc != 0) return -1;

    key_for(i, 'T', 'g', k);
    SMCKeyData in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = fourcc(k);
    in.data8 = kSMCReadKeyInfo;
    if (smc_call(&in, &out) == KERN_SUCCESS && out.keyInfo.dataSize == 2) {
        float clamped = rpm > 16383.0f ? 16383.0f : (rpm < 0.0f ? 0.0f : rpm);
        uint16_t val = (uint16_t)(clamped * 4.0f);
        uint8_t buf[2] = { (uint8_t)(val >> 8), (uint8_t)(val & 0xff) };
        return smc_write(k, buf, 2);
    }
    return smc_write(k, &rpm, 4);
}

static int peer_signer_matches_self(CFDictionaryRef peer_info) {
    SecCodeRef self_code = NULL;
    CFDictionaryRef self_info = NULL;
    int ok = 0;

    if (SecCodeCopySelf(kSecCSDefaultFlags, &self_code) == errSecSuccess && self_code) {
        if (SecCodeCopySigningInformation(self_code, kSecCSSigningInformation, &self_info) == errSecSuccess && self_info) {
            CFArrayRef self_certs = CFDictionaryGetValue(self_info, kSecCodeInfoCertificates);
            if (self_certs && CFArrayGetCount(self_certs) > 0) {
                CFArrayRef peer_certs = CFDictionaryGetValue(peer_info, kSecCodeInfoCertificates);
                if (peer_certs && CFArrayGetCount(peer_certs) > 0 &&
                    CFEqual(CFArrayGetValueAtIndex(self_certs, 0), CFArrayGetValueAtIndex(peer_certs, 0))) {
                    ok = 1;
                }
            }
            CFRelease(self_info);
        }
        CFRelease(self_code);
    }
    return ok;
}

static int peer_ok(int fd) {
    audit_token_t tok;
    socklen_t len = sizeof(tok);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &tok, &len) != 0) return 0;
    pid_t pid = audit_token_to_pid(tok);
    if (pid <= 0) return 0;

    char raw_path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, raw_path, sizeof(raw_path)) <= 0) return 0;

    char resolved[PATH_MAX];
    if (!realpath(raw_path, resolved)) return 0;
    if (strcmp(resolved, ALLOWED_EXE_PATH) != 0) return 0;

    struct stat st_app, st_exe;
    if (stat(ALLOWED_APP_DIR, &st_app) != 0 || !S_ISDIR(st_app.st_mode)) return 0;
    if ((st_app.st_mode & S_IWOTH) != 0) return 0;
    if (stat(resolved, &st_exe) != 0 || !S_ISREG(st_exe.st_mode)) return 0;
    if ((st_exe.st_mode & S_IWOTH) != 0) return 0;

    int authorized = 0;
    CFDataRef tok_data = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&tok, sizeof(tok));
    if (!tok_data) return 0;
    const void *keys[] = { kSecGuestAttributeAudit };
    const void *vals[] = { tok_data };
    CFDictionaryRef attrs = CFDictionaryCreate(
        kCFAllocatorDefault, keys, vals, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks
    );
    CFRelease(tok_data);
    if (!attrs) return 0;

    SecCodeRef guest = NULL;
    if (SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, &guest) == errSecSuccess && guest) {
        if (SecCodeCheckValidity(guest, kSecCSDefaultFlags, NULL) == errSecSuccess) {
            CFURLRef code_url = NULL;
            char code_path[PATH_MAX];
            if (SecCodeCopyPath(guest, kSecCSDefaultFlags, &code_url) == errSecSuccess && code_url) {
                if (CFURLGetFileSystemRepresentation(code_url, true, (UInt8 *)code_path, sizeof(code_path))) {
                    char code_real[PATH_MAX];
                    if (realpath(code_path, code_real) && strcmp(code_real, ALLOWED_EXE_PATH) == 0) {
                        CFDictionaryRef info = NULL;
                        if (SecCodeCopySigningInformation(guest, kSecCSSigningInformation, &info) == errSecSuccess && info) {
                            CFStringRef ident = CFDictionaryGetValue(info, kSecCodeInfoIdentifier);
                            if (ident && CFGetTypeID(ident) == CFStringGetTypeID() &&
                                CFStringCompare(ident, CFSTR(ALLOWED_BUNDLE_ID), 0) == kCFCompareEqualTo) {
                                if (peer_signer_matches_self(info)) {
                                    authorized = 1;
                                }
                            }
                            CFRelease(info);
                        }
                    }
                }
                CFRelease(code_url);
            }
        }
        CFRelease(guest);
    }
    CFRelease(attrs);
    return authorized;
}

static int reply(int fd, const char *s) {
    size_t n = strlen(s);
    return (int)write(fd, s, n) == (int)n ? 0 : -1;
}

static void handle_client(int fd) {
    struct timeval rcv_tv = { .tv_sec = 10, .tv_usec = 0 };
    struct timeval snd_tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcv_tv, sizeof(rcv_tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &snd_tv, sizeof(snd_tv));

    char buf[96];
    int used = 0;
    int did_override = 0;
    while (1) {
        ssize_t r = read(fd, buf + used, sizeof(buf) - 1 - (size_t)used);
        if (r <= 0) break;
        used += (int)r;
        buf[used] = 0;
        char *nl;
        while ((nl = memchr(buf, '\n', (size_t)used))) {
            *nl = 0;
            if (strcmp(buf, "PING") == 0) {
                reply(fd, "OK\n");
            } else if (strcmp(buf, "AUTO") == 0) {
                auto_all();
                did_override = 0;
                reply(fd, "OK\n");
            } else if (strncmp(buf, "AUTO ", 5) == 0) {
                int fan = -1;
                if (sscanf(buf + 5, "%d", &fan) == 1 && fan >= 0 && fan < fan_count()) {
                    char k[5];
                    unsigned char z = 0;
                    key_for(fan, 'M', 'd', k);
                    smc_write(k, &z, 1);
                    key_for(fan, 'm', 'd', k);
                    smc_write(k, &z, 1);
                } else {
                    auto_all();
                    did_override = 0;
                }
                reply(fd, "OK\n");
            } else if (strncmp(buf, "SET ", 4) == 0) {
                int fan = -1;
                float rpm = 0;
                if (sscanf(buf + 4, "%d %f", &fan, &rpm) != 2 || set_fan(fan, rpm) != 0) {
                    reply(fd, "ERR\n");
                } else {
                    did_override = 1;
                    reply(fd, "OK\n");
                }
            } else if (strcmp(buf, "VER") == 0) {
                char ver[16];
                snprintf(ver, sizeof(ver), "VER %d\n", SINO_HELPER_VERSION);
                reply(fd, ver);
            } else {
                reply(fd, "ERR\n");
            }
            int rest = used - (int)(nl + 1 - buf);
            memmove(buf, nl + 1, (size_t)rest);
            used = rest;
        }
        if (used > 80) {
            reply(fd, "ERR\n");
            break;
        }
    }
    if (did_override) {
        auto_all();
    }
}

static void cleanup(int sig) {
    (void)sig;
    auto_all();
    if (g_listen >= 0) close(g_listen);
    unlink(SOCK);
    if (g_conn) IOServiceClose(g_conn);
    _exit(0);
}

static int run_cmd(char *const argv[]) {
    pid_t pid = 0;
    if (posix_spawn(&pid, argv[0], NULL, NULL, argv, environ) != 0) return -1;
    int st = 0;
    waitpid(pid, &st, 0);
    return st;
}

static const char *plist =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
    "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    "<plist version=\"1.0\"><dict>\n"
    "<key>Label</key><string>" LABEL "</string>\n"
    "<key>ProgramArguments</key><array><string>" DEST "</string></array>\n"
    "<key>RunAtLoad</key><true/>\n"
    "<key>KeepAlive</key><true/>\n"
    "</dict></plist>\n";

static int do_install(const char *self) {
    if (geteuid() != 0) {
        fprintf(stderr, "root required\n");
        return 1;
    }
    char *bootout[] = { "/bin/launchctl", "bootout", "system/" LABEL, NULL };
    run_cmd(bootout);
    unlink(SOCK);
    mkdir("/Library/PrivilegedHelperTools", 0755);
    if (copyfile(self, DEST, NULL, COPYFILE_DATA | COPYFILE_UNLINK) != 0) {
        perror("copyfile");
        return 1;
    }
    chmod(DEST, 0755);
    chown(DEST, 0, 0);
    int fd = open(PLIST, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        perror("plist");
        return 1;
    }
    size_t plen = strlen(plist);
    ssize_t written = write(fd, plist, plen);
    close(fd);
    if (written != (ssize_t)plen) {
        perror("plist write");
        unlink(PLIST);
        return 1;
    }
    chown(PLIST, 0, 0);
    chmod(PLIST, 0644);
    char *boot[] = { "/bin/launchctl", "bootstrap", "system", PLIST, NULL };
    if (run_cmd(boot) != 0) {
        char *load[] = { "/bin/launchctl", "load", "-w", PLIST, NULL };
        run_cmd(load);
    }
    for (int i = 0; i < 40; i++) {
        if (access(SOCK, F_OK) == 0) return 0;
        usleep(50000);
    }
    fprintf(stderr, "socket did not appear\n");
    return 1;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "--install") == 0)
        return do_install(argv[0]);

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return 1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) return 1;

    auto_all();
    signal(SIGTERM, cleanup);
    signal(SIGINT, cleanup);
    signal(SIGPIPE, SIG_IGN);

    unlink(SOCK);
    g_listen = socket(AF_UNIX, SOCK_STREAM, 0);
    if (g_listen < 0) return 1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCK, sizeof(addr.sun_path) - 1);
    if (bind(g_listen, (struct sockaddr *)&addr, sizeof(addr)) != 0) return 1;
    chmod(SOCK, 0666);
    if (listen(g_listen, 4) != 0) return 1;

    while (1) {
        int fd = accept(g_listen, NULL, NULL);
        if (fd < 0) continue;
        if (!peer_ok(fd)) {
            close(fd);
            continue;
        }
        handle_client(fd);
        close(fd);
    }
}
