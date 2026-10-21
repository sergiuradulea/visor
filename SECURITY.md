# Security

## Reporting a vulnerability

Please open a [private security advisory](../../security/advisories/new) instead of a public issue. Include the macOS version, the steps to reproduce and what an attacker gains. You'll get an answer within a week.

## Threat model

Visor runs as you, unsandboxed, and may hold **Accessibility** and **Downloads folder** permissions. The main risk is that something abuses those permissions or reads what Visor stores.

| Area | What Visor does | Why it's acceptable / mitigations |
|---|---|---|
| **Accessibility** (event tap) | Listens for `NX_SYSDEFINED` events only: volume, mute and brightness keys. | It never receives `keyDown` events, so it cannot log typing. Unhandled keys pass through to macOS unchanged. |
| **Permission inheritance** | macOS lets child processes inherit the parent's privacy permissions, and Visor launches its bundled helper. | Install to `/Applications` (admin-owned) rather than running from a user-writable build folder, so other processes can't swap the helper. Don't run builds from untrusted forks. |
| **`com.apple.` helper bundle ID** | `VisorMedia` uses `com.apple.controlcenter.VisorMedia` so MediaRemote answers it. | It's local-only and signed with your own key; it grants no Apple entitlements. Some endpoint-security tools may flag it, and you can verify the source yourself. |
| **Clipboard history at rest** | The last 40 clips (≤10 images) are stored as plain JSON in `~/Library/Application Support/Visor/`. | Concealed/transient items (password managers) are skipped. The file is excluded from Time Machine. It's readable by other processes running as you, like any app data. Use **Clear history** after copying something sensitive. |
| **Notes / tray list** | Stored in the app's preferences plist. | Tray entries are paths only; files are never copied. |
| **Screenshot auto-add** | Spotlight's `kMDItemIsScreenCapture` tag, which any app can set. | Only files directly inside the configured screenshot folder are accepted. |
| **Download auto-add** | `NSProgress` publications for files in `~/Downloads`. | Only adds a reference to a file that already exists in Downloads. Nothing is opened or sent without a click. |
| **Private APIs** | MediaRemote, DisplayServices and SkyLight, resolved with `dlsym`. | Missing symbols are handled: the feature turns off rather than crashing. |
| **Network** | None. | No sockets, no update checks, no telemetry. |
| **Process execution** | Launches only its own bundled helper, with fixed arguments and no shell. | Commands are numeric and no input is interpolated. |

## Not in scope

- Attacks that already require code execution as your user with the same permissions. They can read your clipboard directly.
- Breakage caused by macOS changing private APIs.
