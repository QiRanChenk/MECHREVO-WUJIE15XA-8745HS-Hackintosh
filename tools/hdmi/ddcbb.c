// ddcbb: bit-banged I2C on the DDC2 pads (the HDMI port of the WUJIE15XA) through PhxBringup's debug selectors.
// The DCN hardware I2C engine resets this machine under macOS (first write to DC_I2C_DATA), so the DDC lines are driven
// as open-drain GPIOs instead: DC_GPIO_DDC2_MASK selects GPIO mode, _EN drives a line low (A stays 0), _Y reads it.
//   ddcbb edid [out.bin]            EDID from 0x50 (block 0 plus extensions)
//   ddcbb rd <addr7> <offset> <n>   e.g. SCDC: ddcbb rd 0x54 0x01 1
//   ddcbb wr <addr7> <offset> <value>
//   ddcbb vcp <code> [value]        DDC/CI: read or set a monitor control, e.g. brightness: ddcbb vcp 0x10 60
// build: clang -arch x86_64 -O2 -o ddcbb ddcbb.c -framework IOKit -framework CoreFoundation ; run as root, phxdebug=1
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define UC_TYPE 0x4E34384Eu
static io_connect_t conn;
static uint32_t rd(uint32_t reg) { uint64_t in[3] = {reg, 1, 0xFFFFFFFFull}; uint32_t v = 0; size_t sz = 4;
   IOConnectCallMethod(conn, 2, in, 3, NULL, 0, NULL, NULL, &v, &sz); return v; }
static void wr(uint32_t reg, uint32_t val) { uint64_t in[3] = {reg, val, 1}, out[1] = {0}; uint32_t n = 1;
   if (IOConnectCallScalarMethod(conn, 108, in, 3, out, &n) != KERN_SUCCESS) { n = 1; IOConnectCallScalarMethod(conn, 108, in, 2, out, &n); } }
enum { MASK = 0x5d94, A = 0x5d95, EN = 0x5d96, Y = 0x5d97 };
static uint32_t en;                       // bit 0 = SCL driven low, bit 8 = SDA driven low
static void dly(void) { usleep(20); }
static void scl(int hi) { if (hi) en &= ~1u; else en |= 1u; wr(EN, en); dly();
   if (hi) for (int i = 0; i < 2000 && !(rd(Y) & 1); i++) usleep(10); }        // clock stretching
static void sda(int hi) { if (hi) en &= ~0x100u; else en |= 0x100u; wr(EN, en); dly(); }
static int sda_in(void) { return (rd(Y) >> 8) & 1; }
static void start(void) { sda(1); scl(1); sda(0); scl(0); }
static void stop(void) { sda(0); scl(1); sda(1); }
static int txb(uint8_t b) { for (int i = 7; i >= 0; i--) { sda((b >> i) & 1); scl(1); scl(0); }
   sda(1); scl(1); int nack = sda_in(); scl(0); return nack; }
static uint8_t rxb(int ack) { uint8_t b = 0; sda(1); for (int i = 0; i < 8; i++) { scl(1); b = (b << 1) | sda_in(); scl(0); }
   sda(ack ? 0 : 1); scl(1); scl(0); sda(1); return b; }
static int i2c_read(uint8_t a7, uint8_t off, uint8_t *buf, int n) {
   start(); if (txb(a7 << 1)) { stop(); return -1; } if (txb(off)) { stop(); return -2; }
   start(); if (txb((a7 << 1) | 1)) { stop(); return -3; }
   for (int i = 0; i < n; i++) buf[i] = rxb(i < n - 1); stop(); return 0; }
static int i2c_write(uint8_t a7, uint8_t off, uint8_t v) {
   start(); int r = txb(a7 << 1) ? -1 : txb(off) ? -2 : txb(v) ? -3 : 0; stop(); return r; }
// DDC/CI (monitor control, I2C address 0x37): VCP feature get/set, e.g. 0x10 = brightness, 0x12 = contrast
static int ci_write(const uint8_t *p, int n) {     // p = payload after the length byte
   uint8_t chk = 0x6e ^ 0x51 ^ (uint8_t)(0x80 | n);
   start(); int r = txb(0x37 << 1) ? -1 : txb(0x51) ? -2 : txb((uint8_t)(0x80 | n)) ? -3 : 0;
   for (int i = 0; i < n && !r; i++) { chk ^= p[i]; if (txb(p[i])) r = -4; }
   if (!r && txb(chk)) r = -5;
   stop(); return r; }
