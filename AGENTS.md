# Agent instructions

This repository contains a read-only Windows diagnostic collector for VRChat,
Meta Quest Link, SteamVR, OpenXR, and related PC hardware.

## Required invariants

- Keep collection read-only. Do not change drivers, services, power plans,
  registry values, VR settings, game files, or installed applications.
- Do not download or install dependencies during collection.
- Do not upload collected data anywhere.
- Crash dumps must remain opt-in because they can contain private memory.
- Preserve best-effort redaction and extend it when collecting a new identifier.
- Never log passwords, authentication cookies, bearer tokens, browser profiles,
  saved credentials, or unrelated personal documents.
- Keep Windows PowerShell 5.1 compatibility.
- A failed collection step must be recorded and must not abort unrelated steps.
- NVIDIA, AMD, and Intel systems must retain a useful vendor-neutral collection
  path. Vendor tools are optional enhancements, never requirements.
- Treat the PC's LAN uplink and the headset's transport as separate facts. A PC
  on Ethernet may stream to a headset over Wi-Fi through the local router.
- Output must remain a timestamped folder and ZIP with a readable summary,
  privacy report, collection-error log, and file manifest.

## Hardware support

Use Windows CIM, performance counters, DirectX diagnostics, PnP inventory,
event logs, and WER metadata as the baseline.

- NVIDIA: use `nvidia-smi` only when already installed.
- AMD: use `amd-smi` only when already installed.
- Intel graphics: rely on Windows GPU-engine counters and driver diagnostics
  unless a supported local telemetry tool is already present.
- Intel and AMD CPUs use the same topology, load, power-policy, WHEA, and
  best-effort ACPI thermal collection.

Do not infer a temperature, clock, power, or health value that the system did
not expose.

Network collection should remain passive. Record local adapter counters, active
routes, gateway latency, driver events, and application-reported transport
metrics. Steam Link collection should preserve bad-link, delivery-delay,
bitrate/adaptive, timeout, reset, disconnect, and compositor-watchdog evidence.
Do not scan the LAN or probe public hosts. A user-supplied or log-derived private
headset address may be pinged during an active diagnostic run.

## Privacy review

Before adding a file source, decide whether it can contain:

- account or player identifiers
- headset, motherboard, disk, or device serials
- public IP or IPv6 addresses
- Wi-Fi SSIDs or BSSIDs
- email addresses
- URLs containing tokens, signatures, keys, codes, or IP parameters
- chat, voice, or private message content
- process arguments unrelated to VR diagnosis

Exclude the source or add a targeted redaction rule. Retain private LAN
addresses only when they are useful for diagnosing local streaming routes.

## Validation

Run:

```powershell
powershell.exe -NoProfile -File ".\tests\Validate-Collector.ps1"
```

Documentation-only changes do not require a collector run. For behavioural
changes, also run a short local capture when safe and inspect the resulting ZIP.

Update `README.md` and `ANALYZE-DIAGNOSTICS.md` whenever collection behaviour,
privacy handling, output layout, or analysis expectations change.
