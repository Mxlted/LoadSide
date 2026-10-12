# Third-party notices

## libarchive public headers

`Sources/CArchive/archive.h` and `archive_entry.h` are copied without modification from [libarchive v3.7.7](https://github.com/libarchive/libarchive/tree/v3.7.7/libarchive). They retain their original BSD copyright and license notices. `Sources/CArchive/LICENSE` contains the upstream COPYING file.

These headers declare stable APIs used by LoadSide. The application links the libarchive library supplied by macOS; it does not embed an upstream libarchive binary. Keep calls within the subset present on macOS 14+. When updating headers, verify both minimum macOS support and the archive tests.

The original header notices and COPYING file are bundled in packaged builds.
