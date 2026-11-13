import sys,struct,re
d=b''
for l in sys.stdin:
    m=re.match(r'vram\+0x[0-9a-f]+: (.*)',l)
    if m: d+=b''.join(struct.pack('<I',int(x,16)) for x in m.group(1).split())
u=lambda o,n=1: struct.unpack_from('<%dH'%n,d,o)
print('gfxclk %d socclk %d vclk %d dclk %d memclk %d | gfxAct %.2f%% uvdAct %.2f%%'%(u(0,5)+(u(12)[0]/100,u(14)[0]/100)))
print('VDD  %d mV %d mA %d mW | SOC %d mV %d mA %d mW'%(u(16)[0],u(20)[0],u(24)[0],u(18)[0],u(22)[0],u(26)[0]))
print('coreMHz',u(28,8)); print('core mW',u(44,8),'sum',sum(u(44,8)))
print('gfxT %.1f socT %.1f | socket %d mW | ApuPower %d mW'%(u(80)[0]/100,u(82)[0]/100,u(86)[0],struct.unpack_from('<I',d,92)[0]))
a=u(120,10); print('AVG gfxclk %d fclk %d gfxAct %.2f%% socclk %d vclk %d vcnAct %d | socket %d mW core %d mW'%(a[0],a[1],a[2]/100,a[3],a[4],a[5],a[8],a[9]))
print('C0 res %',[x/100 for x in u(140,8)],'counter',struct.unpack_from('<I',d,156)[0])
