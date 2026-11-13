// WujieXhciIntx: make AMD xHCI secondary-interrupter events reach AppleUSBXHCI without polling.
//
// AppleUSBXHCI puts transfer events of non-isochronous endpoints on interrupter 1 and isochronous ones on
// interrupter 2, but services all rings from the single MSI vector of the device. The AMD Phoenix controllers
// advertise one MSI message and a one-entry MSI-X table, and only interrupter 0 raises that message, so HID
// events wait up to 2 s (the usual workaround polls every millisecond).
//
// In legacy INTx mode the pin is the OR of every interrupter's pending bit, so this kext switches the device
// to INTx, attaches its own level interrupt source (interrupt index 0, the IOAPIC pin) to the controller's
// work loop, acknowledges the pending bits and signals Apple's own interrupt event source.
//
// Control: sysctl debug.wujiexhci = 1 (INTx on) / 0 (back to MSI). Boot-arg wujiexhci=1 applies it 5 s after start.
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/IOFilterInterruptEventSource.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/RootDomain.h>
#include <pexpert/pexpert.h>
#include <sys/sysctl.h>

#define MAXC 8
struct Ctl {
    IOService *ctrl; IOPCIDevice *pci; IOWorkLoop *wl; IOMemoryMap *map; volatile uint8_t *base;
    uint32_t op, rt, nintr; uint8_t msiOff;
    IOFilterInterruptEventSource *appleES, *myES;
    bool intx, dead, stop; uint32_t irqs, spurious, winIrqs; uint64_t winStart;
};
static uint64_t gStart, gDelayMs, gWinTicks;
static Ctl gC[MAXC]; static int gN; static int gMode; static int gIrqs, gSpurious, gStormReverts;

struct ESPeek : IOEventSource { static IOEventSource *next(IOEventSource *e) { return static_cast<ESPeek *>(e)->getNext(); } };
struct WLPeek : IOWorkLoop { static IOEventSource *chain(IOWorkLoop *w) { return static_cast<WLPeek *>(w)->eventChain; } };

static inline uint32_t rd(Ctl *c, uint32_t o) { return *(volatile uint32_t *)(c->base + o); }
static inline void wr(Ctl *c, uint32_t o, uint32_t v) { *(volatile uint32_t *)(c->base + o) = v; }
static inline uint32_t iman(Ctl *c, uint32_t i) { return c->rt + 0x20 + 32 * i; }

class WujieXhciIntx : public IOService {
    OSDeclareDefaultStructors(WujieXhciIntx)
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    IOTimerEventSource *timer;
    static bool filter(OSObject *owner, IOFilterInterruptEventSource *src);
    static void action(OSObject *owner, IOInterruptEventSource *src, int count);
    static IOReturn gatedSwitch(OSObject *owner, void *a0, void *a1, void *, void *);
    void discover();
    void setMode(int on);
};
OSDefineMetaClassAndStructors(WujieXhciIntx, IOService)
static WujieXhciIntx *gSelf;

static Ctl *byES(void *es) { for (int i = 0; i < gN; i++) if (gC[i].myES == es) return &gC[i]; return nullptr; }

// Primary interrupt context. Run Apple's own interrupt path first, with IMAN.IP still set, exactly as an MSI on that
// interrupter would (v1-v3 cleared IP and only signalled the action: interrupter 1 worked, the isochronous ring on
// interrupter 2 was never drained and the camera delivered no frames). Then drop the level line ourselves: under MSI
// the controller clears IP by itself, so Apple's code may not.
bool WujieXhciIntx::filter(OSObject *, IOFilterInterruptEventSource *src) {
    Ctl *c = byES(src);
    if (!c || !c->intx) return false;
    bool pend = rd(c, c->op + 4) & 0x8;                       // USBSTS.EINT
    for (uint32_t i = 0; !pend && i < c->nintr; i++) pend = rd(c, iman(c, i)) & 1;
    if (!pend) { c->spurious++; gSpurious++; return false; }
    c->irqs++; gIrqs++;
    uint64_t now = mach_absolute_time();
    if (now - c->winStart > gWinTicks) { c->winStart = now; c->winIrqs = 0; }
    bool alive = c->appleES && c->appleES->getWorkLoop() == c->wl && !c->ctrl->isInactive();
    if (!alive || ++c->winIrqs > 5000) { c->stop = true; return true; }   // level source: masked until action() detaches
    c->appleES->normalInterruptOccurred(nullptr, c->pci, 0);
    wr(c, c->op + 4, 0x8);                                    // USBSTS.EINT is RW1C
    for (uint32_t i = 0; i < c->nintr; i++) { uint32_t v = rd(c, iman(c, i)); if (v & 1) wr(c, iman(c, i), v); }  // IMAN.IP RW1C, IE kept
    return false;
}

static void toMsi(Ctl *c) {
    c->pci->configWrite16(kIOPCIConfigCommand, c->pci->configRead16(kIOPCIConfigCommand) | 0x400);
    c->pci->configWrite16(c->msiOff + 2, c->pci->configRead16(c->msiOff + 2) | 1);
    c->intx = false;
}

