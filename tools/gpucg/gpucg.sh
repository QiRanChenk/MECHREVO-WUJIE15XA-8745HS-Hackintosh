#!/bin/sh
# gpucg: enable Radeon 780M (GC 11.0.1) clock gating that nullarc leaves at reset defaults.
# Sequence follows Linux amdgpu gfx_v11_0_update_gfx_clock_gating(). Usage: gpucg.sh status|mgcg|cgcg|all|off
P=/Users/Shared/gpu/phxctl/phxctl
SAFE=0xA980; OVR=0xEC48; CGCG=0xEC49; CGCG3D=0xECC5; POLL=0x21C2; INT0=0x306A; SDMA=0x12BC
rd() { $P regs $1 | awk '{print $2}'; }
wr() { $P wreg $1 $2 >/dev/null; }
safe_enter() { wr $SAFE 0x3; i=0; while [ $i -lt 50 ]; do v=$(rd $SAFE); [ $(( v & 1 )) -eq 0 ] && return 0; i=$((i+1)); done; echo "safe mode: no ack ($v)"; return 1; }
safe_exit() { wr $SAFE 0x1; }
status() { for r in $SAFE $OVR $CGCG $CGCG3D $POLL $INT0 $SDMA; do printf "%s=%s " $r $(rd $r); done; echo; }
mgcg() { v=$(rd $OVR); wr $OVR $(printf "0x%x" $(( v & ~0x726 ))); }          # MGCG (0x26) + FGCG 0x100 + repeater FGCG 0x200 + perf clk 0x400
cgcg() {
  v=$(rd $OVR); wr $OVR $(printf "0x%x" $(( v & ~0x98 )))                     # CGCG 0x08, CGLS 0x10, 3D 0x80 overrides off
  v=$(rd $CGCG);   wr $CGCG   $(printf "0x%x" $(( (v & ~0x07FFFFFC) | (0x36 << 8) | (0xF << 2) | 0x3 )))
  v=$(rd $CGCG3D); wr $CGCG3D $(printf "0x%x" $(( (v & ~0x07FFFFFC) | (0x36 << 8) | (0xF << 2) | 0x3 )))
  wr $POLL 0x00900100
  v=$(rd $INT0); wr $INT0 $(printf "0x%x" $(( v | 0x003C0000 )))
  v=$(rd $SDMA); wr $SDMA $(printf "0x%x" $(( v | 0x2 )))
}
off() {
  v=$(rd $CGCG);   wr $CGCG   $(printf "0x%x" $(( v & ~0x3 )))
  v=$(rd $CGCG3D); wr $CGCG3D $(printf "0x%x" $(( v & ~0x3 )))
  v=$(rd $INT0); wr $INT0 $(printf "0x%x" $(( v & ~0x003C0000 )))
  v=$(rd $SDMA); wr $SDMA $(printf "0x%x" $(( v & ~0x2 )))
  v=$(rd $OVR); wr $OVR $(printf "0x%x" $(( v | 0x7BE )))
}
case "$1" in
  status) status ;;
  mgcg) safe_enter || exit 1; mgcg; safe_exit; status ;;
  cgcg) safe_enter || exit 1; cgcg; safe_exit; status ;;
  all)  safe_enter || exit 1; cgcg; mgcg; safe_exit; status ;;
  off)  safe_enter || exit 1; off; safe_exit; status ;;
  *) echo "usage: $0 status|mgcg|cgcg|all|off"; exit 2 ;;
esac
