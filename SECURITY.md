# Security policy

Magnife opens two ports on your Mac and parses whatever is sent to them, so security reports are very welcome.

## Supported versions

Only the [latest release](https://github.com/NsRF/Magnife/releases/latest) and `main` get security fixes.

## Reporting a vulnerability

Please report it privately. Do not open a public issue.

1. Go to the [Security tab](https://github.com/NsRF/Magnife/security) and choose **Report a vulnerability**.
2. Describe the problem, what an attacker could do with it, and how to reproduce it. A payload or a small script helps a lot.

You will get an answer within a week. Once a fix ships, the advisory credits you unless you prefer otherwise.

## What is in scope

- **The OTLP receiver** (`ingest/internal/receiver`). It binds `127.0.0.1` only, and HTTP accepts only `localhost`, loopback and `host.docker.internal` Hosts and Origins, which defends against DNS rebinding. Bodies are capped at 32 MiB with 4 decodes at once, and values nested more than 64 levels deep are refused. Anything that gets around these limits counts: reaching the receiver from another machine or a web page, crashing the helper, or making it use unbounded memory or disk.
- **File > Import Traces…** (`Receiver.ImportFile`), which parses files people share with each other. Files are capped at 64 MB and get the same nesting check.
- **The database files** in `~/Library/Application Support/Magnife/`. The files are `0600` in a `0700` folder, and the app opens them read-only.
- **The helper protocol** between the app and `magnife-ingest` (stdin and stdout, `docs/schema.sql`).
- **Updates**, when a build includes Sparkle (`MAGNIFE_SPARKLE=1`).

## Out of scope

- Telemetry your own apps choose to send. Magnife stores what it receives, so do not send secrets in span attributes.
- Builds you signed yourself, and the ad hoc signature of current releases. That one is a known limitation, described in [docs/RELEASE.md](docs/RELEASE.md).
