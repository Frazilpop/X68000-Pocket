// SPDX-License-Identifier: GPL-3.0-or-later
// Checks gvram_psram and tvram_psram against their chips' models: the boot's calibration, the CPU's
// reads and writes of every width, a row filled into a line cache, a CPU write reaching a cached row,
// a fast clear of one page, and a raster copy. Prints each and fails on the first wrong word.
#include <verilated.h>
#include <cstdio>
#include <cstdlib>
#include "Vtb_vram.h"

static Vtb_vram *t;
static vluint64_t ticks;

static void half() {            // a half period of clk80: 6.25 ns
  t->clk80 = !t->clk80;
  if (t->clk80) t->clk40 = !t->clk40;
  t->eval();
  ticks++;
}
static void clk40() { do { half(); } while (!(t->clk40 && t->clk80)); }   // to the next rising clk40
static void wait(int n) { for (int i = 0; i < n; i++) clk40(); }
static void check(const char *what, unsigned got, unsigned want) {
  if (got != want) { printf("FAIL %s: got %04x want %04x at %.1f us\n", what, got, want, ticks * 0.00625); exit(1); }
}
template <class F> static void until(const char *what, F f, int limit = 200000) {
  for (int i = 0; i < limit; i++) { if (f()) return; clk40(); }
  printf("FAIL timeout: %s\n", what); exit(1);
}

// ---- graphics CPU
static void gdone(bool rd) {
  int waited = 0;
  until("graphics CPU ack", [&] { waited++; return t->gc_ack; });
  (void)rd;
  t->gc_rd = 0; t->gc_wr = 0; t->gc_rmw = 0;
  clk40(); clk40();
}
static void gwr(unsigned a, unsigned d, unsigned be = 3) { t->gc_addr = a; t->gc_wdat = d; t->gc_wr = be; clk40(); gdone(false); }
static void grmw(unsigned a, unsigned d, unsigned m) { t->gc_addr = a; t->gc_wdat = d; t->gc_mask = m; t->gc_rmw = 3; clk40(); gdone(false); }
static unsigned grd(unsigned a) { t->gc_addr = a; t->gc_rd = 1; clk40(); until("gread", [] { return t->gc_ack; }); unsigned v = t->gc_rdat; t->gc_rd = 0; clk40(); clk40(); return v; }
// ---- text CPU
static void tdone() { until("text CPU ack", [] { return t->tc_ack; }); t->tc_rd = 0; t->tc_wr = 0; t->tc_rmw = 0; clk40(); clk40(); }
static void twr(unsigned a, unsigned d, unsigned be = 3) { t->tc_addr = a; t->tc_wdat = d; t->tc_wr = be; clk40(); tdone(); }
static void trmw(unsigned a, unsigned d, unsigned m) { t->tc_addr = a; t->tc_wdat = d; t->tc_mask = m; t->tc_rmw = 3; clk40(); tdone(); }
static unsigned trd(unsigned a) { t->tc_addr = a; t->tc_rd = 1; clk40(); until("tread", [] { return t->tc_ack; }); unsigned v = t->tc_rdat; t->tc_rd = 0; clk40(); clk40(); return v; }

