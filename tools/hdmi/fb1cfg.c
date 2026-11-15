// fb1cfg: tell PhxAMDFB's second head (HDMI, boot-arg phxfb2=1) which monitor and mode user space has lit, through
// the sysctl debug.phxfb1_config.   cc -arch x86_64 -O2 -o fb1cfg fb1cfg.c     (run as root)
//   fb1cfg show                      the framebuffer's current state
//   fb1cfg offline                   nothing connected
//   fb1cfg online <edid.bin> [1440p|auto]  the mode is the EDID's first detailed timing; with "1440p" the fixed
//                                    2560x1440@60 (244.8 MHz, 2720x1500 total) that hdmi-on.sh programs; "auto" takes
//                                    the EDID's timing only when it is that mode
//   fb1cfg online <edid.bin> mode <w h pclkKHz htot hss hse vtot vss vse flags>   the mode hdmimode.py chose
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <sys/sysctl.h>
struct PhxFB1Config {
    uint32_t version, online, width, height, pitchPixels, refreshMilliHz;
    uint32_t pixelClockKHz, hTotal, hSyncStart, hSyncEnd, vTotal, vSyncStart, vSyncEnd, syncFlags, edidLen;
    uint8_t edid[1024];
};
static void show(const struct PhxFB1Config *c) {
    printf("online %u  %ux%u pitch %u  %u.%03u Hz  pclk %u kHz  h %u/%u-%u/%u  v %u/%u-%u/%u  sync +h%u +v%u  EDID %u bytes\n", c->online,
           c->width, c->height, c->pitchPixels, c->refreshMilliHz / 1000, c->refreshMilliHz % 1000, c->pixelClockKHz, c->width,
           c->hSyncStart, c->hSyncEnd, c->hTotal, c->height, c->vSyncStart, c->vSyncEnd, c->vTotal, c->syncFlags & 1, (c->syncFlags >> 1) & 1, c->edidLen);
}
int main(int argc, char **argv) {
    struct PhxFB1Config c; size_t len = sizeof c;
    memset(&c, 0, sizeof c);
    if (argc < 2) { fprintf(stderr, "usage: fb1cfg show | offline | online <edid.bin> [1440p|auto]\n"); return 2; }
    if (!strcmp(argv[1], "show")) {
        if (sysctlbyname("debug.phxfb1_config", &c, &len, NULL, 0)) { perror("debug.phxfb1_config"); return 1; }
        show(&c); return 0;
    }
    c.version = 1;
    if (!strcmp(argv[1], "online") && argc >= 3) {
        FILE *f = fopen(argv[2], "rb");
        if (!f) { perror(argv[2]); return 1; }
        c.edidLen = (uint32_t)fread(c.edid, 1, sizeof c.edid, f) & ~127u; fclose(f);
        if (c.edidLen < 128 || memcmp(c.edid, "\0\xff\xff\xff\xff\xff\xff\0", 8)) { fprintf(stderr, "%s is not an EDID\n", argv[2]); return 1; }
        if (c.edidLen > 128u * (1 + c.edid[126])) c.edidLen = 128u * (1 + c.edid[126]);
        c.online = 1;
        if (argc >= 14 && !strcmp(argv[3], "mode")) {   // mode w h pclkKHz htot hss hse vtot vss vse flags (hdmimode.py's mode.txt)
            uint32_t *dst[10] = { &c.width, &c.height, &c.pixelClockKHz, &c.hTotal, &c.hSyncStart, &c.hSyncEnd, &c.vTotal, &c.vSyncStart, &c.vSyncEnd, &c.syncFlags };
            for (int i = 0; i < 10; i++) *dst[i] = (uint32_t)strtoul(argv[4 + i], NULL, 0);
            goto have;
        }
        const int qhd = (c.edid[54] | c.edid[55] << 8) == 24480 && (c.edid[56] | (c.edid[58] >> 4) << 8) == 2560;
        if (argc >= 4 && (!strcmp(argv[3], "1440p") || (!strcmp(argv[3], "auto") && !qhd))) {
            c.width = 2560; c.height = 1440; c.pixelClockKHz = 244800; c.hTotal = 2720; c.hSyncStart = 2608; c.hSyncEnd = 2640;
            c.vTotal = 1500; c.vSyncStart = 1443; c.vSyncEnd = 1448; c.syncFlags = 1;
        } else {
            const uint8_t *d = c.edid + 54;   // the first detailed timing descriptor
            const unsigned pclk = d[0] | d[1] << 8;
            if (!pclk) { fprintf(stderr, "the EDID's first descriptor is not a timing\n"); return 1; }
            const unsigned ha = d[2] | (d[4] >> 4) << 8, hb = d[3] | (d[4] & 15) << 8, va = d[5] | (d[7] >> 4) << 8, vb = d[6] | (d[7] & 15) << 8;
            const unsigned hso = d[8] | (d[11] >> 6) << 8, hsw = d[9] | ((d[11] >> 4) & 3) << 8, vso = (d[10] >> 4) | ((d[11] >> 2) & 3) << 4,
                           vsw = (d[10] & 15) | (d[11] & 3) << 4;
            c.width = ha; c.height = va; c.pixelClockKHz = pclk * 10; c.hTotal = ha + hb; c.hSyncStart = ha + hso; c.hSyncEnd = ha + hso + hsw;
            c.vTotal = va + vb; c.vSyncStart = va + vso; c.vSyncEnd = va + vso + vsw;
            c.syncFlags = ((d[17] & 0x18) == 0x18) ? ((d[17] >> 1) & 1) | ((d[17] >> 2) & 1) << 1 : 1;
        }
have:
        c.pitchPixels = (c.width + 63) & ~63u;
        c.refreshMilliHz = (uint32_t)((uint64_t)c.pixelClockKHz * 1000000ull / ((uint64_t)c.hTotal * c.vTotal));
    } else if (strcmp(argv[1], "offline")) { fprintf(stderr, "usage: fb1cfg show | offline | online <edid.bin> [1440p|auto]\n"); return 2; }
    if (sysctlbyname("debug.phxfb1_config", NULL, NULL, &c, sizeof c)) { perror("debug.phxfb1_config"); return 1; }
    show(&c); return 0;
}
