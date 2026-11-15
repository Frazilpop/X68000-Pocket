// SPDX-License-Identifier: GPL-3.0-or-later
// The machine in Verilator, from reset to whatever a disk does. Built twice: SIM_PORT, the real
// core_top with main.cpp playing APF over the bridge, target commands and all; otherwise upstream's own
// X68K_top, with main.cpp playing MiSTer's HPS. Everything below prints what the CPU reached, as a run
// that passes with nothing running proves nothing.
#include <verilated.h>
#include <zlib.h>
#include <coroutine>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <map>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>

#if VM_TRACE
#include <verilated_vcd_c.h>
#endif
#ifdef SIM_PORT
#include "Vsim_port.h"
#include "Vsim_port___024root.h"
typedef Vsim_port Top;
#else
#include "Vsim_upstream.h"
#include "Vsim_upstream___024root.h"
typedef Vsim_upstream Top;
#endif

static Top *t;
static uint64_t now_fs;            // simulated time
#if VM_TRACE
static VerilatedVcdC *vcd;
static double vcd_from = -1, vcd_to = -1;
static std::string vcd_path;
static inline void vcd_step(uint64_t now) {
    double u = now * 1e-9;
    if (vcd_from >= 0 && u >= vcd_from && u <= vcd_to) {
        if (!vcd) { vcd = new VerilatedVcdC; t->trace(vcd, 99); vcd->open(vcd_path.c_str()); printf("VCD from %.1f us\n", u); }
        vcd->dump(now / 1000);
    } else if (vcd && u > vcd_to) { vcd->close(); delete vcd; vcd = nullptr; vcd_from = -1; printf("VCD closed\n"); }
}
#define EVAL() do { t->eval(); vcd_step(now_fs); } while (0)
#else
#define EVAL() t->eval()
#endif
static uint64_t c40;               // rising edges of clk40
static uint64_t c74;

// ------------------------------------------------------------------------- options
struct Press { int frame, n; uint32_t keys; };
struct Event { int frame; int value; };
static struct {
    std::string out = "build/sim_run", boot = "build/pocket/x68000_boot.rom";
    std::string disk[7], sav_in, sav_out, trace;
    int frames = 300, every = 0;
    long trace_max = 200000;
    std::vector<int> save;
    std::vector<Press> press;
    std::vector<Event> drive0, drive1, menu, reset, overlay, reload;
    int seek_us = 500, kb_us = 100, rom_us = -1;
    int bridge_clocks = 30;
    double stop_seconds = 0;
    bool audio = false;
    uint32_t rtc_date = 0x20261105, rtc_time = 0x00120000;   // what APF tells the core, BCD
} opt;

static double sim_us() { return now_fs * 1e-9; }

// ------------------------------------------------------------------------- bus trace
static FILE *trace_f;
static long trace_n, bus_total, bus_writes, gvram_writes, tvram_writes;
static uint32_t last_addr[8]; static int last_i;
static bool as_q; static uint32_t tr_addr; static int tr_rw, tr_mask, tr_fc, tr_dma; static uint32_t tr_data;
static uint32_t fetch_hi;          // the top megabyte's highest fetch etc, for the summary
static std::map<uint32_t, long> region_reads;

static FILE *snd_log_f;            // --audio: writes to the FM chip, the ADPCM and the PPI's port C, timed
static void bus_end() {
    bus_total++;
    if (tr_rw == 0) bus_writes++;
    uint32_t a = tr_addr & 0xfffffe;
    last_addr[last_i++ & 7] = a;
    if (tr_rw == 0) {
        if (a >= 0xc00000 && a < 0xe00000) gvram_writes++;
        else if (a >= 0xe00000 && a < 0xe80000) tvram_writes++;
    }
    region_reads[a >> 20]++;
    if (snd_log_f && tr_rw == 0 && ((a >= 0xe90000 && a < 0xe90004) || (a >= 0xe92000 && a < 0xe92004) || (a >= 0xe9a004 && a < 0xe9a008))) {
        bool lo = tr_mask & 1;
        fprintf(snd_log_f, "%.3f %06x %02x\n", now_fs * 1e-9, a | (lo ? 1 : 0), lo ? tr_data & 0xff : (tr_data >> 8) & 0xff);
    }
    if (trace_f && trace_n < opt.trace_max) {
        uint32_t m = tr_mask == 3 ? 0xffff : tr_mask == 2 ? 0xff00 : 0x00ff;
        fprintf(trace_f, "%06x %c %04x %04x\n", a, tr_rw ? 'R' : 'W', tr_data & 0xffff, m);
        trace_n++;
        if (!(trace_n & 0xff)) fflush(trace_f);
        if (trace_n == opt.trace_max) { fclose(trace_f); trace_f = nullptr; printf("trace: %ld accesses\n", trace_n); }
    }
}

// On each clk40. The CPU's own lines when it has the bus, so an interrupt acknowledge can be left out
// (MAME's tap doesn't see those), the shared bus's when the DMAC has it.
static inline void bus_tick() {
    if (c40 < 64) return;                  // the first clocks' registers are anything
    bool dma = t->t_dma;
    bool as = dma ? !t->t_as : !t->t_asn;
    bool ds = !(t->t_uds_n && t->t_lds_n);
    if (as && ds) {
        tr_addr = dma ? t->t_abus : (uint32_t)t->t_eab << 1;
        tr_rw = dma ? t->t_rw_n : t->t_rwn;
        tr_mask = (t->t_uds_n ? 0 : 2) | (t->t_lds_n ? 0 : 1);
        tr_fc = t->t_fc;
        tr_dma = dma;
        tr_data = (tr_rw || dma) ? t->t_dbus : t->t_cpu_o;
    }
    if (as_q && !as && (tr_dma || tr_fc != 7) && tr_mask) { bus_end(); tr_mask = 0; }
    as_q = as;
}

