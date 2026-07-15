/* Provides an UNVERSIONED fcntl64 that forwards to the system fcntl.
 * On Linux, fcntl64 is ABI-identical to fcntl; glibc < 2.28 only exports
 * `fcntl`, so modules built against glibc 2.28+ fail to relocate fcntl64.
 * Build:  gcc -shared -fPIC -O2 -o libfcntl64.so fcntl64-shim.c
 * Then patchelf --add-needed libfcntl64.so <module.node> and point rpath here.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdarg.h>
int fcntl64(int fd, int cmd, ...) {
    va_list ap; va_start(ap, cmd);
    void *arg = va_arg(ap, void *); va_end(ap);
    return fcntl(fd, cmd, arg);
}
