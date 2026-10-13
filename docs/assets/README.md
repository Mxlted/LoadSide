# Application screenshots

These are genuine window captures of the packaged LoadSide app on macOS, captured on 2026-10-13 at 1508 × 984 pixels in dark appearance. They show empty signing and injection workspaces, without synthetic exports or user signing material. The images are the original JPEG bytes returned by the native capture tool, about 280 KiB combined; no compositing or UI reconstruction was applied.

Capture source: local packaged UI at commit `0f3de55` (RC.2 development state). RC.3 changes credential state and engine/release safeguards without changing these views. No device-installation or signing-success claim is implied by these screenshots.

To refresh, build and launch the actual app in an isolated temporary home (`CFFIXED_USER_HOME` passed to the bundled executable, not a global setting), confirm that its stores are empty, then capture just its window. Close other LoadSide instances first so the capture tool selects the isolated process. Check the visible UI and accessibility text for paths, account/profile names, credentials, and session links before saving. Never start library sharing for a screenshot. Preserve truthful state; do not edit text or fabricate progress. Update descriptive alt text and this provenance when replacing assets.
