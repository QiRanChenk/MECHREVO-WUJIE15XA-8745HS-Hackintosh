// dmubboot: start the DAL DMUB firmware on DCN 3.1.4 under macOS and send it commands, through PhxBringup's debug
// selectors (boot-arg phxdebug=1, run as root). Sequence and values from Linux 7.2 on the same machine
// (staging/hdmi/ROUTING.md section 6). Every step is appended to a log and fsync'ed BEFORE it runs: the machine may
// reset, and the last line then names the step.
//   dmubboot status
//   dmubboot start <vbios.bin>     (after the firmware image went to the PSP: phxctl loadfw <fw> 256 <size> 51 <off>)
//   dmubboot cmd <w0> <w1> [w2..w7]   one 64-byte inbox command (hex u64 words), waits for the read pointer
// build: clang -arch x86_64 -O2 -o dmubboot dmubboot.c -framework IOKit -framework CoreFoundation
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdarg.h>

#define UC_TYPE 0x4E34384Eu
#define SEL_HELLO 0
#define SEL_READREGS 2
#define SEL_DBG_VRAM_READ 102
#define SEL_DBG_WRITE_REG 108
#define SEL_DBG_VRAM_WRITE 109
static io_connect_t conn;
static int logfd = -1;

static void say(const char *fmt, ...) {
   char b[256]; va_list ap; va_start(ap, fmt); int n = vsnprintf(b, sizeof b - 1, fmt, ap); va_end(ap);
   b[n++] = '\n'; fwrite(b, 1, n, stdout); fflush(stdout);
   if (logfd >= 0) { write(logfd, b, n); fsync(logfd); fcntl(logfd, F_FULLFSYNC); }
}
static int open_kext(void) {
   io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("PhxBringup"));
   if (!svc) { fprintf(stderr, "no PhxBringup\n"); return -1; }
   kern_return_t kr = IOServiceOpen(svc, mach_task_self(), UC_TYPE, &conn);
   uint64_t hin[2] = {1, 0}, hout[4]; uint32_t hn = 4;
   if (kr == 0) kr = IOConnectCallScalarMethod(conn, SEL_HELLO, hin, 2, hout, &hn);
   if (kr) { fprintf(stderr, "open: 0x%x\n", kr); return -1; }
   return 0;
}
static uint32_t rd(uint32_t reg) {
   uint64_t in[3] = {reg, 1, 0xFFFFFFFFull}; uint32_t v = 0; size_t sz = 4;
   IOConnectCallMethod(conn, SEL_READREGS, in, 3, NULL, 0, NULL, NULL, &v, &sz);
   return v;
}
static void wr(uint32_t reg, uint32_t val, const char *name) {
   say("w %-28s 0x%05x = 0x%08x", name, reg, val);
   // third input 1 = no read-back (newer PhxBringup): a read after the write moves the index of index/data registers.
   // An older kext rejects three inputs; then the plain two-input write is used.
   uint64_t in[3] = {reg, val, 1}, out[1] = {0}; uint32_t n = 1;
   if (IOConnectCallScalarMethod(conn, SEL_DBG_WRITE_REG, in, 3, out, &n) != KERN_SUCCESS) { n = 1; IOConnectCallScalarMethod(conn, SEL_DBG_WRITE_REG, in, 2, out, &n); }
}
static void vw(uint64_t off, uint32_t v) { uint64_t in[2] = {off, v}; IOConnectCallScalarMethod(conn, SEL_DBG_VRAM_WRITE, in, 2, NULL, NULL); }
static uint32_t vr(uint64_t off) {
   uint64_t in[2] = {off, 4}; uint32_t buf[4] = {0}; size_t sz = sizeof(buf);
   IOConnectCallMethod(conn, SEL_DBG_VRAM_READ, in, 2, NULL, 0, NULL, NULL, buf, &sz);
   return buf[0];
}

