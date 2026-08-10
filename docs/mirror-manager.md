# Mirror Manager

Mirror Manager is a local operator interface for the existing mirror-management scripts. It does not introduce a second provider implementation, registry or credential store.

## Start and stop

Run from the infrastructure repository with PowerShell 7:

```powershell
./tools/Start-MirrorManager.ps1
```

The host opens `http://127.0.0.1:53681` in the default browser. Use `-NoBrowser` to start without opening a window or `-Port` to select another loopback port.

Stop the host with `Ctrl+C`. The host stops an active operation and clears its process-scoped session credentials before exiting.

## Operator workflow

1. Connect GitHub, Cloudflare and Bitbucket under **Provider access**.
2. Select a configured mirror or create a provisioning plan.
3. Inspect operation output under **Activity**.
4. For plan/apply operations, use **Apply reviewed plan** only after the planning pass succeeds.
5. Validate the affected mirror and review any `config/mirrors.json` diff.
6. Stop or explicitly disconnect the management session when finished.

GitHub uses Device Flow. Mirror Manager opens the authorization page in a compact popup and shows the device code with a copy action in the main interface. Cloudflare and Bitbucket use fixed loopback callbacks on ports `53682` and `53683`. Because every provider window is opened by the interface, it closes automatically after successful authentication. When the browser blocks the initial popup, use **Open authorization** in the visible authorization panel.

## Available operations

- provider connection and complete session disconnect;
- mirror resource validation and workflow dispatch;
- complete webhook-driven branch/tag synchronization and pruning validation;
- new-target provisioning and explicit existing-target adoption;
- `enabled` and `scheduled_recovery` configuration planning and application;
- credential repair with optional webhook replacement;
- two-phase deploy-key rotation;
- managed resource removal with optional disposable target deletion;
- Worker deployment planning and application.

`config/mirrors.json` remains the only authoritative non-secret registry. The UI can update it through the same validation boundary but never commits or pushes it automatically.

## Security properties

- The listener binds only to IPv4 loopback.
- Every mutation requires the exact local origin and a random request token.
- Provider tokens exist only in the PowerShell host process.
- The browser stores no token, provider secret or application state persistently.
- The host accepts only a fixed action and parameter allowlist.
- One operation runs at a time.
- Existing script validation, confirmation and plan/apply behavior remains authoritative.

The UI is intentionally not deployable as a public or shared web service. Remote access, background service installation, persistent sessions and unattended management credentials are outside this architecture.
