# Security

## Reporting a vulnerability

Please open a [private security advisory](../../security/advisories/new) instead of a public issue. Include the macOS version, the steps to reproduce and what an attacker gains. You'll get an answer within a week.

## Threat model

Visor runs as you, unsandboxed, and may hold **Accessibility** and **Downloads folder** permissions. The main risk is that something abuses those permissions or reads what Visor stores.

| Area | What Visor does | Why it's acceptable / mitigations |
|---|---|---|
| **Accessibility** (event tap) | Listens for `NX_SYSDEFINED` events only: volume, mute and brightness keys. | It never receives `keyDown` events, so it cannot log typing. Unhandled keys pass through to macOS unchanged. The tap runs on its own thread and is removed within a second if Accessibility is revoked, so it can't stall system input. |
| **Permission inheritance** | macOS lets child processes inherit the parent's privacy permissions, and Visor launches its bundled helper. | Install to `/Applications` (admin-owned) rather than running from a user-writable build folder, so other processes can't swap the helper. Don't run builds from untrusted forks. |
| **`com.apple.` helper bundle ID** | `VisorMedia` uses `com.apple.controlcenter.VisorMedia` so MediaRemote answers it. | It's local-only and signed with your own key; it grants no Apple entitlements. Some endpoint-security tools may flag it, and you can verify the source yourself. |
| **Clipboard history at rest** | The last 40 clips (≤10 images) are stored unencrypted in `~/Library/Application Support/Visor/`: text and thumbnails in `clipboard.json`, full images as `clips/<id>.png`. | Concealed/transient items (password managers) are skipped. The folder is excluded from Time Machine, and images are deleted when they drop out of the history. It's readable by other processes running as you, like any app data. Use **Clear history** after copying something sensitive. |
| **Notes / tray list** | Stored in the app's preferences plist. | Tray entries are paths only; files are never copied. |
| **Screenshot auto-add** | Spotlight's `kMDItemIsScreenCapture` tag, which any app can set. | Only files directly inside the configured screenshot folder are accepted. |
| **Download auto-add** | `NSProgress` publications for files in `~/Downloads`. | Only adds a reference to a file that already exists in Downloads. Nothing is opened or sent without a click. |
| **Private APIs** | MediaRemote, DisplayServices and SkyLight, resolved with `dlsym`. | Missing symbols are handled: the feature turns off rather than crashing. |
| **Network** | None by default. With the opt-in Claude plan limits on: one HTTPS `GET https://api.anthropic.com/api/oauth/usage` every 5 minutes, only while the Home tab is visible. | No update checks or telemetry. Ephemeral session (no cookies or cache on disk). Redirects are refused so the token can't be forwarded to another host. |
| **Claude Code login** (opt-in) | Reads the `Claude Code-credentials` keychain item to get the access token for the request above. macOS asks before allowing this. **That item also holds the access tokens of your Claude Code connectors (Slack, Notion, Figma and so on), so allowing it lets Visor read those too.** Visor uses only the `claudeAiOauth` entry and drops the rest without looking at it. When the token has expired (it lasts 8 hours), Visor runs Claude Code's own `claude auth status` so Claude Code can renew it. | Tokens stay in memory for one request only: never written, logged or shown. Visor never calls the renewal endpoint or writes to the keychain, so it can't sign you out of Claude Code. If you'd rather not grant this, leave the limits off; nothing else needs it. Off by default. |
| **Claude Code sessions** | Reads `~/.claude/sessions/*.json` (name, project folder, busy/idle) to list running agents. | Read-only. The `.key` files in that folder are never opened. |
| **Bluetooth batteries** | Runs Apple's `/usr/sbin/system_profiler SPBluetoothDataType -json` once a minute while Home is visible. | Fixed path and arguments, no shell. Only battery levels and device names are used. |
| **Process execution** | Launches only its own bundled helper, Apple's `system_profiler`, and (opt-in limits only) Claude Code's `claude auth status`, all with fixed paths and arguments and no shell. | Commands are numeric and no input is interpolated. |

## Not in scope

- Attacks that already require code execution as your user with the same permissions. They can read your clipboard directly.
- Breakage caused by macOS changing private APIs.
