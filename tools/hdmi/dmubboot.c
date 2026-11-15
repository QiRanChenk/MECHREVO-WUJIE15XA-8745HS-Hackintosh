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
static int quiet;   // AUX transactions: thousands of writes, not logged one by one
static void wr(uint32_t reg, uint32_t val, const char *name) {
   if (!quiet) say("w %-28s 0x%05x = 0x%08x", name, reg, val);
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

static int cmdw(const uint64_t *w);
static int cmd(int argc, char **argv) {
   uint64_t w[8] = {0};
   for (int i = 0; i < argc && i < 8; i++) w[i] = strtoull(argv[i], NULL, 16);
   return cmdw(w);
}
static int cmdw(const uint64_t *w) {
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

// ---- DisplayPort on the USB-C port (UNIPHY_C, DIG2/DP2, DP_AUX2 on the DDC3 pads, HPD at 0x53e4) -------------------
// The type-C side (EC / PD controller) enters DP alt mode by itself; the GPU sees HPD and the AUX channel. AUX is the
// software engine of DP_AUX2, driven register by register as Linux's dce_aux does; the PHY, its PLL and the lane
// drive are set by the DMUB firmware through DIG1_TRANSMITTER_CONTROL (ENABLE, SETUP_VSEMPH, DISABLE).
enum { AUX_CONTROL = 0x5448, AUX_SW_CONTROL = 0x5449, AUX_ARB_CONTROL = 0x544a, AUX_INT_CONTROL = 0x544b, AUX_SW_STATUS = 0x544c,
       AUX_SW_DATA = 0x544e, AUX_RX_CONTROL1 = 0x5453, DDC3_MASK = 0x5d98, DDC3_A = 0x5d99, DDC3_EN = 0x5d9a, AUX_CTRL_5 = 0x5ddd,
       HPD_USBC = 0x53e4 };
static void aux_init(void) {
   quiet = 1;
   wr(DDC3_MASK, 0xcf411010, ""); wr(DDC3_A, 0, ""); wr(DDC3_EN, 0, ""); wr(AUX_CTRL_5, rd(AUX_CTRL_5) & ~0x4000u, "");
   if (rd(AUX_CONTROL) != 0x01240001) wr(AUX_CONTROL, 0x01240001, "");
   wr(AUX_RX_CONTROL1, 0x00004510, "");
   quiet = 0;
}
// one AUX transaction; returns the reply byte (>> 4: 0 ACK, 1 NACK, 2 DEFER, 4 I2C NACK, 8 I2C DEFER), < 0 on failure
static int aux_xfer(unsigned cmd4, uint32_t addr, const uint8_t *w, int wlen, int rlen, uint8_t *r, int *got, int addr_only) {
   int rc = -1; quiet = 1; if (got) *got = 0;
   wr(AUX_ARB_CONTROL, 0x10000, "");
   int i; for (i = 0; i < 200 && (rd(AUX_ARB_CONTROL) & 0xc) != 0x4; i++) usleep(50);
   if (i == 200) { quiet = 0; say("aux: engine not granted (0x%x)", rd(AUX_ARB_CONTROL)); return -2; }
   wr(AUX_INT_CONTROL, 0x42, "");
   for (i = 0; i < 200 && (rd(AUX_SW_STATUS) & 1); i++) usleep(50);
   const int n = 3 + (addr_only ? 0 : 1) + wlen;
   wr(AUX_SW_CONTROL, (uint32_t)n << 16, "");
   wr(AUX_SW_DATA, 0x80000000u | ((cmd4 << 4 | ((addr >> 16) & 0xf)) << 8), "");
   wr(AUX_SW_DATA, ((addr >> 8) & 0xff) << 8, ""); wr(AUX_SW_DATA, (addr & 0xff) << 8, "");
   if (!addr_only) wr(AUX_SW_DATA, (uint32_t)((wlen ? wlen : rlen) - 1) << 8, "");
   for (i = 0; i < wlen; i++) wr(AUX_SW_DATA, (uint32_t)w[i] << 8, "");
   wr(AUX_SW_CONTROL, (uint32_t)n << 16 | 1, "");
   uint32_t st = 0; for (i = 0; i < 2000; i++) { st = rd(AUX_SW_STATUS); if (st & 1) break; usleep(10); }
   if (!(st & 1)) rc = -3;                       // no DONE
   else if (st & 0x200) rc = -4;                 // HPD_DISCON
   else if (st & 0x00f0f0f0u & ~0u && ((st >> 24) & 0x1f) == 0) rc = -5;   // error bits and no reply
   else {
      const int cnt = (st >> 24) & 0x1f;
      wr(AUX_SW_DATA, 0x80000001u, "");
      rc = (rd(AUX_SW_DATA) >> 8) & 0xff;
      for (i = 0; i + 1 < cnt && i < 16; i++) { const uint8_t b = (rd(AUX_SW_DATA) >> 8) & 0xff; if (r) r[i] = b; }
      if (got) *got = i;
   }
   wr(AUX_ARB_CONTROL, 0x20004, "");
   quiet = 0;
   if (rc < 0) say("aux: transaction failed (%d, status 0x%08x)", rc, st);
   return rc;
}
static int dpcd_rd(uint32_t addr, uint8_t *b, int n) {
   for (int done = 0; done < n; ) {
      int k = n - done > 16 ? 16 : n - done, got = 0, rep = -1;
      for (int t = 0; t < 8; t++) { rep = aux_xfer(9, addr + done, NULL, 0, k, b + done, &got, 0); if (rep < 0 || (rep >> 4) != 2) break; usleep(1000); }
      if (rep < 0 || (rep >> 4) != 0 || got <= 0) { say("dpcd read 0x%05x failed (reply 0x%02x)", addr + done, rep); return -1; }
      done += got;
   }
   return 0;
}
static int dpcd_wr(uint32_t addr, const uint8_t *b, int n) {
   int rep = -1;
   for (int t = 0; t < 8; t++) { rep = aux_xfer(8, addr, b, n, 0, NULL, NULL, 0); if (rep < 0 || (rep >> 4) != 2) break; usleep(1000); }
   if (rep < 0 || (rep >> 4) != 0) { say("dpcd write 0x%05x failed (reply 0x%02x)", addr, rep); return -1; }
   return 0;
}
static int dpcd_wr1(uint32_t addr, uint8_t v) { return dpcd_wr(addr, &v, 1); }
// EDID through I2C-over-AUX (address 0x50), 16 bytes a transaction; DEFERs are repeated
static uint32_t i2c_addr = 0x50;
static int i2c_aux(unsigned cmd4, const uint8_t *w, int wlen, int rlen, uint8_t *r, int *got, int addr_only) {
   int rep = -1;
   for (int t = 0; t < 30; t++) { rep = aux_xfer(cmd4, i2c_addr, w, wlen, rlen, r, got, addr_only); if (rep < 0 || !((rep >> 4) & 0xa)) break; usleep(800); }
   return rep;
}
// DDC/CI (monitor control, I2C address 0x37) through I2C-over-AUX: read or set a VCP feature (0x10 brightness, 0x62 volume)
static int aux_vcp(unsigned code, int set, unsigned val) {
   aux_init(); i2c_addr = 0x37;
   uint8_t q[8]; int n;
   if (set) { q[0] = 0x51; q[1] = 0x84; q[2] = 0x03; q[3] = (uint8_t)code; q[4] = (uint8_t)(val >> 8); q[5] = (uint8_t)val; n = 6; }
   else { q[0] = 0x51; q[1] = 0x82; q[2] = 0x01; q[3] = (uint8_t)code; n = 4; }
   uint8_t chk = 0x6e; for (int i = 0; i < n; i++) chk ^= q[i]; q[n++] = chk;
   int rc = i2c_aux(0, q, n, 0, NULL, NULL, 0);
   if (set) { printf("vcp 0x%02x set %s (%d)\n", code, rc ? "failed" : "ok", rc); i2c_addr = 0x50; return rc ? 1 : 0; }
   if (rc) { printf("vcp 0x%02x read failed (%d)\n", code, rc); i2c_addr = 0x50; return 1; }
   usleep(50000);
   uint8_t b[16]; int got = 0;
   rc = i2c_aux(1, NULL, 0, 11, b, &got, 0);
   i2c_addr = 0x50;
   chk = 0x50; for (int i = 0; i < 10; i++) chk ^= b[i];
   if (rc || got < 11 || chk != b[10] || b[2] != 0x02 || b[3] != 0 || b[4] != code) { printf("vcp 0x%02x read failed (%d, %d bytes)\n", code, rc, got); return 1; }
   printf("vcp 0x%02x = %u max %u\n", code, b[8] << 8 | b[9], b[6] << 8 | b[7]);
   return 0;
}
static int aux_edid(const char *path) {
   static uint8_t e[1024]; int blocks = 1;
   aux_init();
   for (int b = 0; b < blocks && b < 8; b++) {
      uint8_t off = (uint8_t)(b * 128);
      if (i2c_aux(4, &off, 1, 0, NULL, NULL, 0) != 0) { say("EDID: offset write for block %d not acknowledged", b); return 1; }
      for (int done = 0; done < 128; ) {
         int got = 0; if (i2c_aux(5, NULL, 0, 16, e + b * 128 + done, &got, 0) != 0 || got <= 0) { say("EDID: read failed at %d", b * 128 + done); return 1; }
         done += got;
      }
      i2c_aux(1, NULL, 0, 0, NULL, NULL, 1);     // address-only, no MOT: I2C stop
      if (b == 0) blocks += e[126];
   }
   unsigned sum = 0; for (int i = 0; i < 128; i++) sum += e[i];
   say("EDID: %d block(s), header %02x%02x%02x%02x%02x%02x%02x%02x, block 0 checksum %s", blocks, e[0], e[1], e[2], e[3], e[4], e[5], e[6], e[7], (sum & 0xff) ? "BAD" : "ok");
   if (path) { FILE *f = fopen(path, "wb"); if (f) { fwrite(e, 1, (size_t)blocks * 128, f); fclose(f); } }
   return (sum & 0xff) ? 1 : 0;
}
static int tx_cmd(unsigned action, unsigned laneset, unsigned lanes, unsigned rate) {
   // DIG1_TRANSMITTER_CONTROL for UNIPHY_C: byte 4 phy id 2, 5 action, 6 dig mode (DP = 0) / lane set, 7 lane count; word 1: symbol clock in 10 kHz
   const uint64_t sym = (uint64_t)rate * 2700;
   uint64_t w[8] = {0};
   w[0] = 0x000000023c000180ull | (uint64_t)action << 40 | (uint64_t)laneset << 48 | (uint64_t)lanes << 56;
   w[1] = action == 1 ? 0xf400000300000000ull | sym : action == 11 ? 0xf613000300000000ull | sym : 0xf413000300000000ull;
   if (action == 0) w[0] = 0x000000023c000180ull;
   return cmdw(w);
}
// dptrain [lanes rate]: PHY on and DP 1.2 link training (clock recovery with TPS1, channel equalization with TPS3 or
// TPS2, drive levels as the sink asks), falling back to lower link rates. Leaves the link sending idle pattern.
static int dp_train(int want_lanes, int want_rate) {
   uint8_t caps[16];
   aux_init();
   if (!(rd(HPD_USBC) & 0x10)) { say("no DP sink on the USB-C port (HPD 0x53e4 = 0x%08x)", rd(HPD_USBC)); return 1; }
   if (dpcd_rd(0x000, caps, 16)) return 1;
   int lanes = caps[2] & 0x1f, rate = caps[1]; const int enh = caps[2] >> 7, tps3 = (caps[2] >> 6) & 1;
   say("DPCD rev %x.%x, max rate 0x%02x, max lanes %d, enhanced framing %d, TPS3 %d, training interval 0x%02x", caps[0] >> 4, caps[0] & 15, rate, lanes, enh, tps3, caps[14]);
   if (lanes > 2) lanes = 2;                      // a USB-C dock/adapter that shares the cable with USB 3 carries two lanes; four is not tried
   if (rate > 0x14) rate = 0x14;
   if (want_lanes && want_lanes < lanes) lanes = want_lanes;
   if (want_rate && want_rate < rate) rate = want_rate;
   static const int rates[] = { 0x14, 0x0a, 0x06 };
   for (unsigned ri = 0; ri < 3; ri++) {
      if (rates[ri] > rate) continue;
      const int lr = rates[ri];
      say("link training: %d lane(s) at rate 0x%02x", lanes, lr);
      tx_cmd(0, 0, 0, 0); usleep(20000);
      wr(0x57cb, (uint32_t)lanes - 1, "DP2_DP_CONFIG"); wr(0x57de, 0x0101ff10, "DP2_DP_DPHY_SCRAM_CNTL");
      if (tx_cmd(1, 0, (unsigned)lanes, (unsigned)lr)) return 2;
      int ok = -1; for (int t = 0; t < 10 && (ok = dpcd_wr1(0x600, 1)); t++) usleep(1000);
      if (ok) return 1;
      dpcd_wr1(0x102, 0); dpcd_wr1(0x108, 1); dpcd_wr1(0x107, 0x10);
      dpcd_wr1(0x101, (uint8_t)((enh ? 0x80 : 0) | lanes)); dpcd_wr1(0x100, (uint8_t)lr);
      int vs = 0, pe = 0, pass = 0; uint8_t st[6];
      // clock recovery
      wr(0x57d8, 0, "DP2_DP_DPHY_TRAINING_PATTERN_SEL"); wr(0x57c8, 0, "DP2_DP_LINK_CNTL"); wr(0x57d7, 0, "DP2_DP_DPHY_CNTL"); wr(0x57dd, 0x7fffff00, "DP2_DP_DPHY_PRBS_CNTL");
      for (int it = 0, same = 0; it < 10 && !pass; it++) {
         const uint8_t ls = (uint8_t)(vs | (vs == 3 ? 4 : 0) | pe << 3 | (pe == 3 ? 0x20 : 0));
         for (int l = 0; l < lanes; l++) tx_cmd(11, (unsigned)(vs | pe << 3), (unsigned)lanes, (unsigned)lr);
         uint8_t t[5] = { 0x21, ls, ls, ls, ls };
         if (dpcd_wr(0x102, t, 1 + lanes)) return 1;
         usleep(2000);
         if (dpcd_rd(0x202, st, 6)) return 1;
         say("  CR  VS %d PE %d: status %02x %02x %02x, adjust %02x %02x", vs, pe, st[0], st[1], st[2], st[4], st[5]);
         int done = 1; for (int l = 0; l < lanes; l++) if (!((st[l / 2] >> (l % 2 * 4)) & 1)) done = 0;
         if (done) { pass = 1; break; }
         int nvs = 0, npe = 0;
         for (int l = 0; l < lanes; l++) { const int a = (st[4 + l / 2] >> (l % 2 * 4)) & 15; if ((a & 3) > nvs) nvs = a & 3; if ((a >> 2) > npe) npe = a >> 2; }
         if (nvs + npe > 3) npe = 3 - nvs;
         same = (nvs == vs) ? same + 1 : 0;
         if (same >= 5 || (vs == 3 && nvs == 3)) break;
         vs = nvs; pe = npe;
      }
      if (pass) {      // channel equalization
         pass = 0;
         wr(0x57d8, tps3 ? 2 : 1, "DP2_DP_DPHY_TRAINING_PATTERN_SEL"); wr(0x57c8, 0, "DP2_DP_LINK_CNTL"); wr(0x57d7, 0, "DP2_DP_DPHY_CNTL"); wr(0x57dd, 0x7fffff00, "DP2_DP_DPHY_PRBS_CNTL");
         for (int it = 0; it < 6 && !pass; it++) {
            const uint8_t ls = (uint8_t)(vs | (vs == 3 ? 4 : 0) | pe << 3 | (pe == 3 ? 0x20 : 0));
            for (int l = 0; l < lanes; l++) tx_cmd(11, (unsigned)(vs | pe << 3), (unsigned)lanes, (unsigned)lr);
            uint8_t t[5] = { (uint8_t)(tps3 ? 0x23 : 0x22), ls, ls, ls, ls };
            if (dpcd_wr(0x102, t, 1 + lanes)) return 1;
            usleep((caps[14] & 0x7f) ? (caps[14] & 0x7f) * 4000 : 1000);
            if (dpcd_rd(0x202, st, 6)) return 1;
            say("  EQ  VS %d PE %d: status %02x %02x %02x, adjust %02x %02x", vs, pe, st[0], st[1], st[2], st[4], st[5]);
            int cr = 1, eq = 1;
            for (int l = 0; l < lanes; l++) { const int s = (st[l / 2] >> (l % 2 * 4)) & 15; if (!(s & 1)) cr = 0; if ((s & 7) != 7) eq = 0; }
            if (!cr) break;
            if (eq && (st[2] & 1)) { pass = 1; break; }
            int nvs = 0, npe = 0;
            for (int l = 0; l < lanes; l++) { const int a = (st[4 + l / 2] >> (l % 2 * 4)) & 15; if ((a & 3) > nvs) nvs = a & 3; if ((a >> 2) > npe) npe = a >> 2; }
            if (nvs + npe > 3) npe = 3 - nvs;
            vs = nvs; pe = npe;
         }
      }
      dpcd_wr1(0x102, 0);
      if (pass) {
         wr(0x57cf, 0, "DP2_DP_DPHY_INTERNAL_CTRL"); wr(0x57d3, enh ? 0x10102000 : 0x00102000, "DP2_DP_LINK_FRAMING_CNTL"); wr(0x57de, 0x0101ff10, "DP2_DP_DPHY_SCRAM_CNTL");
         wr(0x57c8, 0x10, "DP2_DP_LINK_CNTL training complete"); wr(0x57d7, 0, "DP2_DP_DPHY_CNTL"); wr(0x57dd, 0x7fffff00, "DP2_DP_DPHY_PRBS_CNTL");
         dpcd_rd(0x200, st, 6);
         say("LINK UP: %d lane(s), rate 0x%02x, VS %d PE %d; sink status %02x %02x %02x %02x", lanes, lr, vs, pe, st[0], st[1], st[2], st[3]);
         printf("link %d %d\n", lanes, lr);
         return 0;
      }
      say("training failed at rate 0x%02x", lr);
   }
   tx_cmd(0, 0, 0, 0);
   return 3;
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
   if (!strcmp(argv[1], "aux") && argc >= 3) {
      aux_init();
      if (!strcmp(argv[2], "hpd")) { say("HPD 0x53e4 = 0x%08x (%s)", rd(HPD_USBC), (rd(HPD_USBC) & 0x10) ? "DP sink present" : "nothing"); return (rd(HPD_USBC) & 0x10) ? 0 : 1; }
      if (!strcmp(argv[2], "edid")) return aux_edid(argc > 3 ? argv[3] : NULL);
      if (!strcmp(argv[2], "vcp") && argc >= 4) return aux_vcp((unsigned)strtoul(argv[3], 0, 0), argc > 4, argc > 4 ? (unsigned)strtoul(argv[4], 0, 0) : 0);
      if (!strcmp(argv[2], "rd") && argc >= 5) {
         uint8_t b[64]; int n = atoi(argv[4]); if (n > 64) n = 64;
         if (dpcd_rd((uint32_t)strtoul(argv[3], 0, 0), b, n)) return 1;
         for (int i = 0; i < n; i++) printf("%02x ", b[i]); printf("\n"); return 0;
      }
      if (!strcmp(argv[2], "wr") && argc >= 5) {
         uint8_t b[16]; int n = 0; for (int i = 4; i < argc && n < 16; i++) b[n++] = (uint8_t)strtoul(argv[i], 0, 16);
         return dpcd_wr((uint32_t)strtoul(argv[3], 0, 0), b, n) ? 1 : 0;
      }
   }
   if (!strcmp(argv[1], "dptrain")) return dp_train(argc > 2 ? atoi(argv[2]) : 0, argc > 3 ? (int)strtoul(argv[3], 0, 0) : 0);
   if (!strcmp(argv[1], "dpoff")) { aux_init(); if (rd(HPD_USBC) & 0x10) dpcd_wr1(0x600, 2); return tx_cmd(0, 0, 0, 0); }
   if (!strcmp(argv[1], "bars") && argc >= 6) return bars(strtoull(argv[2], NULL, 0), atoi(argv[3]), atoi(argv[4]), atoi(argv[5]));
   return 2;
}