// Work loop context, only reached when filter() gave up: >50k interrupts/s (stuck pin) or Apple's source is gone
// (it leaves the work loop when the controller stops at shutdown; signalling it then is a NULL dereference).
void WujieXhciIntx::action(OSObject *, IOInterruptEventSource *src, int) {
    Ctl *c = byES(src);
    if (!c || !c->stop) return;
    c->stop = false;
    bool alive = c->appleES && c->appleES->getWorkLoop() == c->wl && !c->ctrl->isInactive();
    toMsi(c); src->disable();
    if (alive) { gStormReverts++; IOLog("WujieXhciIntx: interrupt storm on %s, back to MSI\n", c->pci->getName()); c->appleES->signalInterrupt(); return; }
    if (c->appleES) { c->appleES->release(); c->appleES = nullptr; }
    c->dead = true;
    IOLog("WujieXhciIntx: %s: controller stopped, detached\n", c->pci->getName());
}

// Work-loop gated. Locate (and retain) Apple's interrupt event source on the controller's work loop.
static void findApple(Ctl *c) {
    if (c->appleES && c->appleES->getWorkLoop() != c->wl) { c->appleES->release(); c->appleES = nullptr; }
    if (c->appleES) return;
    for (IOEventSource *e = WLPeek::chain(c->wl); e; e = ESPeek::next(e)) {
        IOFilterInterruptEventSource *f = OSDynamicCast(IOFilterInterruptEventSource, e);
        if (f && f != c->myES && (f->getProvider() == c->pci || f->getProvider() == c->ctrl)) { c->appleES = f; f->retain(); break; }
    }
}

// Boot phase: poll like PhxXhciKick until the INTx switch is applied.
static IOReturn gatedKick(OSObject *, void *a0, void *, void *, void *) {
    Ctl *c = (Ctl *)a0;
    if (c->dead || c->intx || c->ctrl->isInactive()) return kIOReturnSuccess;
    findApple(c);
    if (c->appleES) c->appleES->signalInterrupt();
    return kIOReturnSuccess;
}

IOReturn WujieXhciIntx::gatedSwitch(OSObject *, void *a0, void *a1, void *, void *) {
    Ctl *c = (Ctl *)a0; bool on = a1 != nullptr;
    if (c->dead) return kIOReturnOffline;
    if (on && c->appleES && c->appleES->getWorkLoop() != c->wl) { c->appleES->release(); c->appleES = nullptr; }
    if (on && !c->intx) {
        findApple(c);
        if (!c->appleES) { IOLog("WujieXhciIntx: %s: Apple interrupt source not found\n", c->pci->getName()); return kIOReturnNotFound; }
        c->winStart = mach_absolute_time(); c->winIrqs = 0;
        c->intx = true;
        c->myES->enable();
        c->pci->configWrite16(c->msiOff + 2, c->pci->configRead16(c->msiOff + 2) & ~1);
        c->pci->configWrite16(kIOPCIConfigCommand, c->pci->configRead16(kIOPCIConfigCommand) & ~0x400);
        c->appleES->signalInterrupt();
    } else if (!on && c->intx) {
        toMsi(c); c->myES->disable();
    }
    return kIOReturnSuccess;
}

void WujieXhciIntx::discover() {
    if (gN) return;
    OSDictionary *m = serviceMatching("AppleUSBXHCIPCI");
    OSIterator *it = m ? getMatchingServices(m) : nullptr;
    if (m) m->release();
    if (!it) return;
    while (OSObject *o = it->getNextObject()) {
        IOService *ctrl = OSDynamicCast(IOService, o);
        IOPCIDevice *pci = ctrl ? OSDynamicCast(IOPCIDevice, ctrl->getProvider()) : nullptr;
        if (!pci || gN >= MAXC || pci->configRead16(kIOPCIConfigVendorID) != 0x1022) continue;
        Ctl *c = &gC[gN];
        bzero(c, sizeof(*c));
        uint8_t off = 0;
        if (!pci->findPCICapability(kIOPCIMSICapability, &off) || !off) continue;
        if (!(pci->configRead16(off + 2) & 1)) { IOLog("WujieXhciIntx: %s not in MSI mode, skipped\n", pci->getName()); continue; }
        c->wl = ctrl->getWorkLoop();
        c->map = pci->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress0);
        if (!c->wl || !c->map) { if (c->map) c->map->release(); continue; }
        c->ctrl = ctrl; c->pci = pci; c->msiOff = off;
        c->base = (volatile uint8_t *)c->map->getVirtualAddress();
        c->op = rd(c, 0) & 0xff; c->rt = rd(c, 0x18) & ~0x1fu;
        c->nintr = (rd(c, 4) >> 8) & 0x7ff; if (c->nintr > 8) c->nintr = 8;
        c->myES = IOFilterInterruptEventSource::filterInterruptEventSource(this, &WujieXhciIntx::action, &WujieXhciIntx::filter, pci, 0);
        if (!c->myES || c->wl->addEventSource(c->myES) != kIOReturnSuccess) {
            IOLog("WujieXhciIntx: %s: no INTx source\n", pci->getName());
            if (c->myES) { c->myES->release(); c->myES = nullptr; } c->map->release(); continue;
        }
        c->myES->disable();
        ctrl->retain(); pci->retain(); c->wl->retain();
        IOLog("WujieXhciIntx: %s op=0x%x rt=0x%x intrs=%u msi@0x%x\n", pci->getName(), c->op, c->rt, c->nintr, off);
        gN++;
    }
    it->release();
}