static int vcp_get(uint8_t code, unsigned *cur, unsigned *max) {
   const uint8_t q[2] = { 0x01, code }; int r = ci_write(q, 2); if (r) return r;
   usleep(50000);
   uint8_t b[11]; start(); if (txb((0x37 << 1) | 1)) { stop(); return -6; }
   for (int i = 0; i < 11; i++) b[i] = rxb(i < 10); stop();
   uint8_t chk = 0x50; for (int i = 0; i < 10; i++) chk ^= b[i];
   if (chk != b[10] || b[2] != 0x02 || b[3] != 0 || b[4] != code) return -7;
   *max = b[6] << 8 | b[7]; *cur = b[8] << 8 | b[9]; return 0; }
static int vcp_set(uint8_t code, unsigned v) { const uint8_t q[4] = { 0x03, code, (uint8_t)(v >> 8), (uint8_t)v }; return ci_write(q, 4); }
int main(int argc, char **argv) {
   if (argc < 2) { fprintf(stderr, "usage: ddcbb edid [out] | rd <addr7> <off> <n> | wr <addr7> <off> <val> | vcp <code> [value]\n"); return 2; }
   io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("PhxBringup"));
   if (!svc || IOServiceOpen(svc, mach_task_self(), UC_TYPE, &conn)) { fprintf(stderr, "no PhxBringup\n"); return 1; }
   uint64_t hin[2] = {1, 0}, hout[4]; uint32_t hn = 4; IOConnectCallScalarMethod(conn, 0, hin, 2, hout, &hn);
   const uint32_t m0 = rd(MASK), a0 = rd(A), e0 = rd(EN);
   printf("DDC2: mask 0x%08x a 0x%x en 0x%x y 0x%x (HPD 0x%08x)\n", m0, a0, e0, rd(Y), rd(0x53dc));
   wr(A, 0); en = 0; wr(EN, 0); wr(MASK, m0 | 0x1111);          // GPIO mode for clock and data, pad drivers on
   usleep(3000);
   if ((rd(Y) & 0x101) != 0x101) printf("warning: lines not both high (y 0x%x)\n", rd(Y));
   int rc = 0;
   if (!strcmp(argv[1], "edid")) {
      static uint8_t e[128 * 8]; rc = i2c_read(0x50, 0, e, 128);
      int nb = 1;
      if (!rc) { nb += e[126] > 7 ? 7 : e[126]; for (int b = 1; b < nb && !rc; b++) rc = i2c_read(0x50, b * 128, e + b * 128, 128); }
      if (rc) printf("EDID read failed (%d)\n", rc);
      else {
         unsigned sum = 0; for (int i = 0; i < 128; i++) sum += e[i];
         printf("EDID: %d block(s), header %02x%02x%02x%02x%02x%02x%02x%02x, block 0 checksum %s\n", nb, e[0], e[1], e[2], e[3], e[4], e[5], e[6], e[7], (sum & 0xff) ? "BAD" : "ok");
         if (argc > 2) { FILE *f = fopen(argv[2], "wb"); if (f) { fwrite(e, 1, nb * 128, f); fclose(f); } }
      }
   } else if (!strcmp(argv[1], "rd") && argc >= 5) {
      uint8_t b[64]; int n = atoi(argv[4]); if (n > 64) n = 64;
      rc = i2c_read(strtoul(argv[2], 0, 0), strtoul(argv[3], 0, 0), b, n);
      if (rc) printf("read failed (%d)\n", rc); else { for (int i = 0; i < n; i++) printf("%02x ", b[i]); printf("\n"); }
   } else if (!strcmp(argv[1], "wr") && argc >= 5) {
      rc = i2c_write(strtoul(argv[2], 0, 0), strtoul(argv[3], 0, 0), strtoul(argv[4], 0, 0));
      printf("write %s (%d)\n", rc ? "failed" : "ok", rc);
   }
   else if (!strcmp(argv[1], "vcp") && argc >= 3) {
      const uint8_t code = (uint8_t)strtoul(argv[2], 0, 0); unsigned cur = 0, max = 0;
      if (argc >= 4) { rc = vcp_set(code, (unsigned)strtoul(argv[3], 0, 0)); printf("vcp 0x%02x set %s (%d)\n", code, rc ? "failed" : "ok", rc); }
      else { for (int t = 0; t < 3 && (rc = vcp_get(code, &cur, &max)); t++) usleep(100000);
             if (rc) printf("vcp 0x%02x read failed (%d)\n", code, rc); else printf("vcp 0x%02x = %u max %u\n", code, cur, max); }
   }
   wr(EN, e0); wr(A, a0); wr(MASK, m0);
   return rc ? 1 : 0;
}
