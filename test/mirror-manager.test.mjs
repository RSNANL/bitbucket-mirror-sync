import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const managerModule = await readFile(new URL('../tools/Modules/Mirror.Manager.psm1', import.meta.url), 'utf8');
const setMirror = await readFile(new URL('../tools/Set-Mirror.ps1', import.meta.url), 'utf8');
const server = await readFile(new URL('../tools/Start-MirrorManager.ps1', import.meta.url), 'utf8');
const session = await readFile(new URL('../tools/Modules/Mirror.Session.psm1', import.meta.url), 'utf8');
const managerHtml = await readFile(new URL('../manager/web/index.html', import.meta.url), 'utf8');
const managerApp = await readFile(new URL('../manager/web/app.js', import.meta.url), 'utf8');
const managerDocs = await readFile(new URL('../docs/mirror-manager.md', import.meta.url), 'utf8');
const statusModule = await readFile(new URL('../tools/Modules/Mirror.Status.psm1', import.meta.url), 'utf8');
const bitbucketModule = await readFile(new URL('../tools/Modules/Mirror.Bitbucket.psm1', import.meta.url), 'utf8');
const mirrorWorkflow = await readFile(new URL('../.github/workflows/mirror.yml', import.meta.url), 'utf8');

test('manager exposes every existing management action through an allowlist', () => {
  for (const action of [
    'refresh-status', 'validate', 'dispatch', 'validate-sync', 'new-mirror', 'remove-mirror',
    'repair-mirror', 'rotate-keys', 'deploy-worker', 'set-mirror',
  ]) {
    assert.match(managerModule, new RegExp(`'${action}'\\s*=`));
  }
  assert.match(managerModule, /Unsupported Mirror Manager action/);
  assert.match(managerModule, /Unsupported argument\(s\)/);
});

test('local host enforces the loopback, origin, token, and operation boundaries', () => {
  assert.match(server, /http:\/\/127\.0\.0\.1:\$Port/);
  assert.match(server, /Test-ManagerLoopbackClient -RemoteEndPoint \$request\.RemoteEndPoint/);
  assert.doesNotMatch(server, /\$request\.UserHostAddress/);
  assert.match(server, /X-Mirror-Manager-Token/);
  assert.match(server, /The request origin is not the active Mirror Manager/);
  assert.match(server, /Another Mirror Manager operation is already running/);
  assert.match(server, /GetContextAsync\(\)/);
  assert.match(server, /\/api\/operation\/cancel/);
  assert.match(server, /\/api\/health/);
  assert.match(server, /Content-Security-Policy/);
});

test('loopback OAuth completion attempts to close its browser window', () => {
  assert.match(session, /window\.close\(\)/);
  assert.match(session, /\[AllowNull\(\)\]\[string\]\$ClientSecret/);
  assert.match(session, /CurrentDomain\.GetData\(\$AuthorizationEventKey\)/);
  assert.match(session, /\$authorizationEvents\.Enqueue/);
  assert.doesNotMatch(session, /MIRROR_MANAGER_AUTHORIZATION:/);
  assert.match(server, /authorization = \$operation\.Authorization/);
  assert.match(server, /AddParameter\('NoBrowser', \$true\)/);
  assert.match(server, /AddParameter\('AuthorizationEventKey', \$authorizationEventKey\)/);
  assert.match(server, /AuthorizationEvents\.TryDequeue/);
  assert.match(server, /Provider authorization did not become ready within 30 seconds/);
});

test('configuration mutations preserve plan/apply behavior', () => {
  assert.match(setMirror, /SupportsShouldProcess/);
  assert.match(setMirror, /\[switch\]\$Apply/);
  assert.match(setMirror, /Planning only/);
  assert.match(setMirror, /Assert-MirrorConfiguration/);
});

