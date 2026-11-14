// WujieSleepPolicy: makes every system sleep a hibernation on a machine whose firmware has no working S3.
//
// The MECHREVO WUJIE15XA (Phoenix, Modern Standby only) hides _S3 (XS3 in the DSDT). With the name patched back, macOS
// starts sleeping, X86PlatformPlugin's policy picks kIOPMSleepTypeDeepIdle, hibernation setup is skipped and the
// platform enters S3 - from which this firmware never wakes. IOPMrootDomain takes one policy handler, first come first
// served; this kext installs its own before the platform plugin and always answers "hibernate" (image written, power
// off) when hibernation is enabled (pmset hibernatemode 25), and "abort" otherwise, so S3 is never entered.
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/pwr_mgt/RootDomain.h>
#include <IOKit/IONVRAM.h>
#include <IOKit/IOMessage.h>
#include <sys/sysctl.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <kern/thread_call.h>

struct PolicyVars {            // IOPMSystemSleepPolicyVariables (xnu IOPMPrivate.h)
    uint32_t signature, version; uint64_t currentCapability, highestCapability, sleepFactors;
    uint32_t sleepReason, sleepPhase, hibernateMode, standbyDelay, standbyTimer, poweroffDelay, scheduledAlarms, poweroffTimer;
    uint32_t reserved[49];
};
struct SleepParams {           // IOPMSystemSleepParameters, version 2
    uint16_t version, reserved1; uint32_t sleepType, sleepFlags, ecWakeEvents, ecWakeTimer, ecPoweroffTimer; uint32_t reserved2[10];
} __attribute__((packed));
enum { kTypeAborted = 1, kTypeNormal = 2, kTypeSafeSleep = 3, kTypeHibernate = 4, kHibOn = 1, kHibSleep = 2 };

static int gInstalled, gCalls, gLastType, gLastMode, gAllowS3;
SYSCTL_INT(_debug, OID_AUTO, wujiesleep_installed, CTLFLAG_RD, &gInstalled, 0, "1 = our sleep policy handler is the system's, -1 = another one was first");
SYSCTL_INT(_debug, OID_AUTO, wujiesleep_calls, CTLFLAG_RD, &gCalls, 0, "");
SYSCTL_INT(_debug, OID_AUTO, wujiesleep_last_type, CTLFLAG_RD, &gLastType, 0, "sleep type of the last answer");
SYSCTL_INT(_debug, OID_AUTO, wujiesleep_last_mode, CTLFLAG_RD, &gLastMode, 0, "hibernate mode seen last");
SYSCTL_INT(_debug, OID_AUTO, wujiesleep_allow_s3, CTLFLAG_RW, &gAllowS3, 0, "1 = answer normal sleep when hibernation is off (hangs on this firmware)");

static IOReturn policy(void *, const PolicyVars *vars, SleepParams *params) {
    if (!vars || !params) return kIOReturnBadArgument;
    bzero(params, sizeof(*params));
    params->version = 2;
    const uint32_t mode = vars->hibernateMode;
    params->sleepType = (mode & kHibOn) ? kTypeHibernate : (gAllowS3 ? kTypeNormal : kTypeAborted);
    gCalls++; gLastType = (int)params->sleepType; gLastMode = (int)mode;
    return kIOReturnSuccess;
}

// The hibernation key. IOHibernateSystemSleep() leaves it in the root domain property "IOHibernateRTCVariables" for
// AppleRTC to store in the extended CMOS a Mac has. Here nothing stores it: OpenCore reports "RTC hibernation is 0,
// NVRAM hibernation is 0 / Not Found", boot.efi cannot read boot-signature / boot-image-key, logs EB|H:FAIL and resets.
// boot.efi and OpenCore also accept the same bytes from the NVRAM variable of that name, so once a sleep starts the
// property is copied to NVRAM and synced (what HibernationFixup does by hooking the kernel; it did not on this macOS).
static int gKeyWrites, gCapMsgs;
SYSCTL_INT(_debug, OID_AUTO, wujiesleep_key_writes, CTLFLAG_RD, &gKeyWrites, 0, "hibernation key copies written to NVRAM");
// Called from setPowerState(0). The order inside a sleep is: priority notifications -> willNotifyPowerChildren, where
// IOHibernateSystemSleep() creates the key property -> the root domain's children power down (this service is one) ->
// IOHibernateSystemHasSlept() stores boot-image and syncs NVRAM -> the image is written. So the property exists by
// now and the kernel's own sync a moment later flushes this variable too: only setProperty here. An earlier version
// polled from a thread_call and synced by itself; with it the machine reset or hung while going to sleep.
static void copyKey(void) {
    gCapMsgs++;
    IOPMrootDomain *root = IOService::getPMRootDomain();
    OSObject *o = root ? root->copyProperty("IOHibernateRTCVariables") : nullptr;
    OSData *d = OSDynamicCast(OSData, o);
    IORegistryEntry *e = IORegistryEntry::fromPath("/options", gIODTPlane);
    IODTNVRAM *nv = OSDynamicCast(IODTNVRAM, e);
    if (nv) {
        if (d && d->getLength()) {
            const OSSymbol *k = OSSymbol::withCString("IOHibernateRTCVariables");
            OSData *c = OSData::withBytes(d->getBytesNoCopy(), d->getLength());
            if (k && c && nv->setProperty(k, c)) gKeyWrites++;
            if (c) c->release();
            if (k) k->release();
        }
        // what happened, readable after the next boot: "<capability messages> <key length> <key copies>"
        char note[48]; snprintf(note, sizeof note, "%d %u %d", gCapMsgs, d ? d->getLength() : 0, gKeyWrites);
        const OSSymbol *nk = OSSymbol::withCString("wujie-sleep-note");
        OSData *nd = OSData::withBytes(note, (unsigned int)strlen(note));
        if (nk && nd) nv->setProperty(nk, nd);
        if (nd) nd->release();
        if (nk) nk->release();
    }
    if (e) e->release();
    if (o) o->release();
}