// ------------------------------------------------------------------------- frames
static std::vector<uint32_t> fb(1024 * 1024);
static int fx, fy, fw, fh, frame_no, line_w, bad_lines, line_first = -1, slot_word = -1, slot_shown = -1;
static std::map<std::string, int> modes_seen;
static long slot_junk;             // anything but zero on the bus with DE low, past the clock after it falls
static long bus_breaks;            // APF's video rules broken: DE twice a line, SKIP without DE, HS beside DE, HS within 3 of VS
static long bus_breaks_frame;
static const char *bus_break_first;
static int  bus_break_line, bus_break_frames;
static void bus_break(const char *what) {
    if (!bus_breaks_frame++) { bus_break_first = what; bus_break_line = fy; }
    bus_breaks++;
}
static void bus_break_frame_end() {        // a line for each frame with breaks, the first 30 such frames
    if (bus_breaks_frame && bus_break_frames++ < 30)
        printf("frame %d: video bus broken %ld times, first at line %d: %s\n", frame_no, bus_breaks_frame, bus_break_line, bus_break_first);
    bus_breaks_frame = 0;
}
static FILE *frames_f;
static uint32_t crc_table[256];

static void png_write(const std::string &path, int w, int h) {
    std::vector<uint8_t> raw; raw.reserve((w * 3 + 1) * h);
    for (int y = 0; y < h; y++) {
        raw.push_back(0);
        for (int x = 0; x < w; x++) {
            uint32_t p = fb[y * 1024 + x];
            raw.push_back(p >> 16); raw.push_back(p >> 8); raw.push_back(p);
        }
    }
    uLongf n = compressBound(raw.size());
    std::vector<uint8_t> z(n);
    compress2(z.data(), &n, raw.data(), raw.size(), 1);
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) return;
    auto chunk = [&](const char *ty, const uint8_t *d, uint32_t len) {
        uint8_t l[4] = {uint8_t(len >> 24), uint8_t(len >> 16), uint8_t(len >> 8), uint8_t(len)};
        fwrite(l, 1, 4, f); fwrite(ty, 1, 4, f); if (len) fwrite(d, 1, len, f);
        uLong c = crc32(0, (const Bytef *)ty, 4); if (len) c = crc32(c, d, len);
        uint8_t k[4] = {uint8_t(c >> 24), uint8_t(c >> 16), uint8_t(c >> 8), uint8_t(c)};
        fwrite(k, 1, 4, f);
    };
    static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', 13, 10, 26, 10};
    fwrite(sig, 1, 8, f);
    uint8_t ih[13] = {uint8_t(w >> 24), uint8_t(w >> 16), uint8_t(w >> 8), uint8_t(w),
                      uint8_t(h >> 24), uint8_t(h >> 16), uint8_t(h >> 8), uint8_t(h), 8, 2, 0, 0, 0};
    chunk("IHDR", ih, 13);
    chunk("IDAT", z.data(), n);
    chunk("IEND", nullptr, 0);
    fclose(f);
}

#ifdef SIM_PORT
static bool gv_clr_pending;   // t_clr, held for one rising edge of clk40 after a frame
#endif
static void frame_end() {
    int w = fw, h = fy;
    if (h == 0) { fx = 0; slot_shown = slot_word; return; }     // none of it drawn: not a frame yet
    frame_no++;
    if (w > 0 && h > 0) {
        uint32_t c = 0;
        for (int y = 0; y < h; y++) c = crc32(c, (const Bytef *)&fb[y * 1024], w * 4);
#ifdef SIM_PORT
        // then the graphics fetch's busiest raster line in the frame (clocks of 40 MHz busy / that line's clocks) and the CPU's longest wait
        fprintf(frames_f, "%d %d %d %d %08x %06x %ld %04x %d/%d %d\n", frame_no, w, h, slot_shown, c, last_addr[(last_i - 1) & 7], bus_total, t->flags,
                t->gv_busy_peak, t->gv_busy_line, t->gv_wait_peak);
        t->t_clr = 1; gv_clr_pending = true;
#else
        fprintf(frames_f, "%d %d %d %d %08x %06x %ld\n", frame_no, w, h, slot_shown, c, last_addr[(last_i - 1) & 7], bus_total);
#endif
        fflush(frames_f);
        char m[64]; snprintf(m, sizeof m, "%dx%d slot %d", w, h, slot_shown);
        if (!modes_seen.count(m)) { modes_seen[m] = frame_no; printf("frame %d: mode %s\n", frame_no, m); }
        bool save = opt.every && frame_no % opt.every == 0;
        for (int s : opt.save) if (s == frame_no) save = true;
        if (save) {
            char p[64]; snprintf(p, sizeof p, "/f_%05d.png", frame_no);
            png_write(opt.out + p, w, h);
        }
    }
    fy = 0; fw = 0; fx = 0;
    slot_shown = slot_word;
}

static inline void line_end() {
    if (fx > 0) {
        if (fw && fx != fw && frame_no > 4) {
            if (bad_lines < 20) printf("frame %d line %d: %d pixels where the frame has %d\n", frame_no + 1, fy, fx, fw);
            bad_lines++;
        }
        if (fx > fw) fw = fx;
        fy++;
        if (fy >= 1024) fy = 1023;
    }
    fx = 0;
}

static inline void pixel(uint32_t rgb) {
    if (fx < 1024) fb[fy * 1024 + fx] = rgb;
    fx++;
}