// VRAM (offsets in BAR0; MC address = 0x80_0000_0000 + offset), above mesboot's areas (which end at 0x2578000)
#define FBHI   0x80u
#define CW3_O  0x2800000u   // VBIOS copy, 0x4200
#define CW4_O  0x2810000u   // inbox1 0x2000 + outbox1 0x2000
#define CW5_O  0x2820000u   // trace buffer / region 5, 0x10040
#define CW6_O  0x2840000u   // firmware state, 0xcd00
// DMCUB registers (dword index)
enum { INBOX1_BASE = 0x3694, INBOX1_SIZE, INBOX1_WPTR, INBOX1_RPTR, OUTBOX0_BASE, OUTBOX0_SIZE, OUTBOX0_WPTR, OUTBOX0_RPTR,
       OUTBOX1_BASE, OUTBOX1_SIZE, OUTBOX1_WPTR, OUTBOX1_RPTR,
       SCRATCH0 = 0x36a3, SCRATCH1 = 0x36a4, SCRATCH14 = 0x36b1, SCRATCH15 = 0x36b2, CNTL = 0x36b6, GPINT1 = 0x36b8, CNTL2 = 0x36c0,
       R5_OFF = 0x3658, R5_OFFH = 0x3659, R5_TOP = 0x3662, MMHUBBUB_SOFT_RESET = 0x3802 };

static void status(void) {
   say("DMCUB_CNTL 0x%08x CNTL2 0x%08x SCRATCH0 0x%08x SCRATCH1(fw ver) 0x%08x SCRATCH14 0x%08x SCRATCH15 0x%08x", rd(CNTL), rd(CNTL2), rd(SCRATCH0), rd(SCRATCH1), rd(SCRATCH14), rd(SCRATCH15));
   say("inbox1 base 0x%08x size 0x%x wptr 0x%x rptr 0x%x | outbox1 base 0x%08x wptr 0x%x rptr 0x%x", rd(INBOX1_BASE), rd(INBOX1_SIZE), rd(INBOX1_WPTR), rd(INBOX1_RPTR), rd(OUTBOX1_BASE), rd(OUTBOX1_WPTR), rd(OUTBOX1_RPTR));
   say("CW3 off 0x%08x:%x base 0x%08x top 0x%08x | CW4 off 0x%08x base 0x%08x top 0x%08x", rd(0x367b), rd(0x367c), rd(0x3668), rd(0x3670), rd(0x367d), rd(0x3669), rd(0x3671));
   say("HPD2 0x%08x  DIG1_BE_EN 0x%08x  CC_DC_PIPE_DIS 0x%08x", rd(0x53dc), rd(0x5672), rd(0x358a));
}