// After a hibernation the embedded controller has been through a power cycle and is back in its non-ACPI mode: it no
// longer raises its queries, so closing the lid (_Q19) does nothing and the brightness keys (_Q11/_Q12) are dead, while
// keys the keyboard controller reports itself (volume, keyboard backlight) still work. The firmware tells the EC which
// OS runs in EC0._REG (XSEC = OSEC) and again in _WAK, but there only for Arg0 == 4, which macOS does not pass on this
// path. Running EC0._REG(3, 1) again after every wake puts the EC back into ACPI mode.
static int gEcReg = 0, gEcRegLast = -1;
SYSCTL_INT(_debug, OID_AUTO, wujiesleep_ecreg, CTLFLAG_RD, &gEcReg, 0, "EC0._REG evaluations after a wake");
SYSCTL_INT(_debug, OID_AUTO, wujiesleep_ecreg_last, CTLFLAG_RD, &gEcRegLast, 0, "result of the last one (0 = ok)");
static void ecRegister(thread_call_param_t, thread_call_param_t) {
    static const char *const paths[] = { "IOACPIPlane:/_SB/PCI0/SBRG/EC0", "IOACPIPlane:/_SB/PCI0/LPCB/EC0", "IOACPIPlane:/_SB/PCI0/LPC0/EC0" };
    for (const char *path : paths) {
        IORegistryEntry *e = IORegistryEntry::fromPath(path);
        if (!e) continue;
        if (e->metaCast("IOACPIPlatformDevice")) {
            IOACPIPlatformDevice *ec = static_cast<IOACPIPlatformDevice *>(e);
            OSObject *args[2] = { OSNumber::withNumber(3ull, 32), OSNumber::withNumber(1ull, 32) };   // EmbeddedControl, connect
            gEcRegLast = (args[0] && args[1]) ? ec->evaluateObject("_REG", nullptr, args, 2) : -2;
            if (args[0]) args[0]->release();
            if (args[1]) args[1]->release();
            gEcReg++;
            IOLog("WujieSleepPolicy: %s._REG(3, 1) after wake -> 0x%x\n", path, gEcRegLast);
        }
        e->release();
        return;
    }
    IOLog("WujieSleepPolicy: no EC0 found, nothing re-registered\n");
}
static thread_call_t gEcCall;

class WujieSleepPolicy : public IOService {
    OSDeclareDefaultStructors(WujieSleepPolicy)
public:
    bool start(IOService *provider) override;
    IOReturn setPowerState(unsigned long ordinal, IOService *whatDevice) override;
};
OSDefineMetaClassAndStructors(WujieSleepPolicy, IOService)

bool WujieSleepPolicy::start(IOService *provider) {
    if (!IOService::start(provider)) return false;
    sysctl_register_oid(&sysctl__debug_wujiesleep_installed); sysctl_register_oid(&sysctl__debug_wujiesleep_calls);
    sysctl_register_oid(&sysctl__debug_wujiesleep_last_type); sysctl_register_oid(&sysctl__debug_wujiesleep_last_mode);
    sysctl_register_oid(&sysctl__debug_wujiesleep_allow_s3);
    IOPMrootDomain *root = getPMRootDomain();
    const OSSymbol *fn = OSSymbol::withCString("IOPMInstallSystemSleepPolicyHandler");
    IOReturn r = (root && fn) ? root->callPlatformFunction(fn, false, (void *)&policy, this, nullptr, nullptr) : kIOReturnNotReady;
    if (fn) fn->release();
    gInstalled = r == kIOReturnSuccess ? 1 : -1;
    IOLog("WujieSleepPolicy: install -> 0x%x (%s)\n", r, r == kIOReturnSuccess ? "ours" : "another handler was first");
    sysctl_register_oid(&sysctl__debug_wujiesleep_key_writes);
    sysctl_register_oid(&sysctl__debug_wujiesleep_ecreg); sysctl_register_oid(&sysctl__debug_wujiesleep_ecreg_last);
    gEcCall = thread_call_allocate(ecRegister, nullptr);
    static IOPMPowerState states[2] = {
        { kIOPMPowerStateVersion1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        { kIOPMPowerStateVersion1, kIOPMPowerOn, kIOPMPowerOn, kIOPMPowerOn, 0, 0, 0, 0, 0, 0, 0, 0 } };
    PMinit(); provider->joinPMtree(this); registerPowerDriver(this, states, 2);
    registerService();
    return true;
}

IOReturn WujieSleepPolicy::setPowerState(unsigned long ordinal, IOService *) {
    static bool slept = false;   // not at the initial power-on, where the EC driver registers the region itself
    if (ordinal == 0) { slept = true; copyKey(); }
    else if (gEcCall && slept) {   // two seconds after power-on: the ACPI EC driver is awake by then
        uint64_t d; clock_interval_to_deadline(2000, kMillisecondScale, &d);
        thread_call_enter_delayed(gEcCall, d);
    }
    return kIOPMAckImplied;
}
