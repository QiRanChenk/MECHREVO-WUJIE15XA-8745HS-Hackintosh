import sys,struct,re
d=b''
for l in sys.stdin:
    m=re.match(r'vram\+0x[0-9a-f]+: (.*)',l)
    if m: d+=b''.join(struct.pack('<I',int(x,16)) for x in m.group(1).split())
    if len(d)>=160:
        u=lambda o,n=1: struct.unpack_from('<%dH'%n,d,o)
        vdd=u(24)[0]; core=sum(u(44,8)); 
        print('VDD %5d mW  cores %5d  VDD-cores %5d | SOC %4d mW | Vvdd %d mV | gfxAct %.2f%% avgAct %.2f%% gfxclk %d avg %d'%(vdd,core,vdd-core,u(26)[0],u(16)[0],u(12)[0]/100,u(124)[0]/100,u(0)[0],u(120)[0]))
        d=b''