static int start(const char *vbios) {
   FILE *f = fopen(vbios, "rb"); if (!f) { perror(vbios); return 1; }
   static uint8_t vb[0x4200]; size_t n = fread(vb, 1, sizeof vb, f); fclose(f);
   say("== start: vbios %zu bytes", n);
   status();
   say("clear and fill VRAM windows");
   for (uint32_t o = 0; o < 0x4200; o += 4) { uint32_t v; memcpy(&v, vb + o, 4); vw(CW3_O + o, v); }
   for (uint32_t o = 0; o < 0x4000; o += 4) vw(CW4_O + o, 0);
   for (uint32_t o = 0; o < 0x11000; o += 4) vw(CW5_O + o, 0);
   for (uint32_t o = 0; o < 0xd000; o += 4) vw(CW6_O + o, 0);
   say("vram check: cw3[0]=0x%08x (file 0x%02x%02x%02x%02x le)", vr(CW3_O), vb[3], vb[2], vb[1], vb[0]);
   // dmub_dcn31_reset: ask the running firmware to stop, then force the reset
   if (!(rd(CNTL2) & 1)) {
      wr(GPINT1, 0x80020000, "GPINT STOP_FW");
      for (int i = 0; i < 100 && (rd(GPINT1) & 0x80000000u); i++) usleep(1000);
      say("gpint after stop: datain 0x%08x", rd(GPINT1));
      usleep(30000);
   }
   wr(CNTL2, rd(CNTL2) | 1, "DMCUB_CNTL2 soft reset");
   wr(CNTL, rd(CNTL) & ~0x10000u, "DMCUB_CNTL enable=0");
   wr(MMHUBBUB_SOFT_RESET, rd(MMHUBBUB_SOFT_RESET) | 1, "MMHUBBUB_SOFT_RESET dmuif=1");
   wr(INBOX1_RPTR, 0, "INBOX1_RPTR"); wr(INBOX1_WPTR, 0, "INBOX1_WPTR"); wr(OUTBOX1_RPTR, 0, "OUTBOX1_RPTR"); wr(OUTBOX1_WPTR, 0, "OUTBOX1_WPTR");
   wr(OUTBOX0_RPTR, 0, "OUTBOX0_RPTR"); wr(OUTBOX0_WPTR, 0, "OUTBOX0_WPTR"); wr(SCRATCH0, 0, "SCRATCH0"); wr(GPINT1, 0, "GPINT_DATAIN1");
   // windows: OFFSET = low 32 bits of the MC address, OFFSET_HIGH = 0x80, BASE/TOP as Linux
   wr(0x367b, CW3_O, "CW3_OFFSET"); wr(0x367c, FBHI, "CW3_OFFSET_HIGH"); wr(0x3668, 0x63000000, "CW3_BASE"); wr(0x3670, 0x83004200, "CW3_TOP");
   wr(0x367d, CW4_O, "CW4_OFFSET"); wr(0x367e, FBHI, "CW4_OFFSET_HIGH"); wr(0x3669, 0x64000000, "CW4_BASE"); wr(0x3671, 0x84004000, "CW4_TOP");
   wr(0x367f, CW5_O, "CW5_OFFSET"); wr(0x3680, FBHI, "CW5_OFFSET_HIGH"); wr(0x366a, 0x65000000, "CW5_BASE"); wr(0x3672, 0x85010040, "CW5_TOP");
   wr(R5_OFF, CW5_O, "REGION5_OFFSET"); wr(R5_OFFH, FBHI, "REGION5_OFFSET_HIGH"); wr(R5_TOP, 0x8001003f, "REGION5_TOP");
   wr(0x3681, CW6_O, "CW6_OFFSET"); wr(0x3682, FBHI, "CW6_OFFSET_HIGH"); wr(0x366b, 0x66000000, "CW6_BASE"); wr(0x3673, 0x8600cd00, "CW6_TOP");
   wr(OUTBOX0_BASE, 0xa0000010, "OUTBOX0_BASE"); wr(OUTBOX0_SIZE, 0x00010030, "OUTBOX0_SIZE");
   wr(INBOX1_BASE, 0x64000000, "INBOX1_BASE"); wr(INBOX1_SIZE, 0x2000, "INBOX1_SIZE");
   wr(OUTBOX1_BASE, 0x64002000, "OUTBOX1_BASE"); wr(OUTBOX1_SIZE, 0x2000, "OUTBOX1_SIZE");
   wr(SCRATCH14, 0x08000280, "SCRATCH14 boot options");
   wr(MMHUBBUB_SOFT_RESET, rd(MMHUBBUB_SOFT_RESET) & ~1u, "MMHUBBUB_SOFT_RESET dmuif=0");
   wr(SCRATCH15, 0, "SCRATCH15");
   wr(CNTL, (rd(CNTL) & ~0x100000u) | 0x10000u, "DMCUB_CNTL enable=1");
   wr(CNTL2, rd(CNTL2) & ~1u, "DMCUB_CNTL2 release reset");
   uint32_t s = 0;
   for (int i = 0; i < 500; i++) { s = rd(SCRATCH0); if ((s & 3) == 3) break; usleep(1000); }
   say("boot status SCRATCH0 = 0x%08x (%s)", s, (s & 3) == 3 ? "DAL firmware running, mailbox ready" : "NOT up");
   status();
   return (s & 3) == 3 ? 0 : 2;
}