// ------------------------------------------------------------------------- the card
static std::vector<uint8_t> boot_rom, sav;
static std::vector<uint8_t> disks[7];
static long sectors_read, sectors_written, rom_chunks, cmds_failed;
static double sector_time_sum, sector_time_max;

static bool slurp(const std::string &p, std::vector<uint8_t> &v) {
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    v.resize(n);
    size_t got = fread(v.data(), 1, n, f);
    fclose(f);
    return (long)got == n;
}

static std::vector<uint8_t> *slot_file(int id) {
    if (id == 1) return &boot_rom;
    if (id >= 10 && id <= 16) return &disks[id - 10];
    return nullptr;
}

#ifdef SIM_PORT
// ------------------------------------------------------------------------- APF, on clk_74a
//
// APF as a coroutine. A bridge word is an address, then its data, with bridge_clocks in all at
// clk_74a; a read takes the bus value a few clocks after its address, then strobes bridge_rd, as
// io_bridge_peripheral does. So what a read returns is what the strobe before it fetched.
struct Co {
    struct promise_type {
        Co get_return_object() { return {std::coroutine_handle<promise_type>::from_promise(*this)}; }
        std::suspend_always initial_suspend() { return {}; }
        std::suspend_always final_suspend() noexcept { return {}; }
        void return_void() {}
        void unhandled_exception() { abort(); }
    };
    std::coroutine_handle<promise_type> h;
};

static std::coroutine_handle<> apf_h;
static long apf_wait;

struct Wait {
    long n;
    bool await_ready() const { return n <= 0; }
    void await_suspend(std::coroutine_handle<> h) { apf_h = h; apf_wait = n; }
    void await_resume() {}
};
static Wait clocks(long n) { return Wait{n}; }
static Wait us(double u) { return Wait{(long)(u * 74.25)}; }

static inline void strobes_low() { t->bridge_wr = 0; t->bridge_rd = 0; }

// the words as coroutines of their own would be slow to write; they're macros of awaits
#define BR_WR(a, d) do { t->bridge_addr = (a); t->bridge_wr_data = (d); co_await clocks(8); \
    t->bridge_wr = 1; co_await clocks(1); t->bridge_wr = 0; co_await clocks(opt.bridge_clocks - 9); } while (0)
#define BR_RD(a, v) do { t->bridge_addr = (a); co_await clocks(8); (v) = t->bridge_rd_data; \
    t->bridge_rd = 1; co_await clocks(1); t->bridge_rd = 0; co_await clocks(opt.bridge_clocks - 9); } while (0)
// a register: read twice, as the first only starts its fetch
#define BR_REG(a, v) do { uint32_t dummy_; BR_RD(a, dummy_); (void)dummy_; BR_RD(a, v); } while (0)

#define HOST_CMD(cmd, p0, p1, p2) do { \
    BR_WR(0xF8000020, (p0)); BR_WR(0xF8000024, (p1)); BR_WR(0xF8000028, (p2)); \
    BR_WR(0xF8000000, 0x434D0000u | (cmd)); \
    for (;;) { uint32_t s_; BR_REG(0xF8000000, s_); if ((s_ >> 16) == 0x4F4B) { host_result = s_ & 0xffff; break; } co_await us(5); } \
} while (0)

static int host_result;
static bool shutting_down, shut_done;
static std::vector<std::pair<int, std::string>> apf_log;
static FILE *apf_log_f;
static bool menu_now, menu_want;
static int drive0_want = 0, drive1_want = 1, overlay_want = 0, reset_want = 0, reload_want = 0;
static int drive0_now = 0, drive1_now = 1, overlay_now = 0;

