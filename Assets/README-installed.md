# LoadSide

Sign decrypted iOS apps locally on your Apple Silicon Mac using your own certificate and provisioning profiles.

Open LoadSide, choose an already decrypted IPA, import your PKCS#12 identity and provisioning profiles, review the signing options, and export to a new filename. LoadSide does not decrypt applications. A valid local signature does not guarantee installation or runtime behavior on an iOS device.

- [Getting started](https://github.com/Mxlted/LoadSide/blob/main/docs/GETTING_STARTED.md)
- [Local Library and sharing](https://github.com/Mxlted/LoadSide/blob/main/docs/SHARING.md)
- [Command-line guide](https://github.com/Mxlted/LoadSide/blob/main/docs/CLI.md)
- [Troubleshooting](https://github.com/Mxlted/LoadSide/blob/main/docs/TROUBLESHOOTING.md)
- [Compatibility and limitations](https://github.com/Mxlted/LoadSide/blob/main/docs/COMPATIBILITY.md)
- [Report a bug](https://github.com/Mxlted/LoadSide/issues)

The bundled command-line tool is at `LoadSide.app/Contents/Helpers/loadside`. Run it with `--help` for usage. Passwords are supplied through standard input or a protected file, never as a command-line value.

`BuildInfo.txt` in this directory records the version, source provenance, build type, and toolchain. If packaging skipped compilation, binary source and original compiler are explicitly unverified. A **local** build is ad-hoc signed and is not notarized or approved for public release. See the included `LICENSE` and `ThirdParty/` notices for licensing.

Review diagnostics before sharing them. Do not attach certificates, private keys, passwords, provisioning profiles, or proprietary archives to public issues.