static unsigned gq(unsigned a) { t->g_addr = a; clk40(); clk40(); return t->g_q; }

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  t = new Vtb_vram;
  t->rstn = 0; t->hcomp = 0; t->g_rd = 0; t->g_clear = 0; t->gc_wr = 0; t->gc_rd = 0; t->gc_rmw = 0;
  t->tc_wr = 0; t->tc_rd = 0; t->tc_rmw = 0; t->t_rd = 0; t->cpy_req = 0;
  wait(20);
  t->rstn = 1;
  until("the chips' boot", [] { return t->g_ready && t->t_ready; }, 2000000);
  printf("boot: %.0f us; graphics wr %d rd %d edge %d, text wr %d rd %d edge %d; failed %d %d\n", ticks * 0.00625,
         (t->g_lat >> 4) & 7, t->g_lat & 7, (t->g_lat >> 3) & 1, (t->t_lat >> 4) & 7, t->t_lat & 7, (t->t_lat >> 3) & 1, t->g_fail, t->t_fail);
  if (t->g_fail || t->t_fail) { puts("FAIL calibration"); return 1; }

  // CPU, every width
  gwr(0x12345, 0xA5C3);            check("word", grd(0x12345), 0xA5C3);
  gwr(0x12345, 0x7700, 2);         check("high byte", grd(0x12345), 0x77C3);
  gwr(0x12345, 0x0011, 1);         check("low byte", grd(0x12345), 0x7711);
  grmw(0x12345, 0xFFFF, 0x00F0);   check("nibble", grd(0x12345), 0x77F1);
  grmw(0x12345, 0x0000, 0xFF00);   check("byte mask", grd(0x12345), 0x00F1);
  gwr(0x12344, 0x1111);            check("the word before stands", grd(0x12345), 0x00F1);
  puts("graphics CPU: word, bytes, nibble, masks");

  // a row into a line cache, whole
  for (int i = 0; i < 512; i += 37) gwr((0x55 << 9) | i, 0x1000 + i);
  gwr((0x55 << 9) | 511, 0xBEEF);
  t->g_addr = 0x55 << 9; t->g_rd = 1;
  clk40();
  wait(32 * 32);                    // 32 bursts, at the slowest latency tried
  for (int i = 0; i < 512; i += 37) check("filled word", gq((0x55 << 9) | i), 0x1000 + i);
  check("the row's last word", gq((0x55 << 9) | 511), 0xBEEF);
  puts("graphics fill: 512 words");

  // a CPU write reaches the cached row
  gwr((0x55 << 9) | 37, 0xCAFE);   check("write through, word", gq((0x55 << 9) | 37), 0xCAFE);
  gwr((0x55 << 9) | 37, 0x00D0, 1);check("write through, byte", gq((0x55 << 9) | 37), 0xCAD0);
  grmw((0x55 << 9) | 37, 0xFFFF, 0x0F00); check("write through, nibble", gq((0x55 << 9) | 37), 0xCFD0);
  puts("graphics write-through");

  // a late fill says so
  t->g_addr = 0x66 << 9;
  clk40(); clk40(); clk40();
  t->hcomp = 1; clk40(); t->hcomp = 0;
  check("late flag", t->g_late, 1);
  wait(32 * 32);
  t->g_rd = 0;
  puts("graphics fill late: flagged");

  // fast clear of one page's nibbles, then of a whole byte
  for (int i = 0; i < 512; i += 13) gwr((0x77 << 9) | i, 0xABCD);
  t->g_caddr = 0x77 << 1; t->g_clear = 0x2;
  clk40();
  wait(32 * 64);
  t->g_clear = 0;
  for (int i = 0; i < 512; i += 13) check("clear page 1's nibble", grd((0x77 << 9) | i), 0xAB0D);
  t->g_caddr = (0x77 << 1) + 2; t->g_clear = 0xC;   // the next row, pages 2 and 3
  for (int i = 0; i < 512; i += 13) { t->g_clear = 0; gwr((0x78 << 9) | i, 0xABCD); }
  t->g_clear = 0xC;
  clk40();
  wait(32 * 32);
  t->g_clear = 0;
  for (int i = 0; i < 512; i += 13) check("clear two pages' byte", grd((0x78 << 9) | i), 0x00CD);
  puts("graphics fast clear: a nibble, a byte");

  // text: CPU, per plane
  for (int p = 0; p < 4; p++) twr((0x1234 << 2) | p, 0x1100 * (p + 1) + p);
  for (int p = 0; p < 4; p++) check("text plane", trd((0x1234 << 2) | p), 0x1100 * (p + 1) + p);
  twr((0x1234 << 2) | 1, 0x5A00, 2); check("text byte", trd((0x1234 << 2) | 1), 0x5A01);
  trmw((0x1234 << 2) | 1, 0xFFFF, 0x0FF0); check("text mask", trd((0x1234 << 2) | 1), 0x5FF1);
  puts("text CPU: planes, byte, mask");

  // a text row into the caches
  for (int p = 0; p < 4; p++) for (int i = 0; i < 64; i += 5) twr((((0x123 << 6) | i) << 2) | p, 0x2000 * p + i);
  t->t_addr = 0x123 << 6; t->t_rd = 1;
  clk40();
  wait(16 * 32);
  for (int i = 0; i < 64; i += 5) {
    t->t_addr = (0x123 << 6) | i; clk40(); clk40();
    check("text fill 0", t->t_q0, i); check("text fill 1", t->t_q1, 0x2000 + i);
    check("text fill 2", t->t_q2, 0x4000 + i); check("text fill 3", t->t_q3, 0x6000 + i);
  }
  twr(((0x123 << 6 | 5) << 2) | 2, 0xFACE);
  t->t_addr = (0x123 << 6) | 5; clk40(); clk40();
  check("text write through", t->t_q2, 0xFACE);
  t->t_rd = 0;
  puts("text fill and write-through");

  // raster copy: 32 words of two planes, row 0x40 to row 0x41
  for (int p = 0; p < 4; p++) for (int i = 0; i < 32; i++) twr((((0x40 << 5) | i) << 2) | p, 0x3000 + p * 0x100 + i);
  t->cpy_src = 0x40; t->cpy_dst = 0x41; t->cpy_plane = 0x5; t->cpy_req = 1;
  unsigned ack0 = t->cpy_ack;
  clk40();
  until("raster copy", [&] { return t->cpy_ack != ack0; });
  t->cpy_req = 0; clk40(); clk40();
  for (int i = 0; i < 32; i++) {
    check("copied, plane 0", trd(((0x41 << 5) | i) << 2 | 0), 0x3000 + i);
    check("not copied, plane 1", trd(((0x41 << 5) | i) << 2 | 1), 0);
    check("copied, plane 2", trd(((0x41 << 5) | i) << 2 | 2), 0x3200 + i);
  }
  puts("raster copy: two planes of four");

  check("model's violations", t->violations, 0);
  printf("OK, %.0f us\n", ticks * 0.00625);
  return 0;
}
