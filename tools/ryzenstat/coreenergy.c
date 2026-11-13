// coreenergy: per-core and package power from AMD energy MSRs via AMDRyzenCPUPowerManagement selector 42 (all-CPU rdmsr).
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static io_connect_t c;
static int all(uint32_t a, uint64_t *v){ uint64_t in[1]={a},so[1]; uint32_t sn=1; size_t sz=64*8;
    if(IOConnectCallMethod(c,42,in,1,NULL,0,so,&sn,v,&sz)){fprintf(stderr,"rdmsr-all failed (root? new kext?)\n");exit(1);} return (int)so[0]; }
int main(int argc,char**argv){ int secs=argc>1?atoi(argv[1]):10;
    io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AMDRyzenCPUPowerManagement"));
    if(!s||IOServiceOpen(s,mach_task_self(),0,&c)){fprintf(stderr,"open failed\n");return 1;}
    if(argc>2){ uint64_t v[64]; int n=all((uint32_t)strtoul(argv[2],0,16),v); for(int i=0;i<n;i++) printf("cpu%d 0x%016llx\n",i,v[i]); return 0; }
    uint64_t u[64],a[64],b[64],pa[64],pb[64]; all(0xC0010299,u); double esu=1.0/(1<<((u[0]>>8)&0x1f));
    int n=all(0xC001029A,a); all(0xC001029B,pa); sleep(secs); all(0xC001029A,b); all(0xC001029B,pb);
    double sum=0; for(int i=0;i<n;i+=2){ double w=(double)((b[i]-a[i])&0xffffffff)*esu/secs; sum+=w; printf("core%d %.2f W\n",i/2,w);} 
    double pk=(double)((pb[0]-pa[0])&0xffffffff)*esu/secs;
    printf("cores %.2f W, package %.2f W, rest (GPU+SoC) %.2f W\n",sum,pk,pk-sum); return 0; }