test('web app exposes provider, mirror, operation, and activity surfaces', () => {
  for (const id of ['providers', 'mirror-list', 'refresh-status', 'status-checked', 'activity', 'action-dialog']) {
    assert.match(managerHtml, new RegExp(`id="${id}"`));
  }
  for (const action of ['validate-sync', 'new-mirror', 'remove-mirror', 'repair-mirror', 'rotate-keys', 'deploy-worker', 'set-mirror']) {
    assert.match(managerApp, new RegExp(`['"]${action}['"]`));
  }
  assert.doesNotMatch(managerApp, /localStorage|sessionStorage|document\.cookie/);
  assert.match(managerHtml, /Apply reviewed plan/);
  assert.match(managerHtml, /id="authorization-code"/);
  assert.match(managerApp, /window\.open\('', 'mirror-manager-provider-authorization', 'popup=yes/);
  assert.match(managerApp, /navigator\.clipboard\.writeText\(code\)/);
  assert.match(managerApp, /state\.authPopup\.location\.replace\(uri\)/);
  assert.match(managerApp, /closeAuthenticationPopup\(\)/);
  assert.match(managerApp, /navigator\.locks\?\.request/);
  assert.match(managerApp, /setInterval\(checkHost, 1000\)/);
  assert.match(managerApp, /\/api\/operation\/cancel/);
  assert.match(managerHtml, /id="cancel-operation"/);
  assert.match(managerDocs, /only authoritative non-secret registry/);
  assert.doesNotMatch(managerHtml, /class="sidebar"|class="nav-link"/);
  assert.doesNotMatch(managerApp, /querySelectorAll\('\.nav-link'\)/);
});

test('provider sessions reconnect independently and GitHub device flow is code-first', () => {
  assert.match(managerModule, /authenticated = \$hasToken -and -not \$isExpired/);
  assert.match(managerModule, /expired = \$hasToken -and \$isExpired/);
  assert.match(managerApp, /provider\.expired\s*\? 'Session expired'/);
  assert.match(managerApp, /provider\.authenticated \? 'Connected' : provider\.expired \? 'Reconnect' : 'Connect'/);
  assert.match(managerApp, /if \(provider !== 'github'\) state\.authPopup = openAuthenticationPopup\(\);/);
  assert.match(managerApp, /operation\.authorization && operation\.authorization\.provider !== 'github'/);
  assert.match(managerApp, /!\['refresh-status', 'connect-provider'\]\.includes\(action\)/);
  assert.match(managerApp, /Copy this code, then open GitHub authorization when you are ready/);
  assert.match(managerDocs, /re-authenticate that provider without disconnecting the other active provider sessions/);
});

test('per-mirror live status has a normalized contract and deterministic workflow identity', () => {
  assert.match(statusModule, /ValidateSet\('healthy', 'unhealthy', 'unknown'\)/);
  assert.match(statusModule, /function Resolve-MirrorOverallStatus/);
  for (const property of [
    'bitbucket_repository', 'bitbucket_webhook', 'cloudflare_worker',
    'github_repository', 'github_actions', 'last_successful_sync',
  ]) {
    assert.match(statusModule, new RegExp(`${property}\\s*=`));
  }
  assert.match(mirrorWorkflow, /run-name:\s*Mirror \$\{\{ inputs\.mirror_id \}\}/);
  assert.match(managerApp, /runOperation\('refresh-status'\)/);
  assert.match(managerApp, /dataset\.statusKind/);
  assert.match(managerHtml, /data-status-kind="github_actions"/);
  assert.match(managerDocs, /healthy`, `unhealthy` or `unknown`/);
  assert.match(statusModule, /function Merge-MirrorSyncValidationEvidence/);
  assert.match(statusModule, /evidence = 'full_sync_validation'/);
  assert.match(bitbucketModule, /commits\/\$\{encodedRevision\}\?pagelen=1/);
});

test('dialogs can be dismissed without satisfying required fields', () => {
  assert.equal((managerHtml.match(/data-dialog-dismiss[^>]*type="button"/g) || []).length, 2);
  assert.doesNotMatch(managerHtml, /value="cancel"[^>]*type="submit"/);
  assert.match(managerApp, /querySelectorAll\('\[data-dialog-dismiss\]'\)/);
  assert.match(managerApp, /addEventListener\('cancel'/);
  assert.match(managerApp, /event\.target !== elements\.dialog/);
  assert.match(managerApp, /function closeDialog\(\)/);
});
