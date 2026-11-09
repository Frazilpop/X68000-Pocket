// SPDX-License-Identifier: GPL-3.0-or-later
// pocket_audio_resample alone: the FM chip's samples (a 62.5 kHz s16 file, as the FM bench writes)
// held on its input as the board holds them, a new one every 640 clocks of 40.0125 MHz, left and
// minus left on the right. Each 48 kHz output is checked against the same sum worked out here from
// the taps file: the 24 samples the module had taken before the tick, the phase from the clocks
// since the last of them over 10, rounded at 2^17 and kept to 16 bits. Also counts the outputs:
// 48,000 a second, none twice, none missed. Writes the outputs (left) to OUT.s16.
//
//   build/sound/resample_bench/run FILE.s16 STRIDE COL SECONDS OUT.s16 TAPS.hex
#include <verilated.h>
#include "Vpocket_audio_resample.h"
#include "Vpocket_audio_resample___024root.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

int main(int argc, char **argv) {
    if (argc < 7) { fprintf(stderr, "run FILE.s16 STRIDE COL SECONDS OUT.s16 TAPS.hex\n"); return 2; }
    int stride = atoi(argv[2]), col = atoi(argv[3]);
    double secs = atof(argv[4]);
    std::vector<int16_t> all;
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    int16_t b[8];
    while (fread(b, 2, stride, f) == (size_t)stride) all.push_back(b[col]);
    fclose(f);
    std::vector<int32_t> taps;
    FILE *h = fopen(argv[6], "r");
    if (!h) { perror(argv[6]); return 2; }
    unsigned v;
    while (fscanf(h, "%x", &v) == 1) taps.push_back((v & 0x20000) ? (int32_t)v - 0x40000 : (int32_t)v);
    fclose(h);
    FILE *o = fopen(argv[5], "wb");
    Vpocket_audio_resample *t = new Vpocket_audio_resample;
    const double CLK = 40.0125e6;
    uint64_t clocks = (uint64_t)(secs * CLK), c = 0;
    size_t k = 0;
    std::vector<std::pair<uint64_t, int>> taken;        // (clock, value) of each sample the module took
    long outs = 0, bad = 0, checked = 0;
    int16_t q_in = 0;
    // the tick, as the module's accumulator makes it, kept here on its own
    uint32_t acc = 0;
    std::vector<uint64_t> ticks;
    t->clk = 0; t->in_l = 0; t->in_r = 0; t->eval();
    while (c < clocks) {
        if (c % 640 == 300 && k < all.size()) q_in = all[k++];
        t->in_l = q_in; t->in_r = -q_in;
        bool tick = acc >= 26643;
        if (tick) ticks.push_back(c);
        acc = tick ? acc + 32 - 26675 : acc + 32;
        bool e3_pre = t->rootp->pocket_audio_resample__DOT__e3;     // out is written on this edge
        int16_t in_now = q_in;
        bool take = t->rootp->pocket_audio_resample__DOT__div == 639;
        t->clk = 1; t->eval();
        if (take) taken.push_back({c, in_now});
        t->clk = 0; t->eval();
        if (e3_pre) {
            int16_t out = (int16_t)t->out_l, out_r = (int16_t)t->out_r;
            outs++;
            fwrite(&out, 2, 1, o);
            // its tick: the last before this edge by at least the pipeline's 28 clocks
            uint64_t tk = 0;
            for (size_t i = ticks.size(); i-- > 0;) if (ticks[i] + 27 <= c) { tk = ticks[i]; break; }
            size_t n = taken.size();
            while (n && taken[n - 1].first >= tk) n--;   // samples taken on an edge before the tick's
            if (n >= 24) {
                int ph = (int)((tk - taken[n - 1].first - 1) / 10);
                if (ph > 63) ph = 63;
                int64_t s = 0, sr = 0;
                for (int j = 0; j < 24; j++) {
                    s  += (int64_t)taps[ph * 32 + j] * taken[n - 24 + j].second;
                    sr += (int64_t)taps[ph * 32 + j] * -taken[n - 24 + j].second;
                }
                auto fin = [](int64_t x) { int64_t q = (x + 65536) >> 17; return (int16_t)(q > 32767 ? 32767 : q < -32768 ? -32768 : q); };
                checked++;
                if (fin(s) != out || fin(sr) != out_r) {
                    if (bad < 5) printf("tick %llu: out %d %d, want %d %d (phase %d)\n", (unsigned long long)tk, out, out_r, fin(s), fin(sr), ph);
                    bad++;
                }
            }
        }
        c++;
    }
    fclose(o);
    double s = c / CLK;
    printf("%.3f s: %ld outputs (%.3f a second, 48000 wanted), %zu samples taken (%.1f a second), %ld checked, %ld not as worked out\n",
           s, outs, outs / s, taken.size(), taken.size() / s, checked, bad);
    delete t;
    return bad ? 1 : 0;
}