void WujieXhciIntx::setMode(int on) {
    discover();
    for (int i = 0; i < gN; i++) gC[i].wl->runAction(&WujieXhciIntx::gatedSwitch, this, &gC[i], on ? (void *)1 : nullptr);
    gMode = on ? 1 : 0;
    IOLog("WujieXhciIntx: mode %d on %d controllers\n", gMode, gN);
}

static int sysctl_mode SYSCTL_HANDLER_ARGS {
    int v = gMode;
    int err = sysctl_handle_int(oidp, &v, 0, req);
    if (err || !req->newptr) return err;
    if (gSelf) gSelf->setMode(v != 0);
    return 0;
}
SYSCTL_PROC(_debug, OID_AUTO, wujiexhci, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, 0, 0, sysctl_mode, "I", "AMD xHCI INTx mode");
SYSCTL_INT(_debug, OID_AUTO, wujiexhci_irqs, CTLFLAG_RD, &gIrqs, 0, "");
SYSCTL_INT(_debug, OID_AUTO, wujiexhci_spurious, CTLFLAG_RD, &gSpurious, 0, "");
SYSCTL_INT(_debug, OID_AUTO, wujiexhci_storms, CTLFLAG_RD, &gStormReverts, 0, "");

// A system sleep (a hibernation on this machine) power-cycles the controllers and AppleUSBXHCI brings them back with
// MSI enabled and INTx disabled again, while this kext still believed it was in INTx mode: after a wake the USB mouse
// answered once every few seconds. Go back to MSI before the sleep; after the wake poll for 3 s like at boot (the
// timer), then switch to INTx again.
static int gWakeRestore;
static IOReturn sleepWake(void *, void *, UInt32 type, IOService *, void *, vm_size_t) {
    if (!gSelf) return kIOReturnSuccess;
    if (type == kIOMessageSystemWillSleep) {
        gWakeRestore = gMode;
        if (gMode) gSelf->setMode(0);
    } else if (type == kIOMessageSystemHasPoweredOn && gWakeRestore && gSelf->timer) {
        gWakeRestore = 0;
        gStart = mach_absolute_time(); gDelayMs = 3000;
        gSelf->timer->setTimeoutMS(300);
    }
    return kIOReturnSuccess;
}

bool WujieXhciIntx::start(IOService *provider) {
    if (!IOService::start(provider)) return false;
    gSelf = this;
    sysctl_register_oid(&sysctl__debug_wujiexhci);
    sysctl_register_oid(&sysctl__debug_wujiexhci_irqs);
    sysctl_register_oid(&sysctl__debug_wujiexhci_spurious);
    sysctl_register_oid(&sysctl__debug_wujiexhci_storms);
    int arg = 0;
    PE_parse_boot_argn("wujiexhci", &arg, sizeof(arg));
    IOWorkLoop *wl = getWorkLoop();
    // wujiexhci=1: switch 45 s after load (system is up by then); wujiexhci=N (N>1): after N seconds. Until then poll every 2 ms.
    nanoseconds_to_absolutetime(100000000ULL, &gWinTicks);
    gDelayMs = (arg > 1 ? arg : 45) * 1000ULL; gStart = mach_absolute_time();
    timer = wl ? IOTimerEventSource::timerEventSource(this, [](OSObject *o, IOTimerEventSource *t) {
        static int tries;
        WujieXhciIntx *me = static_cast<WujieXhciIntx *>(o);
        me->discover();
        if (gN == 0) { if (++tries < 30) t->setTimeoutMS(2000); return; }
        uint64_t ns = 0; absolutetime_to_nanoseconds(mach_absolute_time() - gStart, &ns);
        if (gMode) return;                                    // switched by hand meanwhile
        if (ns / 1000000ULL < gDelayMs) {
            for (int i = 0; i < gN; i++) gC[i].wl->runAction(&gatedKick, me, &gC[i]);
            t->setTimeoutMS(2); return;
        }
        me->setMode(1);
    }) : nullptr;
    if (timer) { wl->addEventSource(timer); if (arg) timer->setTimeoutMS(3000); }
    registerPrioritySleepWakeInterest(&sleepWake, this, nullptr);
    IOLog("WujieXhciIntx loaded (boot-arg %d)\n", arg);
    registerService();
    return true;
}

void WujieXhciIntx::stop(IOService *provider) {
    setMode(0);
    IOService::stop(provider);
}
