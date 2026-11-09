// SPDX-License-Identifier: GPL-3.0-or-later
// jt51 and IKAOPM fed one game's FM writes at the times MAME made them (tools/mame_x68k_sound.lua's
// writes.txt), for tools/pocket/compare_fm.py to set beside MAME's own YM2151 samples.
//
//   build/sound/opm_bench/run WRITES OUT_DIR [SECONDS [exact]]
//
// Writes OUT_DIR/jt51.s16 (left, right, xleft, xright) and OUT_DIR/ikaopm.s16 (L, R, L_EX, R_EX), a
// frame per sample each chip marks, and OUT_DIR/bench.txt with the time of each file's first sample.
// A write holds chip select and write low for 1 us, as the board's 68000 does through its I/O wait.
// MAME's YM2151 takes a write at the next of its samples, so each write here waits for the start
// of the 62.5 kHz sample it would land in there (640 clocks a sample, from time 0); several in one
// sample go one after another, and each waits for both chips' busy flags to fall, as the game
// polls them: MAME's YM2151 is ready again sooner than IKAOPM (a cycle-true chip loses a data write
// that a new address write overtakes), so its times alone are too close for it. "exact" puts each
// at the time MAME logged instead, with no wait. The chips are held in reset for the first millisecond.
#include <verilated.h>
#include "Vtb_opm.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>

struct W { double us; int a0; int d; };

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "run WRITES OUT_DIR [SECONDS]\n"); return 2; }
    double secs = argc > 3 ? atof(argv[3]) : 1e9;
    bool exact = argc > 4 && std::string(argv[4]) == "exact";
    std::vector<W> ws;
    FILE *f = fopen(argv[1], "r");
    if (!f) { perror(argv[1]); return 2; }
    char line[128];
    while (fgets(line, sizeof line, f)) {
        double us; unsigned a, d;
        if (sscanf(line, "%lf %x %x", &us, &a, &d) != 3) continue;
        if (a != 0xe90001 && a != 0xe90003) continue;
        ws.push_back({us, a == 0xe90003, (int)d});
    }
    fclose(f);
    if (!ws.empty() && ws.back().us * 1e-6 < secs) secs = ws.back().us * 1e-6 + 2.0;
    std::string out = argv[2];
    FILE *fj = fopen((out + "/jt51.s16").c_str(), "wb"), *fi = fopen((out + "/ikaopm.s16").c_str(), "wb");
    if (!fj || !fi) { perror(out.c_str()); return 2; }

    Vtb_opm *t = new Vtb_opm;
    t->clk = 0; t->rst = 1; t->cs_n = 1; t->wr_n = 1; t->a0 = 0; t->din = 0;
    uint64_t c = 0;                        // clocks of 40 MHz
    auto tick = [&]() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); c++; };
    for (int i = 0; i < 40000; i++) tick();
    t->rst = 0;
    size_t wi = 0; int hold = 0, gap = 0;
    bool js_q = false, is_q = false;
    double first_j = -1, first_i = -1;
    long nj = 0, ni = 0;
    uint64_t end = (uint64_t)(secs * 40e6);
    while (c < end) {
        if (hold == 0 && gap == 0 && wi < ws.size() && (exact || (!t->jt_busy && !t->ika_busy)) && (exact ? (uint64_t)(ws[wi].us * 40.0) : (uint64_t)ceil(ws[wi].us * 1e-6 * 62500.0) * 640) <= c) {
            t->a0 = ws[wi].a0; t->din = ws[wi].d; t->cs_n = 0; t->wr_n = 0; hold = 40; wi++;
        } else if (hold > 0 && --hold == 0) { t->cs_n = 1; t->wr_n = 1; gap = 160; }   // 4 us: a busy flag rises a few of the chip's clocks after the write
        else if (gap > 0) gap--;
        tick();
        if (t->jt_sample && !js_q) {
            int16_t s[4] = {(int16_t)t->jt_l, (int16_t)t->jt_r, (int16_t)t->jt_xl, (int16_t)t->jt_xr};
            fwrite(s, 2, 4, fj); if (first_j < 0) first_j = c / 40e6; nj++;
        }
        if (t->ika_sample && !is_q) {
            int16_t s[4] = {(int16_t)t->ika_l, (int16_t)t->ika_r, (int16_t)t->ika_xl, (int16_t)t->ika_xr};
            fwrite(s, 2, 4, fi); if (first_i < 0) first_i = c / 40e6; ni++;
        }
        js_q = t->jt_sample; is_q = t->ika_sample;
        if (!(c % 40000000)) { printf("%llu of %llu s\n", (unsigned long long)(c / 40000000), (unsigned long long)(end / 40000000)); fflush(stdout); }
    }
    fclose(fj); fclose(fi);
    FILE *b = fopen((out + "/bench.txt").c_str(), "w");
    fprintf(b, "jt51 %.9f %ld\nikaopm %.9f %ld\nwrites %zu\n", first_j, nj, first_i, ni, wi);
    fclose(b);
    printf("jt51 %ld samples from %.6f s, IKAOPM %ld from %.6f s, %zu writes\n", nj, first_j, ni, first_i, wi);
    delete t;
    return 0;
}
