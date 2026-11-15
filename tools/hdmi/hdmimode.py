#!/usr/bin/python3
# hdmimode.py <edid.bin> <outdir> [WxH[@Hz]]: pick the monitor's mode from its EDID and write the register plans for it
# (signal.txt, plane.txt, audio.txt; dmubboot run) plus mode.txt, the arguments for `fb1cfg online <edid> mode ...`.
# The plans are the captured 2560x1440@60 ones (plan_signal, plan_plane6, plan_audio) with the mode's numbers put in.
# For the captured mode itself nothing changes. Any other mode gets the request settings the firmware (GOP) uses on
# the panel's pipe (TTU off, no DLG timing parameters), since Linux's DLG values are computed per mode by DML.
# Limits: 8 bpc RGB, pixel clock <= 340 MHz (no HDMI 2.0 scrambling), progressive.
import sys, os, math
HERE = os.path.dirname(os.path.abspath(__file__))
MAXCLK = 340000

def dtd(d):
    pclk = (d[0] | d[1] << 8) * 10
    if not pclk: return None
    ha = d[2] | (d[4] >> 4) << 8; hb = d[3] | (d[4] & 15) << 8; va = d[5] | (d[7] >> 4) << 8; vb = d[6] | (d[7] & 15) << 8
    hso = d[8] | (d[11] >> 6) << 8; hsw = d[9] | ((d[11] >> 4) & 3) << 8
    vso = (d[10] >> 4) | ((d[11] >> 2) & 3) << 4; vsw = (d[10] & 15) | (d[11] & 3) << 4
    if d[17] & 0x80 or not (ha and va and hb and vb and hsw and vsw): return None   # interlaced or broken
    pos = (d[17] & 0x18) == 0x18
    return dict(pclk=pclk, ha=ha, va=va, ht=ha + hb, vt=va + vb, hss=ha + hso, hse=ha + hso + hsw, vss=va + vso, vse=va + vso + vsw,
                hpos=1 if pos and d[17] & 2 else 0, vpos=1 if pos and d[17] & 4 else 0)

