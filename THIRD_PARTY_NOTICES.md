# Third-party notices

## libarchive public headers

`Sources/CArchive/archive.h` and `archive_entry.h` are copied without modification from [libarchive v3.7.7](https://github.com/libarchive/libarchive/tree/v3.7.7/libarchive). They retain their original BSD copyright and license notices. `Sources/CArchive/LICENSE` contains the upstream COPYING file.

These headers declare stable APIs used by LoadSide. The application links the libarchive library supplied by macOS; it does not embed an upstream libarchive binary. Keep calls within the subset present on macOS 14+. When updating headers, verify both minimum macOS support and the archive tests.

The original header notices and COPYING file are bundled in packaged builds.

## Optional Cloudflare HTTPS helper

Choosing Automatic HTTPS downloads the official [cloudflared 2026.10.0 macOS release](https://github.com/cloudflare/cloudflared/releases/tag/2026.10.0) from Cloudflare’s GitHub release assets. No cloudflared binary or source is bundled in LoadSide. The archive and extracted executable hashes for ARM64 and x86_64 are pinned in `CloudflaredInstaller.swift`; the helper is verified again before reuse.

cloudflared is licensed under [Apache License 2.0](https://github.com/cloudflare/cloudflared/blob/2026.10.0/LICENSE). Its upstream [source and dependency notices](https://github.com/cloudflare/cloudflared/tree/2026.10.0) remain available from Cloudflare. The managed helper uses the [Cloudflare Quick Tunnel service](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/), which forwards the explicitly shared library through Cloudflare’s network.

LoadSide’s independent tunnel integration follows the approach documented by [SignTools](https://github.com/SignTools/SignTools/blob/243154c0de9e8036bcd667c3264dafac3d8b0b42/INSTALL.md#4b-tunnel-provider). No SignTools or SignTools-CI source is incorporated.
