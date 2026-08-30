# Security policy

## Supported versions

There is no stable release yet. Security fixes are developed against the
current main line. Older snapshots are not promised security support.

## Reporting a vulnerability

If the repository host offers private vulnerability reporting, use that
channel. Otherwise, open an issue containing only non-sensitive impact and
contact details, and ask the maintainers for a private channel before sharing
reproduction inputs, exploit details, credentials, or private data.

Include, when safe:

- the exact commit and Cangjie SDK version;
- affected API and TOML mode;
- expected and observed behavior;
- whether the issue is a crash, resource exhaustion, data corruption, unsafe
  output, or diagnostic bypass;
- the smallest non-sensitive reproduction.

Do not publish a working exploit before a fix and coordinated disclosure are
available.

## Security boundaries

The parser and schema validator enforce configurable input, nesting, token,
node, diagnostic, visit, and reference-depth limits. Applications processing
untrusted data should choose limits appropriate to their environment instead
of relying only on defaults.

The library does not perform file or network resolution for schema references.
Only named local references are accepted. It also does not use `stdx`
DataModel, runtime field reflection, or a global codec registry.

These controls reduce risk; they are not a security certification. Hosted CI,
fuzzing duration, platform matrices, and stable-SDK release qualification must
be evaluated for each release candidate.
