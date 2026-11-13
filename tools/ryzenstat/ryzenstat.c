// ryzenstat: package power, temperature, P-state and per-core effective clock from AMDRyzenCPUPowerManagement (selector 4)
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 5;
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AMDRyzenCPUPowerManagement"));
    io_connect_t c;
    if (!s || IOServiceOpen(s, mach_task_self(), 0, &c)) { fprintf(stderr, "open failed\n"); return 1; }
    if (argc > 2 && !strcmp(argv[1], "rdmsr")) { uint64_t in[1] = { strtoull(argv[2], 0, 16) }, out[1] = {0}; uint32_t on = 1;
        kern_return_t kr = IOConnectCallMethod(c, 40, in, 1, NULL, 0, out, &on, NULL, NULL);
        printf("msr 0x%llx = 0x%016llx (kr 0x%x)\n", in[0], out[0], kr); return kr != 0; }
    if (argc > 3 && !strcmp(argv[1], "wrmsr")) { uint64_t in[2] = { strtoull(argv[2], 0, 16), strtoull(argv[3], 0, 16) };
        kern_return_t kr = IOConnectCallMethod(c, 41, in, 2, NULL, 0, NULL, NULL, NULL, NULL);
        printf("wrmsr 0x%llx <- 0x%016llx (kr 0x%x)\n", in[0], in[1], kr); return kr != 0; }
    if (argc > 2) { uint64_t in[1] = { (uint64_t)atoi(argv[2]) }; printf("set pstate %llu -> 0x%x\n", in[0], IOConnectCallMethod(c, 10, in, 1, NULL, 0, NULL, NULL, NULL, NULL)); }
    uint64_t pst[8]; size_t psz = sizeof pst;
    if (!IOConnectCallMethod(c, 0, NULL, 0, NULL, 0, NULL, NULL, pst, &psz))
        for (int i = 0; i < 8; i++) printf("PStateDef%d 0x%016llx\n", i, pst[i]);
    for (int k = 0; k < n; k++) {
        float d[64 + 3]; size_t sz = sizeof d; uint64_t so[1]; uint32_t sn = 1;
        if (IOConnectCallMethod(c, 4, NULL, 0, NULL, 0, so, &sn, d, &sz)) { fprintf(stderr, "call failed\n"); return 1; }
        printf("pkg %.1f W  %.0f C  pstate %.0f  MHz:", d[0], d[1], d[2]);
        for (uint64_t i = 0; i < so[0]; i++) printf(" %.0f", d[3 + i]);
        printf("\n"); fflush(stdout); sleep(2);
    }
    return 0;
}