static Co apf_main() {
    uint32_t v;
    co_await clocks(1000);
    // booting: ask until it says it's ready for setup
    for (;;) {
        HOST_CMD(0x0000, 0, 0, 0);
        if (host_result >= 2) break;
        co_await us(50);
    }
startup:
    HOST_CMD(0x0010, 0, 0, 0);          // Reset Enter
    // the table of slots, in data.json's order: id, size
    {
        static const int ids[10] = {0, 1, 2, 10, 11, 12, 13, 14, 15, 16};
        for (int i = 0; i < 10; i++) {
            uint32_t size = 0;
            if (ids[i] == 0) size = 256;
            else if (ids[i] == 1) size = boot_rom.size();
            else if (ids[i] == 2) size = sav.size();
            else size = disks[ids[i] - 10].size();
            BR_WR(0xF8002000 + i * 8, ids[i]);
            BR_WR(0xF8002004 + i * 8, size);
        }
    }
    // the save comes first, over the bridge, if there's a file for it
    if (!sav.empty()) {
        HOST_CMD(0x0080, 2, 0, 0);
        for (size_t i = 0; i + 4 <= sav.size(); i += 4) {
            uint32_t w = (sav[i] << 24) | (sav[i + 1] << 16) | (sav[i + 2] << 8) | sav[i + 3];
            BR_WR(0x20000000 + i, w);
        }
        printf("APF: save loaded, %zu bytes\n", sav.size());
    }
    // persisted settings come just before Reset Exit (the docs' order)
    if (drive0_want != 0) { drive0_now = drive0_want; BR_WR(0xF1000020, drive0_now); }
    if (drive1_want != 1) { drive1_now = drive1_want; BR_WR(0xF1000024, drive1_now); }
    HOST_CMD(0x0090, 0, opt.rtc_date, opt.rtc_time);   // the time
    HOST_CMD(0x008F, 0, 0, 0);          // all complete
    HOST_CMD(0x0011, 0, 0, 0);          // Reset Exit
    printf("APF: running at %.1f us\n", sim_us());

    // running: answer the core's commands, and do what the run asks of the menu
    long poll = 0;
    for (;;) {
        if (shutting_down) break;
        if (menu_want != menu_now) { menu_now = menu_want; HOST_CMD(0x00B0, menu_now, 0, 0); printf("APF: menu %d at frame %d\n", menu_now, frame_no); }
        if (drive0_want != drive0_now) { drive0_now = drive0_want; BR_WR(0xF1000020, drive0_now); printf("APF: drive 0 = %d at frame %d\n", drive0_now, frame_no); }
        if (drive1_want != drive1_now) { drive1_now = drive1_want; BR_WR(0xF1000024, drive1_now); printf("APF: drive 1 = %d at frame %d\n", drive1_now, frame_no); }
        if (overlay_want != overlay_now) { overlay_now = overlay_want; BR_WR(0xF1000014, overlay_now); }
        if (reset_want) { reset_want = 0; BR_WR(0xF100000C, 1); printf("APF: reset at frame %d\n", frame_no); }
        // A game loaded again from the menu, with the core kept: the menu open, APF's start again from Reset Enter, and
        // no word that the menu has closed (the worst the Pocket could do short of loading the bitstream again)
        if (reload_want) {
            reload_want = 0;
            if (!menu_now) { menu_now = menu_want = true; HOST_CMD(0x00B0, 1, 0, 0); }
            printf("APF: reload at frame %d\n", frame_no);
            goto startup;
        }

        uint32_t st;
        BR_REG(0xF8001000, st);
        if ((st >> 16) == 0x636D) {         // 'cm'
            int cmd = st & 0xffff;
            if (cmd == 0x0140) {
                BR_WR(0xF8001000, 0x6F6B0000u);  // Ready to Run
                printf("APF: 0x0140 at %.1f us\n", sim_us());
            } else if (cmd == 0x0180 || cmd == 0x0184) {
                uint32_t id, off, addr, len;
                BR_REG(0xF8001020, id); BR_REG(0xF8001024, off); BR_REG(0xF8001028, addr); BR_REG(0xF800102C, len);
                BR_WR(0xF8001000, 0x62750000u | cmd);   // 'bu'
                auto *file = slot_file(id);
                double t0 = sim_us();
                int err = 0;
                if (!file || file->empty() || off + len > file->size()) { err = 2; cmds_failed++; printf("APF: bad command %04x id %u off %u len %u\n", cmd, id, off, len); }
                double took = (id == 1 && opt.rom_us >= 0) ? opt.rom_us : opt.seek_us + opt.kb_us * (len / 1024.0);
                if (cmd == 0x0180) {
                    co_await us(took);
                    if (!err) for (uint32_t i = 0; i < len; i += 4) {
                        const uint8_t *p = file->data() + off + i;
                        uint32_t w = (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
                        BR_WR(addr + i, w);
                    }
                    if (id == 1) rom_chunks++; else sectors_read++;
                } else {
                    // APF reads a word ahead: the strobe at each address, its word on the next read
                    if (!err) {
                        BR_RD(addr, v);
                        for (uint32_t i = 0; i < len; i += 4) {
                            BR_RD(addr + (i + 4 < len ? i + 4 : i), v);
                            uint8_t *p = file->data() + off + i;
                            p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
                        }
                    }
                    co_await us(took);
                    sectors_written++;
                }
                double d = sim_us() - t0;
                if (id != 1) { sector_time_sum += d; if (d > sector_time_max) sector_time_max = d; }
                BR_WR(0xF8001000, 0x6F6B0000u | err);    // 'ok'
                if (apf_log_f) { fprintf(apf_log_f, "%.1f %04x id %u off %u len %u err %d frame %d\n", sim_us(), cmd, id, off, len, err, frame_no); fflush(apf_log_f); }
            } else {
                printf("APF: command %04x not handled\n", cmd);
                BR_WR(0xF8001000, 0x6F6BFFFFu);
            }
        }
        co_await clocks(poll = 200);
    }
    (void)poll;

    // quitting: the save read back, a word ahead
    if (!opt.sav_out.empty()) {
        // the size APF goes by is the one in the table, which the core keeps for a slot with no file
        uint32_t size;
        BR_REG(0xF8002014, size);
        printf("APF: the table says the save is %u bytes\n", size);
        HOST_CMD(0x0082, 2, size, 0);
        sav.assign(size, 0);
        BR_RD(0x20000000, v);
        for (uint32_t i = 0; i < size; i += 4) {
            BR_RD(0x20000000 + (i + 4 < size ? i + 4 : i), v);
            sav[i] = v >> 24; sav[i + 1] = v >> 16; sav[i + 2] = v >> 8; sav[i + 3] = v;
        }
        FILE *f = fopen(opt.sav_out.c_str(), "wb");
        if (f) { fwrite(sav.data(), 1, sav.size(), f); fclose(f); }
        printf("APF: save written out to %s\n", opt.sav_out.c_str());
    }
    shut_done = true;
    for (;;) co_await clocks(1000000);
}

static inline void apf_tick() {
    if (apf_wait > 0 && --apf_wait == 0) { auto h = apf_h; apf_h = nullptr; h.resume(); }
}
#else
// ------------------------------------------------------------------------- the HPS, on clk40
static enum { L_WAIT, L_WR, L_ACK, L_ACK2, L_NAK, L_DONE } ldr = L_WAIT;
static uint32_t ldr_i; static long ldr_delay = 2000;
static uint32_t mnt[2];
static int fd_size_known;
static enum { D_IDLE, D_DELAY, D_RD, D_RD2, D_WR, D_WR2, D_END } dsk = D_IDLE;
static int d_unit; static long d_wait; static int d_k; static uint32_t d_lba; static bool d_is_wr;

static inline void hps_tick() {
    if (c40 == 200) t->plllock = 1;
    // the boot ROM, a byte at a time, each on the board's ack: X68000.sv's ldr_wr
    switch (ldr) {
    case L_WAIT:
        if (--ldr_delay == 0) { t->rstn = 1; t->ldr_aen = 1; ldr = L_WR; }
        break;
    case L_WR:
        t->ldr_addr = ldr_i; t->ldr_wdat = boot_rom[ldr_i]; t->ldr_wr = 1; ldr = L_ACK;
        break;
    case L_ACK:
        if (t->ldr_ack) ldr = L_ACK2;      // X68000.sv's ldr_wr falls a clock after it sees this
        break;
    case L_ACK2:
        t->ldr_wr = 0; ldr = L_NAK;
        break;
    case L_NAK:
        if (!t->ldr_ack) {
            if (++ldr_i == boot_rom.size()) {
                t->ldr_aen = 0; t->ldr_done = 1; ldr = L_DONE; printf("HPS: boot ROM in at %.1f us\n", sim_us());
                for (int u = 0; u < 2; u++) if (!disks[u].empty()) mnt[u] = 0xFFFFFF;
            } else ldr = L_WR;
        }
        break;
    case L_DONE: break;
    }
    // mounting, as mount_count: taken out for 0.4 s, then shown as mounted for 1.6 ms
    for (int u = 0; u < 2; u++) if (mnt[u]) mnt[u]--;
    uint32_t e = ((mnt[1] >> 16) ? 2 : 0) | ((mnt[0] >> 16) ? 1 : 0);
    uint32_t m = ((mnt[1] && !(e & 2) && !disks[1].empty()) ? 2 : 0) | ((mnt[0] && !(e & 1) && !disks[0].empty()) ? 1 : 0);
    t->fd_eject = e;
    t->fd_mounted = m;
    t->fd_size = (m & 1) ? disks[0].size() : disks[1].size();
    // a sector
    t->mist_buffwr = 0;
    switch (dsk) {
    case D_IDLE:
        if (t->mist_rd & 3) { d_unit = (t->mist_rd & 2) ? 1 : 0; d_is_wr = false; d_lba = t->mist_lba; d_wait = opt.seek_us * 40 + opt.kb_us * 20; dsk = D_DELAY; }
        else if (t->mist_wr & 3) { d_unit = (t->mist_wr & 2) ? 1 : 0; d_is_wr = true; d_lba = t->mist_lba; d_wait = 8; dsk = D_DELAY; }
        break;
    case D_DELAY:
        if (--d_wait == 0) { t->mist_ack = 1 << d_unit; d_k = 0; dsk = d_is_wr ? D_WR : D_RD; }
        break;
    case D_RD:
        { size_t off = (size_t)d_lba * 512 + d_k;
          t->mist_buffaddr = d_k; t->mist_buffdout = off < disks[d_unit].size() ? disks[d_unit][off] : 0; t->mist_buffwr = 1; }
        dsk = D_RD2;
        break;
    case D_RD2:
        if (++d_k == 512) { dsk = D_END; sectors_read++; } else dsk = D_RD;
        break;
    case D_WR:
        t->mist_buffaddr = d_k; dsk = D_WR2; d_wait = 2;
        break;
    case D_WR2:
        if (--d_wait == 0) {
            size_t off = (size_t)d_lba * 512 + d_k;
            if (off < disks[d_unit].size()) disks[d_unit][off] = t->mist_buffdin;
            if (++d_k == 512) { dsk = D_END; sectors_written++; } else dsk = D_WR;
        }
        break;
    case D_END:
        t->mist_ack = 0; dsk = D_IDLE;
        break;
    }
}
#endif

// ------------------------------------------------------------------------- audio
static FILE *wav_f; static long wav_samples; static double wav_next_us;
#ifdef SIM_PORT
// the FM chip's own output at its rate, 4 MHz / 64: every 640 clocks of 40 MHz, left and right; the
// ADPCM decoder's 12 bits each time they change, with the clock of 40 MHz they changed on
static FILE *fm_f, *pcm_f; static int fm_div; static int pcm_q = -1;
#endif
static void wav_header() {
    uint32_t bytes = wav_samples * 4, rate = 48000;
    uint8_t h[44] = {'R','I','F','F',0,0,0,0,'W','A','V','E','f','m','t',' ',16,0,0,0,1,0,2,0,0,0,0,0,0,0,0,0,4,0,16,0,'d','a','t','a',0,0,0,0};
    auto p32 = [&](int o, uint32_t v) { h[o]=v; h[o+1]=v>>8; h[o+2]=v>>16; h[o+3]=v>>24; };
    p32(4, 36 + bytes); p32(24, rate); p32(28, rate * 4); p32(40, bytes);
    fseek(wav_f, 0, SEEK_SET); fwrite(h, 1, 44, wav_f); fseek(wav_f, 0, SEEK_END);
}

// The boot ROM as it lies in the SDRAM model, against the file: says the loader worked.
static void check_rom() {
#ifdef SIM_PORT
    auto &m = t->rootp->sim_port__DOT__u_sdram__DOT__mem;
#else
    auto &m = t->rootp->sim_upstream__DOT__u_sdram__DOT__mem;
#endif
    long bad = 0, first = -1;
    for (uint32_t i = 0; i + 1 < boot_rom.size(); i += 2) {
        uint32_t w = (0xF00000 + i) >> 1;
        uint32_t idx = (((w >> 22) & 3) << 23) | (((w >> 9) & 0x1fff) << 10) | (w & 0x1ff);
        uint32_t want = (boot_rom[i] << 8) | boot_rom[i + 1];
        if (m[idx] != want) { if (first < 0) { first = i; printf("ROM check: at %06x SDRAM %04x file %04x\n", 0xF00000 + i, (unsigned)m[idx], want); } bad++; }
    }
    printf("ROM check: %ld of %zu words differ\n", bad, boot_rom.size() / 2);
}

// ------------------------------------------------------------------------- run
static uint32_t key_mask(const std::string &s) {
    static const std::map<std::string, int> b = {{"up",0},{"down",1},{"left",2},{"right",3},{"a",4},{"b",5},{"x",6},{"y",7},
        {"l",8},{"r",9},{"select",14},{"start",15}};
    uint32_t m = 0; size_t i = 0;
    while (i < s.size()) {
        size_t j = s.find('+', i); if (j == std::string::npos) j = s.size();
        auto it = b.find(s.substr(i, j - i));
        if (it == b.end()) { fprintf(stderr, "unknown key %s\n", s.substr(i, j - i).c_str()); exit(2); }
        m |= 1u << it->second; i = j + 1;
    }
    return m;
}
static Event parse_ev(const char *a) { Event e{}; sscanf(a, "%d:%d", &e.frame, &e.value); return e; }

static void usage() {
    puts("--frames N  --every K  --save F[,F...]  --out DIR  --boot FILE|none  --disk N FILE (1-7)  --trace FILE  --trace-max N\n"
         "--press F:keys[:N]  --drive0 F:slot  --drive1 F:slot  --menu F:0|1  --reset F  --reload F  --overlay F:0|1\n"
         "--sav-in FILE --sav-out FILE  --seek-us N --kb-us N --rom-us N  --audio  --rtc YYYYMMDD:00HHMMSS (APF's time, BCD)");
    exit(2);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::randReset(0);
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> const char * { if (++i >= argc) usage(); return argv[i]; };
        if (a == "--frames") opt.frames = atoi(next());
        else if (a == "--every") opt.every = atoi(next());
        else if (a == "--out") opt.out = next();
        else if (a == "--boot") opt.boot = next();
        else if (a == "--disk") { int n = atoi(next()); opt.disk[n - 1] = next(); }
        else if (a == "--trace") opt.trace = next();
        else if (a == "--trace-max") opt.trace_max = atol(next());
        else if (a == "--save") { std::string s = next(); size_t p = 0; while (p < s.size()) { opt.save.push_back(atoi(s.c_str() + p)); p = s.find(',', p); if (p == std::string::npos) break; p++; } }
        else if (a == "--press") { Press r{}; char keys[64] = {}; r.n = 4; sscanf(next(), "%d:%63[^:]:%d", &r.frame, keys, &r.n); r.keys = key_mask(keys); opt.press.push_back(r); }
        else if (a == "--drive0") opt.drive0.push_back(parse_ev(next()));
        else if (a == "--drive1") opt.drive1.push_back(parse_ev(next()));
        else if (a == "--menu") opt.menu.push_back(parse_ev(next()));
        else if (a == "--overlay") opt.overlay.push_back(parse_ev(next()));
        else if (a == "--reset") { Event e{atoi(next()), 1}; opt.reset.push_back(e); }
        else if (a == "--reload") { Event e{atoi(next()), 1}; opt.reload.push_back(e); }
        else if (a == "--sav-in") opt.sav_in = next();
        else if (a == "--sav-out") opt.sav_out = next();
        else if (a == "--seek-us") opt.seek_us = atoi(next());
        else if (a == "--kb-us") opt.kb_us = atoi(next());
        else if (a == "--rom-us") opt.rom_us = atoi(next());
        else if (a == "--audio") opt.audio = true;
        else if (a == "--rtc") { unsigned d, h; if (sscanf(next(), "%x:%x", &d, &h) != 2) usage(); opt.rtc_date = d; opt.rtc_time = h; }
        else if (a == "--stop-s") opt.stop_seconds = atof(next());
#if VM_TRACE
        else if (a == "--vcd") { vcd_path = next(); vcd_from = atof(next()); vcd_to = atof(next()); Verilated::traceEverOn(true); }
#endif
        else usage();
    }
    mkdir(opt.out.c_str(), 0755);
    if (opt.boot == "none") boot_rom.clear();   // as a card without the file: every read of it fails
    else if (!slurp(opt.boot, boot_rom) || boot_rom.size() != 1048576) { fprintf(stderr, "no boot ROM at %s\n", opt.boot.c_str()); return 2; }
    for (int i = 0; i < 7; i++) if (!opt.disk[i].empty() && !slurp(opt.disk[i], disks[i])) { fprintf(stderr, "no disk at %s\n", opt.disk[i].c_str()); return 2; }
    if (!opt.sav_in.empty() && !slurp(opt.sav_in, sav)) { fprintf(stderr, "no save at %s\n", opt.sav_in.c_str()); return 2; }
    frames_f = fopen((opt.out + "/frames.txt").c_str(), "w");
    if (!opt.trace.empty()) trace_f = fopen(opt.trace.c_str(), "w");
    if (opt.audio) {
        wav_f = fopen((opt.out + "/audio.wav").c_str(), "wb"); wav_header();
        snd_log_f = fopen((opt.out + "/sound_writes.txt").c_str(), "w");
#ifdef SIM_PORT
        fm_f = fopen((opt.out + "/fm.s16").c_str(), "wb");
        pcm_f = fopen((opt.out + "/pcm.txt").c_str(), "w");
#endif
    }

    {   // the init files are named from the translation's folder; the run's own paths are kept
        char *abs = realpath(opt.out.c_str(), nullptr);
        if (abs) { opt.out = abs; free(abs); }
        if (const char *gen = getenv("X68K_SIM_GEN")) if (chdir(gen)) { perror(gen); return 2; }
    }
    t = new Top;
#ifdef SIM_PORT
    for (auto &e : opt.drive0) if (e.frame == 0) drive0_want = e.value;
    for (auto &e : opt.drive1) if (e.frame == 0) drive1_want = e.value;
    apf_log_f = fopen((opt.out + "/apf.log").c_str(), "w");
    Co apf = apf_main();
    apf_h = apf.h; apf_wait = 1;
    t->cont1_key = 0; t->cont2_key = 0; t->t_clr = 0;
    const uint64_t half80 = 6248000, half74 = 6734000;   // fs, 80.025 and 74.25 MHz
#else
    t->plllock = 0; t->rstn = 0; t->ldr_aen = 0; t->ldr_wr = 0; t->ldr_done = 0; t->mist_ack = 0; t->mist_buffwr = 0;
    t->joy_a = 0x3F; t->sysrtc = {0, 0, 0}; t->fd_eject = 0; t->fd_mounted = 0;
    const uint64_t half80 = 6250000;
    uint64_t half_scan = 12865000, next_scan = half_scan;     // 38.86 MHz until a mode says otherwise
#endif
    uint64_t next80 = half80;
#ifdef SIM_PORT
    uint64_t next74 = half74;
#endif
    auto wall0 = std::chrono::steady_clock::now();
    int frames_done = 0, frame_seen = -1;
    bool vs_q = false, hs_q = false;
    size_t next_press = 0;
    uint32_t keys = 0; int keys_until = -1;
    double last_print = 0;

    auto run_events = [&]() {
#ifdef SIM_PORT
        for (auto &e : opt.drive0) if (e.frame == frame_no) drive0_want = e.value;
        for (auto &e : opt.drive1) if (e.frame == frame_no) drive1_want = e.value;
        for (auto &e : opt.menu) if (e.frame == frame_no) menu_want = e.value;
        for (auto &e : opt.overlay) if (e.frame == frame_no) overlay_want = e.value;
        for (auto &e : opt.reset) if (e.frame == frame_no) reset_want = 1;
        for (auto &e : opt.reload) if (e.frame == frame_no) reload_want = 1;
#endif
        keys = 0;
        for (auto &p : opt.press) if (frame_no >= p.frame && frame_no < p.frame + p.n) keys |= p.keys;
#ifdef SIM_PORT
        t->cont1_key = keys;
#else
        // 2-button pad, active low: up, down, left, right, A, B on the port as the machine reads it
        uint32_t j = 0x3F;
        if (keys & 1) j &= ~1; if (keys & 2) j &= ~2; if (keys & 4) j &= ~4; if (keys & 8) j &= ~8;
        if (keys & 16) j &= ~16; if (keys & 32) j &= ~32;
        t->joy_a = j;
#endif
        (void)next_press; (void)keys_until;
    };

    for (;;) {
#ifdef SIM_PORT
        if (next74 <= next80) {
            now_fs = next74; next74 += half74;
            t->clk_74a = !t->clk_74a;
            EVAL();
            if (t->clk_74a) { c74++; apf_tick(); }
        } else
#else
        if (next_scan <= next80) {
            now_fs = next_scan; next_scan += half_scan;
            t->clk_scan = !t->clk_scan;
            EVAL();
            if (t->clk_scan && t->v_ce) {
                bool vs = t->v_vs, hs = t->v_hs;
                if (hs && !hs_q) line_end();
                if (vs && !vs_q) { line_end(); frame_end(); run_events(); }
                hs_q = hs; vs_q = vs;
                if (!t->v_hb && !t->v_vb) pixel((t->v_r << 16) | (t->v_g << 8) | t->v_b);
            }
        } else
#endif
        {
            now_fs = next80; next80 += half80;
            t->clk80 = !t->clk80;
            bool r40 = false;
            if (t->clk80) { t->clk40 = !t->clk40; r40 = t->clk40; }
#ifdef SIM_PORT
            else t->clk40_90 = t->clk40;
#endif
            EVAL();
            if (r40) {
                c40++;
                bus_tick();
#ifdef SIM_PORT
                if (gv_clr_pending) { t->t_clr = 0; gv_clr_pending = false; }
                if (t->video_vs) { line_end(); frame_end(); bus_break_frame_end(); run_events(); }
                if (t->video_hs) line_end();
                // the scaler's view (Analogue: Bus Communication, VIDEO): a pixel on each clock with DE
                // high and SKIP low; the word on the first clock after DE falls, the last such in a line
                static bool de_q, hs_q, de_this_line;
                static int since_vs = 99;
                since_vs = t->video_vs ? 0 : since_vs + 1;
                if (t->video_hs) {
                    if (t->video_de || de_q) bus_break("HS beside DE");
                    if (since_vs < 3) bus_break("HS within 3 clocks of VS");
                    de_this_line = false;
                }
                if (t->video_skip && !t->video_de) bus_break("SKIP without DE");
                if (t->video_de && !de_q) {
                    if (de_this_line) bus_break("DE twice in a line");
                    if (hs_q) bus_break("DE the clock after HS");
                    de_this_line = true;
                }
                if (t->video_de) { if (!t->video_skip) pixel(t->video_rgb); }
                else {
                    if (de_q) slot_word = (t->video_rgb >> 13) & 7;
                    else if (t->video_rgb) slot_junk++;
                }
                hs_q = t->video_hs;
                de_q = t->video_de;
#else
                hps_tick();
                static int mode_q = -1;
                if (t->scan_mode_o != mode_q) {
                    mode_q = t->scan_mode_o;
                    half_scan = (mode_q & 3) == 3 ? 9930000 : !(mode_q & 4) ? 12865000 : 7188000;   // 50.35, 38.86, 69.55 MHz
                }
#endif
#ifdef SIM_PORT
                if (fm_f && ++fm_div == 640) {
                    fm_div = 0;
                    int16_t s[2] = {(int16_t)t->ym_l, (int16_t)t->ym_r};
                    fwrite(s, 2, 2, fm_f);
                }
                if (pcm_f && (int)t->pcm_raw != pcm_q) {
                    pcm_q = t->pcm_raw;
                    fprintf(pcm_f, "%llu %d\n", (unsigned long long)c40, (pcm_q & 0x800) ? pcm_q - 0x1000 : pcm_q);
                }
#endif
#ifdef SIM_PORT
                // the port's WAV: each sample the resampler makes, as sound_i2s takes them (the harness's clock40
                // is 40.0128 MHz, so 48,000.36 a second, not quite the header's; sampled at 48 kHz of its own,
                // one would slip every 3 s)
                if (wav_f && t->aud_new) {
#else
                if (wav_f && sim_us() >= wav_next_us) {
#endif
                    int16_t s[2] = {(int16_t)t->snd_l, (int16_t)t->snd_r};
                    fwrite(s, 2, 2, wav_f); wav_samples++; wav_next_us += 1e6 / 48000;
                }
            }
        }
        if (frame_no != frame_seen) {
            frame_seen = frame_no;
            double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - wall0).count();
            if (secs - last_print >= 10 || frame_no >= opt.frames) {
                last_print = secs;
                printf("%d of %d frames, %.0f s, sim %.3f s, CPU %ld bus accesses at %06x, sectors %ld + %ld\n",
                       frame_no, opt.frames, secs, sim_us() * 1e-6, bus_total, last_addr[(last_i - 1) & 7], sectors_read, sectors_written);
                fflush(stdout);
            }
            if (frame_no >= opt.frames) break;
        }
        if (!(c40 & 0xFFFFF)) {
            // no frames at all is a run that has to say so: the time limit
            static uint64_t last_c40 = ~0ull;
            if (c40 != last_c40) {
                last_c40 = c40;
                double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - wall0).count();
                if (secs - last_print >= 10) {
                    last_print = secs;
                    printf("still %d frames at sim %.3f s, %.0f s, CPU %ld bus accesses at %06x\n", frame_no, sim_us() * 1e-6, secs, bus_total, last_addr[(last_i - 1) & 7]);
                    fflush(stdout);
                }
                if (opt.stop_seconds > 0 && sim_us() * 1e-6 > opt.stop_seconds) break;
            }
        }
        if (Verilated::gotFinish()) break;
    }

