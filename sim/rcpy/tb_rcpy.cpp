// SPDX-License-Identifier: GPL-3.0-or-later
// Plays a program copying text rasters line after line, as Strider does before its title: the start
// written (the write held while the copy is busy, as the board's iowait holds it), a wait for the
// next H-sync, then the stop written until busy reads clear. The renderer fills a text row a line.
// The timings are drawn at random from a seed; a start held over 1 ms is the machine stopped.
#include <verilated.h>
#include <cstdio>
#include <cstdlib>
#include <random>
#include "Vtb_rcpy.h"

static Vtb_rcpy *t;
static unsigned long n40;                 // clk40 cycles
static int line_clk = 2560;               // the renderer's line, 64 us
static unsigned row;

static void clk40() {                     // one cycle of clk40: four edges of clk80
  t->ce = (n40 % 4) == 0;                 // the board's sys_ce: one clock in four
  if (n40 % line_clk == 0) { row = (row + 1) & 0x3FF; t->t_addr = row << 6; }
  for (int i = 0; i < 2; i++) {
    t->clk80 = !t->clk80; if (t->clk80) t->clk40 = !t->clk40; t->eval();
    t->clk80 = !t->clk80; t->eval();
  }
  n40++;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  unsigned seed = argc > 1 ? atoi(argv[1]) : 1;
  int lines = argc > 2 ? atoi(argv[2]) : 3000;
  std::mt19937 rng(seed);
  auto rnd = [&](int lo, int hi) { return std::uniform_int_distribution<int>(lo, hi)(rng); };
  t = new Vtb_rcpy;
  t->rstn = 0; t->start = 0; t->stop = 0; t->t_rd = 0; t->t_addr = 0;
  for (int i = 0; i < 20; i++) clk40();
  t->rstn = 1;
  while (!t->t_ready) clk40();
  t->t_rd = 1;
  int stops_busy = 0, longest = 0;
  for (int l = 0; l < lines; l++) {
    // the start: AS and the write's strobe together, IO_ack registered a clock after the I/O decode's
    // first clock, low while iowait (start and busy); the CPU samples DTACK one clock in four
    int phase = rnd(0, 3);
    while ((n40 & 3) != (unsigned)phase) clk40();
    t->start = 1;
    int held = 0; bool io_ack = false, iowait_q = false;
    for (;;) {
      bool iowait = t->start && t->busy;
      if (held >= 2) io_ack = !iowait_q;
      iowait_q = iowait;
      clk40(); held++;
      if (io_ack && ((n40 & 3) == (unsigned)((phase + 2) & 3))) break;
      if (held > 40000) {
        printf("HANG seed %u line %d: the start held 1 ms, busy %d (stops that found it busy so far: %d)\n",
               seed, l, t->busy, stops_busy);
        return 1;
      }
    }
    if (held > longest) longest = held;
    if (getenv("RC_DEBUG")) {                 // each line's figures: the start's hold, busy after it
      unsigned long s0 = n40;
      while (t->busy && n40 - s0 < 100000) clk40();
      printf("line %d: start held %d clocks, busy %lu clocks after\n", l, held, n40 - s0);
    }
    for (int i = 0; i < 6; i++) clk40();      // the rest of the cycle, the strobe still up
    t->start = 0;
    for (int i = rnd(800, 5200); i > 0; i--) clk40();   // the H-sync waits, 20-130 us
    for (;;) {                                // bclr #3 / bne: read busy, write the stop
      for (int i = 0; i < 20; i++) clk40();
      bool was = t->busy;
      for (int i = 0; i < 30; i++) clk40();
      t->stop = 1; for (int i = 0; i < 6; i++) clk40(); t->stop = 0;
      if (!was) break;
      stops_busy++;
      for (int i = 0; i < 40; i++) clk40();
    }
    for (int i = rnd(100, 300); i > 0; i--) clk40();
  }
  printf("seed %u: %d lines, no hang; stops that found it busy %d; longest start %d clocks; violations %u\n",
         seed, lines, stops_busy, longest, t->violations);
  return 0;
}