def modes(e):
    out = []
    for o in range(54, 126, 18):
        m = dtd(e[o:o + 18])
        if m: out.append(m)
    for b in range(1, len(e) // 128):
        x = e[b * 128:(b + 1) * 128]
        if x[0] != 2 or x[2] < 4: continue          # CTA-861 extension: detailed timings from its offset on
        for o in range(x[2], 127 - 17, 18):
            m = dtd(x[o:o + 18])
            if m: out.append(m)
    return out

FHD = dict(pclk=148500, ha=1920, va=1080, ht=2200, vt=1125, hss=2008, hse=2052, vss=1084, vse=1089, hpos=1, vpos=1)

def hz(m): return m['pclk'] * 1000 / (m['ht'] * m['vt'])

def pick(e, want):      # want: (width, height, refresh or None)
    ms = modes(e)
    ok = [m for m in ms if m['pclk'] <= MAXCLK and m['ha'] <= 4096 and m['va'] <= 2304]
    if want:
        hit = [m for m in ok if (m['ha'], m['va']) == want[:2] and (want[2] is None or abs(hz(m) - want[2]) < 1)]
        if hit: return hit[0]
    if not ok: return FHD
    return ok[0] if ok[0] is ms[0] else max(ok, key=lambda m: (m['ha'] * m['va'], m['pclk']))   # the preferred timing when it fits

# The audio endpoint of the HDMI port (AZF0ENDPOINT1: index 0x384c, data 0x384d), as Linux's dce_audio sets it at
# every enable: what the sink can play (from the EDID's CTA block) and its name, for the HD-audio codec's ELD. Without
# it the codec reports no monitor. Returns the plan lines for before the link comes up and for after, or None when the
# EDID announces no audio.
def audio_endpoint(e, dp=False):
    sad = None; spk = 1; basic = False
    for b in range(1, len(e) // 128):
        x = e[b * 128:(b + 1) * 128]
        if x[0] != 2: continue
        basic = basic or bool(x[3] & 0x40)
        i = 4
        while i < x[2]:
            tag, n = x[i] >> 5, x[i] & 31
            if tag == 1:
                for j in range(i + 1, i + 1 + n - 2, 3):
                    if x[j] >> 3 & 15 == 1 and (sad is None or (x[j] & 7) > (sad[0] & 7)): sad = x[j:j + 3]   # LPCM, most channels
            elif tag == 4 and n >= 1: spk = x[i + 1] & 0x7f or 1
            i += 1 + n
    if sad is None and not basic: return None
    if sad is None: sad = bytes([0x09, 0x07, 0x07])      # basic audio: 2-channel LPCM, 32/44.1/48 kHz, 16/20/24 bit
    name = b''
    for o in range(54, 126, 18):
        if e[o:o + 3] == b'\0\0\0' and e[o + 3] == 0xfc: name = e[o + 5:o + 18].split(b'\n')[0].rstrip()
    name = name[:16]
    ir = 0x3852 if dp else 0x384c       # the HDMI port's encoder uses endpoint 1, the USB-C DP one endpoint 2
    w = lambda idx, val, note='': ['w %x %x AZF0ENDPOINT_INDEX' % (ir, idx), 'w %x %x AZF0ENDPOINT_DATA %s' % (ir + 1, val, note)]
    pre = ['# audio endpoint %d: sink capabilities and name (from the EDID)' % (2 if dp else 1)]
    for v in (0x80000001, 1, 0, 1): pre += w(0x54, v, 'hot plug control')
    pre += w(0x25, (0x20000 if dp else 0x10000) | spk, 'speaker allocation, ' + ('DP' if dp else 'HDMI')) + w(0x27, 0)
    pre += w(0x28, (sad[0] & 7) | sad[1] << 8 | sad[2] << 16 | sad[1] << 24, 'LPCM: channels - 1, rates, sample sizes')
    for idx in (0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x31, 0x32, 0x33, 0x35): pre += w(idx, 0)
    pre += w(0x38, 1) + w(0x37, 0) + w(0x37, 0)
    pre += w(0x3a, e[8] | e[9] << 8 | e[10] << 16 | e[11] << 24, 'manufacturer, product') + w(0x3b, len(name) + 1 if name else 0)
    pre += w(0x3c, 0x5558859e, 'port id') + w(0x3d, 0x0d989449)
    padded = name + bytes(20 - len(name))
    for k in range(5): pre += w(0x3e + k, int.from_bytes(padded[k * 4:k * 4 + 4], 'little'), 'name')
    post = ['# audio endpoint on (after the link is up)'] + w(0x54, 0x10) + w(0x54, 0x80000001) + w(0x54, 0x80000000)
    return pre, post

def gen(m, outdir, edid=b'', dp=None):
    captured = not os.environ.get('HDMIMODE_FORCE') and (m['pclk'], m['ha'], m['va'], m['ht'], m['vt'], m['hss'], m['hse'], m['vss'], m['vse']) == (244800, 2560, 1440, 2720, 1500, 2608, 2640, 1443, 1448)
    ha, va, ht, vt, pclk = m['ha'], m['va'], m['ht'], m['vt'], m['pclk']
    hsw = m['hse'] - m['hss']; hbe = ht - m['hss']          # sync width; sync + back porch (blank end, counted from sync start)
    vsw = m['vse'] - m['vss']; vbe = vt - m['vss']
    pitch = (ha + 63) & ~63
    vstart = 13; fp2 = max(0, vstart - vbe)
    dlg = {0x3b8d: 0x300, 0x3bc5: 0x55, 0x3bc6: 0, 0x3bc7: 0xe3000a64, 0x3bc8: 0x8000000, 0x3bc9: 0, 0x3bca: 0, 0x3bcc: 0,
           0x3be0: vbe << 16 | min(0x3ff, hbe * 24000 // pclk), 0x3be1: 0, 0x3be2: 0, 0x3be3: 0, 0x3be4: 0x28080000, 0x3be6: 0x301, 0x3be7: 0,
           0x3be9: 0, 0x3bea: 0, 0x3beb: 0, 0x3bec: 0, 0x3bed: 0, 0x3bee: 0, 0x3bef: 0, 0x3bf2: 0, 0x3bf3: 0, 0x3bf6: 0, 0x3bf7: 0, 0x3bf9: 0}
    geo = {0x15a: lambda o: 0xff0000 | min(255, math.ceil(pclk / 584000 * 255) + 6),   # DPP clock >= pixel clock (display clock ~584 MHz)
           0x506a: lambda o: ht - 1, 0x506c: lambda o: hsw << 16, 0x506b: lambda o: hbe << 16 | (hbe + ha), 0x506d: lambda o: 0 if m['hpos'] else 1,
           0x506f: lambda o: vt - 1, 0x5071: lambda o: vt - 1 if o else 0, 0x5070: lambda o: vt - 1 if o else 0,
           0x5077: lambda o: vsw << 16, 0x5076: lambda o: vbe << 16 | (vbe + va), 0x5078: lambda o: 0 if m['vpos'] else 1,
           0x39ee: lambda o: (o & 0x80000000) | (vbe + va) << 16 | fp2,
           0x50c6: lambda o: vstart, 0x50c7: lambda o: math.ceil(pclk / 2000) << 16 | ht // 4, 0x50c8: lambda o: math.ceil(pclk * 0.61 / 1000),
           0x4d70: lambda o: ha << 16 | va, 0x3ba3: lambda o: pitch - 1,
           0x16d: lambda o: pclk * 10, 0x5668: lambda o: pclk << 12, 0x566a: lambda o: pclk << 12, 0x566c: lambda o: pclk << 12,
           0x3b8f: lambda o: {0xf001b: 0xe1011, 0xf001a: 0xe1010}.get(o, o), 0x565b: lambda o: 3 if o == 0x3003 else o}
    for r in (0x433d, 0x433e, 0x3b86, 0x3b8a, 0x3b88, 0x3b8c): geo[r] = lambda o: va << 16 | ha
    for r, v in dlg.items(): geo[r] = (lambda v: lambda o: v)(v)
    for src, dst in (('plan_signal.txt', 'signal.txt'), ('plan_plane6.txt', 'plane.txt'), ('plan_audio.txt', 'audio.txt')):
        lines = open(os.path.join(HERE, src)).read().split('\n'); out = []; avi = -1
        for ln in lines:
            f = ln.split()
            if captured or not f or f[0] not in ('w', 'd'): out.append(ln); continue
            if f[0] == 'd':
                w0 = int(f[1], 16); w1 = int(f[2], 16)
                if w0 & 0xffffffff == 0x10000280 and w0 >> 32: w0 = (pclk * 10) << 32 | 0x10000280            # SET_PIXEL_CLOCK, 100 Hz units
                elif w0 & 0xffffffff == 0x0c000080: w1 = pclk // 10                                           # DIGx encoder control, 10 kHz
                elif w0 == 0x040301013c000180: w1 = (w1 & ~0xffff) | pclk // 10                               # transmitter enable
                out.append('d %016x %x' % (w0, w1) if f[0] == 'd' and w1 < 1 << 32 else 'd %016x %016x' % (w0, w1)); continue
            reg = int(f[1], 16); old = int(f[2], 16); new = old
            if reg == 0x5628: avi = 0 if old == 0 else -1
            elif reg == 0x5629 and avi >= 0:                 # the AVI infoframe: bar fields carry the totals + 1, then the checksum
                if avi == 0: pkt = [None] * 5
                if avi < 5:
                    pkt[avi] = old
                    if avi == 3: new = vt + 1
                    if avi == 4: new = ht + 1
                    pkt[avi] = new
                    if avi == 4:
                        body = [pkt[0] & 0xff, pkt[0] >> 8 & 0xff, pkt[0] >> 16 & 0xff] + [pkt[1] >> 8 & 0xff, pkt[1] >> 16 & 0xff, pkt[1] >> 24]
                        for w in pkt[2:]: body += [w & 0xff, w >> 8 & 0xff, w >> 16 & 0xff, w >> 24]
                        cs = (-sum(body)) & 0xff
                        for i in range(len(out) - 1, -1, -1):          # the word with the checksum was written three lines back
                            g = out[i].split()
                            if len(g) > 2 and g[1] == '5629' and int(g[2], 16) == pkt[1]:
                                out[i] = 'w 5629 %x %s' % ((pkt[1] & ~0xff) | cs, ' '.join(g[3:])); break
                avi += 1
            elif reg in geo: new = geo[reg](old)
            out.append('w %x %x %s' % (reg, new & 0xffffffff, ' '.join(f[3:])))
        open(os.path.join(outdir, dst), 'w').write('\n'.join(out))
    if dp:      # DisplayPort on the USB-C port: the DP templates with the same geometry, DP DTO, MSA and M/N for the link rate
        lanes, rate = dp
        fixed = captured and rate == 0x14 and lanes == 2
        dpm = {0x145: pclk * 1000, 0x146: 598874000,                      # DP DTO: pixel clock over the 598.874 MHz reference, in Hz
               0x580c: ht << 16 | vt, 0x580d: hbe << 16 | vbe,
               0x580e: (0 if m['hpos'] else 1) << 31 | hsw << 16 | (0 if m['vpos'] else 1) << 15 | vsw, 0x580f: ha << 16 | va,
               0x57d2: round(32768 * pclk / (rate * 27000)), 0x57cb: lanes - 1}
        for src, dst in (('plan_dp_pre.txt', 'dp_pre.txt'), ('plan_dp_post.txt', 'dp_post.txt'), ('plan_dp_plane.txt', 'dp_plane.txt')):
            out = []
            for ln in open(os.path.join(HERE, src)).read().split('\n'):
                f = ln.split()
                if fixed or not f or f[0] != 'w': out.append(ln); continue
                reg = int(f[1], 16); old = int(f[2], 16)
                new = dpm[reg] if reg in dpm else geo[reg](old) if reg in geo and not captured else old
                out.append('w %x %x %s' % (reg, new & 0xffffffff, ' '.join(f[3:])))
            open(os.path.join(outdir, dst), 'w').write('\n'.join(out))
        ep = audio_endpoint(edid, True) if len(edid) >= 256 else None
        if ep:      # DP audio as Linux sets it: audio DTO1 from the DP reference clock, AFMT2 fed by endpoint 2, DP secondary data packets
            a = ['# DP audio: audio DTO1 (48 kHz family over the 598.874 MHz DP reference), AFMT2', 'w 3521 0 DCCG_AUDIO_DTBCLK_DTO_PHASE', 'w 3522 0 DCCG_AUDIO_DTBCLK_DTO_MODULO',
                 'w 16b 100030 DCCG_AUDIO_DTO_SOURCE', 'w 16b 100010 DCCG_AUDIO_DTO_SOURCE', 'w 16f 5b6184 DCCG_AUDIO_DTO1_MODULE', 'w 16e 3a980 DCCG_AUDIO_DTO1_PHASE',
                 'w 5745 2 AFMT2_AFMT_AUDIO_SRC_CONTROL', 'w 5735 300 AFMT2_AFMT_AUDIO_PACKET_CONTROL2']
            b = ['# DP audio on: secondary data packets (audio stream, timestamp, info frame)', 'w 5770 1 DIG2_AFMT_CNTL', 'w 57f1 8000 DP2_DP_SEC_AUD_N', 'w 57f5 1 DP2_DP_SEC_TIMESTAMP',
                 'w 5747 101 AFMT2_AFMT_MEM_PWR', 'w 5742 4000800 AFMT2_AFMT_AUDIO_PACKET_CONTROL', 'w 5735 300 AFMT2_AFMT_AUDIO_PACKET_CONTROL2', 'w 5743 80 AFMT2_AFMT_INFOFRAME_CONTROL0',
                 'w 5738 0 AFMT2_AFMT_60958_0', 'w 57eb 10 DP2_DP_SEC_CNTL', 'w 57eb 1110 DP2_DP_SEC_CNTL', 'w 57eb 1111 DP2_DP_SEC_CNTL', 'w 5747 1 AFMT2_AFMT_MEM_PWR',
                 'w 5742 4000801 AFMT2_AFMT_AUDIO_PACKET_CONTROL']
            open(os.path.join(outdir, 'dp_audio.txt'), 'w').write('\n'.join(a + ep[0]) + '\n')
            open(os.path.join(outdir, 'dp_audio_on.txt'), 'w').write('\n'.join(b + ep[1]) + '\n')
    ep = audio_endpoint(edid) if len(edid) >= 256 else None
    if ep:
        with open(os.path.join(outdir, 'audio.txt'), 'a') as f: f.write('\n' + '\n'.join(ep[0]) + '\n')
        open(os.path.join(outdir, 'audio_on.txt'), 'w').write('\n'.join(ep[1]) + '\n')
    open(os.path.join(outdir, 'mode.txt'), 'w').write('%d %d %d %d %d %d %d %d %d %d\n' % (ha, va, pclk, ht, m['hss'], m['hse'], vt, m['vss'], m['vse'],
                                                                                         m['hpos'] | m['vpos'] << 1))
    return captured, pitch

if __name__ == '__main__':
    e = open(sys.argv[1], 'rb').read()
    want = None; dp = None
    if '--dp' in sys.argv:                 # --dp <lanes> <rate code>: the trained link; it bounds the pixel clock (8 bpc RGB)
        i = sys.argv.index('--dp'); dp = (int(sys.argv[i + 1]), int(sys.argv[i + 2], 0)); del sys.argv[i:i + 3]
        MAXCLK = int(dp[0] * dp[1] * 9000 * 0.97)      # lanes x rate x 0.27 Gbit/s x 8/10, over 24 bits a pixel, some margin
    if len(sys.argv) > 3 and 'x' in sys.argv[3]:
        size, _, r = sys.argv[3].partition('@')
        w, h = size.split('x'); want = (int(w), int(h), float(r) if r else None)
    m = pick(e, want)
    os.makedirs(sys.argv[2], exist_ok=True)
    cap, pitch = gen(m, sys.argv[2], e, dp)
    print('mode %dx%d@%.2f pclk %d kHz totals %dx%d pitch %d (%s)' % (m['ha'], m['va'], m['pclk'] * 1000 / (m['ht'] * m['vt']), m['pclk'], m['ht'], m['vt'],
          pitch, 'captured values' if cap else 'generated, firmware-style requests'))
