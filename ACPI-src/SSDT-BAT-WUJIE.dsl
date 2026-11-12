// Battery for WUJIE15XA: 16-bit EC-region fields XIF3/XIF4/XIF7 split into bytes.
// Needs ACPI patch _BIF -> XBIF (DSDT only, find 5F42494600 replace 5842494600).
DefinitionBlock ("", "SSDT", 2, "WUJIE", "BATT", 0x00001000)
{
    External (_SB_.BAT0, DeviceObj)
    External (_SB_.BAT0.XBIF, MethodObj)
    External (_SB_.MUEX, MutexObj)
    External (ECON, IntObj)
    External (_SB_.PCI0.SBRG.EC0, DeviceObj)
    External (_SB_.PCI0.SBRG.EC0.XIF1, FieldUnitObj)
    External (_SB_.PCI0.SBRG.EC0.XIF2, FieldUnitObj)
    External (_SB_.PCI0.SBRG.EC0.ISDB, FieldUnitObj)
    External (_SB_.PCI0.SBRG.EC0.CYCN, FieldUnitObj)

    Method (B1B2, 2, NotSerialized)
    {
        Return ((Arg0 | (Arg1 << 0x08)))
    }

    Scope (\_SB.PCI0.SBRG.EC0)
    {
        OperationRegion (WBEC, EmbeddedControl, Zero, 0xFF)
        Field (WBEC, ByteAcc, Lock, Preserve)
        {
            Offset (0x06),
            XI30,   8,
            XI31,   8,
            XI40,   8,
            XI41,   8,
            Offset (0x0E),
            XI70,   8,
            XI71,   8
        }
    }

    Scope (\_SB.BAT0)
    {
        Method (_BIF, 0, NotSerialized)
        {
            If (!_OSI ("Darwin"))
            {
                Return (XBIF ())
            }

            Name (PAK0, Package (0x0D)
            {
                One,
                0x0C56,
                0x0C56,
                Zero,
                0x2A30,
                Zero,
                Zero,
                0x10,
                0x08,
                "standard",
                "00001",
                "LiON",
                "OEM"
            })
            If (ECON)
            {
                Acquire (\_SB.MUEX, 0xFFFF)
                PAK0 [One] = \_SB.PCI0.SBRG.EC0.XIF1
                If ((\_SB.PCI0.SBRG.EC0.ISDB == One))
                {
                    If ((\_SB.PCI0.SBRG.EC0.CYCN >= 0x32))
                    {
                        PAK0 [0x02] = \_SB.PCI0.SBRG.EC0.XIF2
                    }
                    Else
                    {
                        PAK0 [0x02] = \_SB.PCI0.SBRG.EC0.XIF1
                    }
                }
                Else
                {
                    PAK0 [0x02] = \_SB.PCI0.SBRG.EC0.XIF2
                }

                PAK0 [0x03] = B1B2 (\_SB.PCI0.SBRG.EC0.XI30, \_SB.PCI0.SBRG.EC0.XI31)
                PAK0 [0x04] = B1B2 (\_SB.PCI0.SBRG.EC0.XI40, \_SB.PCI0.SBRG.EC0.XI41)
                PAK0 [0x07] = B1B2 (\_SB.PCI0.SBRG.EC0.XI70, \_SB.PCI0.SBRG.EC0.XI71)
                Release (\_SB.MUEX)
            }

            Return (PAK0)
        }
    }
}
