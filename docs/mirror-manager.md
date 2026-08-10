# Mirror Manager

Mirror Manager is a local operator interface for the existing mirror-management scripts. It does not introduce a second provider implementation, registry or credential store.

## Start and stop

Run from the infrastructure repository with PowerShell 7:

```powershell
./tools/Start-MirrorManager.ps1
```

The host opens `http://127.0.0.1:53681` in the default browser when no existing Manager tab reconnects during startup. A live tab automatically reconnects after a host restart, so repeated starts do not keep opening new active sessions. Use `-NoBrowser` to start without opening a window or `-Port` to select another loopback port.

Stop the host with `Ctrl+C`. The listener uses an interruptible wait, stops an active operation and clears its process-scoped session credentials before exiting. The UI detects that shutdown, closes its provider popup and shows the stopped state. Restarting the host reloads the existing tab against the new process. A browser-owned main tab cannot be closed programmatically; close that tab manually when the Manager is no longer needed.

## Operator workflow

1. Connect GitHub, Cloudflare and Bitbucket under **Provider access**.
2. Select a configured mirror or create a provisioning plan.
3. Use **Refresh status** to collect the current provider state for every configured mirror.
4. Inspect operation output under **Activity**.
5. For plan/apply operations, use **Apply reviewed plan** only after the planning pass succeeds.
6. Validate the affected mirror and review any `config/mirrors.json` diff.
7. Stop or explicitly disconnect the management session when finished.

An active operation can be cancelled with **Stop operation**. Cancellation stops the operation runspace and clears transient authorization state without discarding provider sessions that were already established.

GitHub uses Device Flow. Mirror Manager opens the authorization page in a compact popup and shows the device code with a copy action in the main interface. Cloudflare and Bitbucket use fixed loopback callbacks on ports `53682` and `53683`. Because every provider window is opened by the interface, it closes automatically after successful authentication. When the browser blocks the initial popup, use **Open authorization** in the visible authorization panel.

## Available operations

- provider connection and complete session disconnect;
- asynchronous live-status refresh for all configured mirrors;
- mirror resource validation and workflow dispatch;
- complete webhook-driven branch/tag synchronization and pruning validation;
- new-target provisioning and explicit existing-target adoption;
- `enabled` and `scheduled_recovery` configuration planning and application;
- credential repair with optional webhook replacement;
- two-phase deploy-key rotation;
- managed resource removal with optional disposable target deletion;
- Worker deployment planning and application.

## Per-mirror live status

**Refresh status** collects one process-local snapshot through the active provider sessions. Each monitored resource is reported as `healthy`, `unhealthy` or `unknown`, with `checked_at` and a short reason. `unknown` means the resource could not be evaluated, for example because a provider is not connected; it is not silently treated as healthy. Any known unhealthy resource makes the mirror unhealthy, otherwise an unknown dependency makes the overall mirror state unknown.

Each mirror card shows:

- Bitbucket source accessibility and the latest default-branch commit time;
- presence of the active managed `repo:push` webhook at the derived Worker route;
- Worker deployment plus the global GitHub App secret and derived per-mirror webhook secret binding;
- GitHub target accessibility, privacy and latest push time;
- the latest mirror workflow status, conclusion and link;
- the latest successful mirror workflow completion time.

The workflow `run-name` includes the authoritative `mirror_id`, so Actions runs can be associated with a mirror without inferring from repository names or logs. Runs created before this convention cannot be attributed and remain `unknown`; dispatching that mirror once creates the first identifiable run.

The snapshot is held only in the local host process. Provider or infrastructure mutations mark it stale; refresh it again after authentication, dispatch, repair, provisioning or deployment. Status collection reuses the same webhook and Worker-readiness rules as resource validation and does not create a second configuration registry.

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
