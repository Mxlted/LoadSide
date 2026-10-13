# Getting started

[Install or build LoadSide](INSTALLATION.md) first. LoadSide signs already-decrypted apps; it does not decrypt App Store downloads or create Apple signing credentials.

## Sign and export

1. Add the source `.ipa` in **Workspace** and select **Sign & export**. LoadSide inspects the app and lists its extensions.
2. Select a saved signing profile, or import the `.p12` and `.mobileprovision` files. Enter the P12 password; empty passwords are supported. Save the combination for reuse from **Signing Profiles**. Remembering the password is optional and uses macOS Keychain. Saved files load without a password prompt; the remembered password is requested when you start signing.
3. Review the signing plan. The default **Keep original** policy keeps the original bundle identifier in app metadata. When it differs from the profile, LoadSide uses one unambiguous exact profile identity in the signature and shows both IDs with a compatibility warning. **Automatic** can change the metadata ID to match the profile. An explicit override takes precedence and must match a supplied profile.
4. Review extension signing. **Reuse main profile (experimental)** is selected by default; **Require matching profiles** disables that fallback. The two checkboxes are mutually exclusive and always retain one selection. Matching extension profiles always take priority. You may also explicitly remove extensions and their features. **Strict** omits and logs unauthorized known Apple-approval entitlements and rejects other unsupported capabilities. Choose **Compatible** to allow other capability removals too.
5. Optionally add `.deb`, `.dylib`, or `.framework` inputs, choose a new export location, and sign. Review diagnostics if validation fails, correct the indicated input and retry.
6. Reveal the verified IPA in Finder or open **Local Library**, which receives a private copy automatically. Activity retains result metadata and diagnostics locally; it never saves passwords or private key material.

## Inject without signing files

Choose **Inject only**, add an IPA and one or more compatible injections, then **Inject & Export**. No P12, password, or provisioning profile is required. LoadSide validates the app and packages, injects supported payloads, removes stale signatures and embedded profiles, and exports an explicitly unsigned IPA. The original archives remain unchanged. The output must be signed before ordinary iOS installation and is not added to the signed-app library. Signature-only entitlements are removed with the old signatures; they cannot be recovered from the resulting unsigned app.

```sh
dist/loadside inject --ipa /path/App.ipa --inject /path/Tweak.deb --output /path/App-injected-unsigned.ipa
```

## Understand the signing policies

A certificate can sign different apps, but its provisioning profile still limits signing identities, entitlements and devices. Main-profile selection recognizes profiles for the app's actual nested bundles; ambiguous main profiles still require a clear selection. Automatic selection and explicit overrides require an authorized metadata bundle ID.

**Keep original compatibility** separates app metadata from the identity authorized for signing. For example, an app may retain `com.example.original` while its signed `application-identifier` uses the profile's prefix and `com.example.signing`. This is an independently implemented version of the supplied-profile approach in [SignTools](https://github.com/SignTools/SignTools) and its [SignTools-CI builder](https://github.com/SignTools/SignTools-CI/blob/8790863e64148768be9e8320c361411580d52554/sign.py#L948-L977). The app does not rewrite a mismatched wildcard into an invented identity. It shows and records a main-app mismatch; installation and app-service behavior remain unverified.

**Experimental extension compatibility**, enabled by default, also retains distinct child extension bundle IDs while signing unmatched extensions with the main profile's exact `application-identifier`. The selected main profile may differ from the preserved main bundle ID; an eligible extension must still be a child of that main bundle ID. Matching profiles always take priority; nested apps cannot use this fallback. Main or extension identity reuse can share keychain identity and break file importing, app groups or other features. Certificate, profile validity, platform, distribution and entitlement checks remain active. Signature verification does not establish device installation or working extensions. **Compatible entitlements** is a separate opt-in and never selected automatically.

## After export

Open **Activity** to inspect diagnostics or reveal output. To retry, return to **Workspace**, correct the input, and export to a new path. [Local Library sharing](SHARING.md) offers downloads and eligible OTA links. A locally verified signature does not establish installation or runtime compatibility on a device. See [compatibility](COMPATIBILITY.md) for the full limits.