#ifdef SIM_PORT
    // quit as APF does
    shutting_down = true;
    while (!shut_done) {
        if (next74 <= next80) { now_fs = next74; next74 += half74; t->clk_74a = !t->clk_74a; EVAL(); if (t->clk_74a) apf_tick(); }
        else { now_fs = next80; next80 += half80; t->clk80 = !t->clk80; if (t->clk80) t->clk40 = !t->clk40; else t->clk40_90 = t->clk40; EVAL(); }
    }
#endif
    check_rom();
    if (wav_f) { wav_header(); fclose(wav_f); }
    if (snd_log_f) fclose(snd_log_f);
#ifdef SIM_PORT
    if (fm_f) fclose(fm_f);
    if (pcm_f) fclose(pcm_f);
#endif
    if (trace_f) fclose(trace_f);
    for (int i = 0; i < 7; i++) if (!disks[i].empty() && sectors_written) {
        char p[64]; snprintf(p, sizeof p, "/disk_%d.dim", i + 1);
        FILE *f = fopen((opt.out + p).c_str(), "wb"); if (f) { fwrite(disks[i].data(), 1, disks[i].size(), f); fclose(f); }
    }
    double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - wall0).count();
    FILE *j = fopen((opt.out + "/run.json").c_str(), "w");
    char sum[1024];
    snprintf(sum, sizeof sum,
             "{\"frames\": %d, \"sim_s\": %.4f, \"wall_s\": %.1f, \"s_per_frame\": %.2f, \"bus\": %ld, \"bus_writes\": %ld, "
             "\"gvram_writes\": %ld, \"tvram_writes\": %ld, \"last_addr\": \"%06x\", \"rom_chunks\": %ld, \"sectors_read\": %ld, "
             "\"sectors_written\": %ld, \"sector_us_max\": %.0f, \"cmds_failed\": %ld, \"lines_of_other_widths\": %d, \"sdram_violations\": %u, \"slot_junk\": %ld, \"video_bus_breaks\": %ld"
#ifdef SIM_PORT
             ", \"psram_violations\": [%u, %u], \"flags\": \"%04x\""
#endif
             "}\n",
             frame_no, sim_us() * 1e-6, secs, frame_no ? secs / frame_no : 0, bus_total, bus_writes, gvram_writes, tvram_writes,
             last_addr[(last_i - 1) & 7], rom_chunks, sectors_read, sectors_written, sector_time_max, cmds_failed, bad_lines, t->sdram_viol, slot_junk, bus_breaks
#ifdef SIM_PORT
             , t->psram0_viol, t->psram1_viol, t->flags
#endif
             );
    fputs(sum, stdout);
    if (j) { fputs(sum, j); fclose(j); }
    printf("regions (1 MB each, accesses):");
    for (auto &kv : region_reads) printf(" %03x:%ld", kv.first << 20 >> 20, kv.second);
    printf("\nmodes:"); for (auto &kv : modes_seen) printf(" [%s from frame %d]", kv.first.c_str(), kv.second);
    printf("\n");
    delete t;
    return 0;
}