static int cmd(int argc, char **argv) {
   uint64_t w[8] = {0};
   for (int i = 0; i < argc && i < 8; i++) w[i] = strtoull(argv[i], NULL, 16);
   uint32_t wp = rd(INBOX1_WPTR), rp = rd(INBOX1_RPTR), sz = rd(INBOX1_SIZE);
   if (!sz || wp != rp) { say("inbox not idle: wptr 0x%x rptr 0x%x size 0x%x", wp, rp, sz); return 1; }
   say("cmd at 0x%x: %016llx %016llx %016llx %016llx", wp, w[0], w[1], w[2], w[3]);
   for (int i = 0; i < 8; i++) { vw(CW4_O + wp + i * 8, (uint32_t)w[i]); vw(CW4_O + wp + i * 8 + 4, (uint32_t)(w[i] >> 32)); }
   (void)vr(CW4_O + wp);
   uint32_t nw = (wp + 0x40) % sz;
   wr(INBOX1_WPTR, nw, "INBOX1_WPTR");
   int i; for (i = 0; i < 2000 && rd(INBOX1_RPTR) != nw; i++) usleep(500);
   say("rptr 0x%x after %d polls (%s); reply words: %08x%08x %08x%08x", rd(INBOX1_RPTR), i, rd(INBOX1_RPTR) == nw ? "consumed" : "TIMEOUT",
       vr(CW4_O + wp + 4), vr(CW4_O + wp), vr(CW4_O + wp + 12), vr(CW4_O + wp + 8));
   return rd(INBOX1_RPTR) == nw ? 0 : 2;
}

// run <plan>: one step per line, logged before it runs:  w <reg> <val> <name> | d <w0> <w1> [..w7] | p <reg> <mask> <val> <name> (poll) | s <ms>
static int run(const char *path) {
   FILE *f = fopen(path, "r"); if (!f) { perror(path); return 1; }
   char line[512]; int n = 0;
   while (fgets(line, sizeof line, f)) {
      char op = line[0]; n++;
      if (op == 'w') { unsigned reg, val; char name[128] = ""; if (sscanf(line + 1, "%x %x %127s", &reg, &val, name) >= 2) wr(reg, val, name); }
      else if (op == 'd') {
         char *argvv[8]; int c = 0; char *tok = strtok(line + 1, " \n");
         while (tok && c < 8) { argvv[c++] = tok; tok = strtok(NULL, " \n"); }
         if (cmd(c, argvv)) { say("plan line %d: DMUB command not consumed, stopping", n); fclose(f); return 2; }
      } else if (op == 'p') {
         unsigned reg, mask, val; char name[128] = ""; sscanf(line + 1, "%x %x %x %127s", &reg, &mask, &val, name);
         int i; uint32_t v = 0; for (i = 0; i < 400; i++) { v = rd(reg); if ((v & mask) == val) break; usleep(500); }
         say("p %-28s 0x%05x = 0x%08x after %d polls%s", name, reg, v, i, i == 400 ? " (TIMEOUT)" : "");
      } else if (op == 's') { usleep(atoi(line + 1) * 1000); }
      else if (op == '#') { line[strcspn(line, "\n")] = 0; say("%s", line); }
   }
   fclose(f); say("plan done: %d lines", n); return 0;
}

// bars <vram off> <width> <height> <pitch px>: horizontal colour bands (white, red, green, blue, grey), 32 lines of each
// repeated, written through the VRAM aperture: a quick way to see a second scan-out buffer on the monitor
static int bars(uint64_t off, int w, int h, int pitch) {
   static const uint32_t c[5] = {0xffffffff, 0xffff0000, 0xff00ff00, 0xff0000ff, 0xff808080};
   for (int y = 0; y < h; y++) {
      uint32_t v = c[(y / 32) % 5];
      if ((y / 32) % 2 == 1 && y % 32 > 3) continue;                // only every other band is filled completely
      for (int x = 0; x < w; x++) vw(off + ((uint64_t)y * pitch + x) * 4, v);
   }
   say("bars written at vram 0x%llx (%dx%d pitch %d)", (unsigned long long)off, w, h, pitch); return 0;
}

int main(int argc, char **argv) {
   if (argc < 2) { fprintf(stderr, "usage: dmubboot status | start <vbios.bin> | cmd <w0> <w1> ...\n"); return 2; }
   logfd = open("/Users/Shared/dmubboot.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
   if (open_kext()) return 1;
   if (!strcmp(argv[1], "status")) { status(); return 0; }
   if (!strcmp(argv[1], "start") && argc >= 3) return start(argv[2]);
   if (!strcmp(argv[1], "cmd") && argc >= 4) return cmd(argc - 2, argv + 2);
   if (!strcmp(argv[1], "run") && argc >= 3) return run(argv[2]);
   if (!strcmp(argv[1], "bars") && argc >= 6) return bars(strtoull(argv[2], NULL, 0), atoi(argv[3]), atoi(argv[4]), atoi(argv[5]));
   return 2;
}
