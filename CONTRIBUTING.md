# Contributing

Contributions are welcome when they improve diagnostic accuracy, hardware
coverage, privacy, or reliability without changing the read-only nature of the
collector.

## Before opening an issue

Search existing issues first. For a bug, include:

- Windows version
- CPU and GPU models
- headset model
- wired or wireless transport
- VR runtime and version
- exact collector command
- the visible error and when it occurred

Do not attach an unreviewed diagnostic ZIP to a public issue. Logs can contain
account identifiers, local paths, device serials, network addresses, and other
private information. Quote only the smallest redacted excerpt needed to show the
problem.

## Making changes

Keep the collector compatible with Windows PowerShell 5.1 and preserve these
requirements:

- read-only collection
- no downloaded or installed dependencies
- graceful failure of individual collection steps
- vendor-neutral CPU and GPU coverage
- optional vendor-specific telemetry
- best-effort privacy redaction
- opt-in crash dumps
- timestamped ZIP output with summary, error log, privacy report, and manifest

Create a branch, make focused changes, and update the documentation when output
or behaviour changes.

Run the validator:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\tests\Validate-Collector.ps1"
```

For behaviour changes, also run a short capture on a Windows test machine:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Collect-VRChat-Quest-Diagnostics.ps1" -SampleSeconds 30
```

Inspect the resulting ZIP before submitting the pull request. Confirm that the
new data is useful, collection errors are understandable, and no new personal
identifiers were introduced.

## Pull requests

Describe:

- the problem being solved
- the evidence or platform that motivated the change
- any new files or identifiers collected
- privacy implications
- validation performed

Avoid unrelated formatting or refactoring in the same pull request.
