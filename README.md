# VRChat Quest Diagnostics

A read-only Windows PowerShell collector for diagnosing VRChat problems involving
Meta Quest Link, SteamVR, OpenXR, USB transport, graphics drivers, and general
system stability.

The script creates a timestamped ZIP on the current user's Desktop. Upload that
ZIP together with [`ANALYZE-DIAGNOSTICS.md`](ANALYZE-DIAGNOSTICS.md) to an AI
assistant or provide it to a technically experienced person.

## What it collects

The collector records:

- Windows, BIOS, motherboard, CPU, memory, storage, power, and driver details
- WHEA hardware errors, application hangs, display faults, USB events, and
  Windows Error Reporting metadata
- Meta Quest Link services, devices, configuration, and recent logs
- Steam, SteamVR, OpenVR, and VRChat configuration and recent logs
- Live CPU, memory, disk, network, GPU-engine, and relevant process telemetry
- NVIDIA telemetry through `nvidia-smi` when available
- AMD telemetry through `amd-smi` when available
- DirectX, display, OpenXR, and installed VR software information

Windows-native collection remains available when no vendor utility is
installed. Intel and AMD CPUs follow the same diagnostic path. NVIDIA, AMD, and
Intel graphics adapters are identified automatically.

The script does not install software, change drivers, edit application settings,
or run stress tests.

## Run it

Download `Collect-VRChat-Quest-Diagnostics.ps1` into Downloads. Open Meta Quest
Link, SteamVR, VRChat, or whichever combination reproduces the problem, then run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "$HOME\Downloads\Collect-VRChat-Quest-Diagnostics.ps1" -Days 14 -SampleSeconds 2700
```

The script requests Administrator access. Once live capture starts, reproduce
the fault. Press **Enter** after the problem occurs to stop early and build the
ZIP. Do not use `Ctrl+C`, because that skips final log collection.

For a quick five-minute capture:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "$HOME\Downloads\Collect-VRChat-Quest-Diagnostics.ps1" -SampleSeconds 300
```

## Privacy

The archive can contain local paths, device information, application logs,
network configuration, account identifiers, and diagnostic messages. The
collector applies best-effort redaction to copied text, including Windows
usernames, computer names, email addresses, public IP addresses, Wi-Fi names,
Steam IDs, VRChat IDs, Meta machine IDs, MAC addresses, and headset serials.

Redaction cannot guarantee that every application-specific identifier is
removed. Review the ZIP before publishing it or sending it to someone you do not
trust.

Application crash dumps are excluded by default because they may contain
fragments of private memory. Include them only when necessary:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "$HOME\Downloads\Collect-VRChat-Quest-Diagnostics.ps1" -IncludeCrashDumps
```

## GPU support

All systems receive vendor-neutral Windows GPU-engine telemetry, display-driver
inventory, DirectX diagnostics, and graphics event collection.

If present, the collector also uses:

- `nvidia-smi` for NVIDIA temperature, power, clocks, utilization, VRAM, PCIe,
  and performance-state information
- `amd-smi` for AMD static information and live metrics in JSON format

Neither utility is downloaded or installed by the script.

## Analysing the ZIP

Upload the ZIP and [`ANALYZE-DIAGNOSTICS.md`](ANALYZE-DIAGNOSTICS.md) together.
Add a short description of what happened, how the headset was connected, and
roughly when the fault occurred.

An effective analysis should compare:

- the live telemetry timeline
- Meta USB and streaming-session transitions
- SteamVR compositor and server behaviour
- VRChat's output log
- Windows events and reliability history
- current errors versus stale or repeatedly submitted WER reports

## Limitations

- The collector covers the Windows PC side. It does not retrieve Android logs
  from the Quest headset.
- CPU temperatures are available only when exposed through ACPI or another
  installed monitoring provider.
- Vendor utilities differ by driver and hardware generation, so unsupported
  fields may be absent.
- Logs buffered by a running application may not be fully flushed until that
  application closes.

## Validation

The script targets Windows PowerShell 5.1. Validate its syntax with:

```powershell
powershell.exe -NoProfile -File ".\tests\Validate-Collector.ps1"
```
