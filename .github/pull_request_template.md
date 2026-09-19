## What changed

Describe the diagnostic or documentation change.

## Why

Explain the failure mode, hardware, runtime, or transport this addresses.

## Privacy impact

List any new files, fields, identifiers, or process data collected. Explain why
the data is necessary and how it is excluded or redacted when sensitive.

## Validation

- [ ] Windows PowerShell 5.1 parser validation passes
- [ ] `tests/Validate-Collector.ps1` passes
- [ ] Documentation matches the changed output
- [ ] No secrets or personal identifiers are included
- [ ] Behaviour changes were checked with a short Windows capture when practical
