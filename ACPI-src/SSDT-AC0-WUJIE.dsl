// AC adapter for macOS on WUJIE15XA: firmware \_SB.AC0._PSR also calls AMD ALIB and fails under macOS.
// Needs ACPI patch _PSR -> XPSR (DSDT, find 5F50535200 replace 5850535200, count 1).
DefinitionBlock ("", "SSDT", 2, "WUJIE", "AC0PSR", 0x00001000)
{
    External (_SB_.AC0, DeviceObj)
    External (_SB_.AC0.XPSR, MethodObj)
    External (_SB_.MUEX, MutexObj)
    External (ECON, IntObj)
    External (_SB_.PCI0.SBRG.EC0.XCIN, FieldUnitObj)

    Scope (\_SB.AC0)
    {
        Method (_PSR, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                Local0 = One
                Acquire (\_SB.MUEX, 0xFFFF)
                If (ECON)
                {
                    Local0 = \_SB.PCI0.SBRG.EC0.XCIN
                }
                Release (\_SB.MUEX)
                Return (Local0)
            }

            Return (XPSR ())
        }
    }
}
