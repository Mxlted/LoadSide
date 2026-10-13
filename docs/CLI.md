# Command-line use

The app and CLI use the same engine, validation, signing policies, and diagnostic codes. The packaged CLI is `dist/loadside`; substitute that for `swift run loadside` below to use the packaged build. Run `dist/loadside --help` for the authoritative options.

```sh
swift run loadside doctor
swift run loadside profile /path/App.mobileprovision
swift run loadside sign \
  --ipa /path/App.ipa \
  --p12 /path/Identity.p12 \
  --profile /path/App.mobileprovision \
  --profile /path/Extension.mobileprovision \
  --inject /path/CompatibleTweak.deb \
  --output /path/App-signed.ipa
```

The CLI prompts for the password without echoing it. For automation, use `--password-stdin` or `--password-file` with a regular UTF-8 file readable only by its owner (at most 16 KiB). Password files cannot be symbolic links or named pipes; use stdin for streamed input. Never put passwords in command-line arguments. `--json` writes the result to stdout and progress JSONL to stderr. Ctrl-C cancels and cleans up. Run `loadside --help` for all options.

The CLI also defaults to preserving the original bundle identifier and experimental main-profile reuse for extensions. Use `--bundle-id-policy automatic` to allow profile-based identifier changes, or `--require-matching-extension-profiles` to disable experimental reuse. `--reuse-main-profile-for-extensions` remains available for explicit scripts; it cannot be combined with `--require-matching-extension-profiles` or `--remove-extensions`.

## Inject without signing

```sh
dist/loadside inject --ipa /path/App.ipa --inject /path/Tweak.deb --output /path/App-injected-unsigned.ipa
```

This strips stale signatures and profiles and produces an unsigned archive. Signing credential options are rejected in this mode. See [getting started](GETTING_STARTED.md#inject-without-signing-files) for entitlement limitations.

Use a new output filename for every export. Failures and cancellation clean staged work without publishing a partial final IPA. Original inputs remain unchanged. See [compatibility](COMPATIBILITY.md) and [troubleshooting](TROUBLESHOOTING.md) before automating a new app/profile combination.
