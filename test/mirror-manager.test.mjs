import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const managerModule = await readFile(new URL('../tools/Modules/Mirror.Manager.psm1', import.meta.url), 'utf8');
const setMirror = await readFile(new URL('../tools/Set-Mirror.ps1', import.meta.url), 'utf8');
const server = await readFile(new URL('../tools/Start-MirrorManager.ps1', import.meta.url), 'utf8');
const session = await readFile(new URL('../tools/Modules/Mirror.Session.psm1', import.meta.url), 'utf8');

test('manager exposes every existing management action through an allowlist', () => {
  for (const action of [
    'validate', 'dispatch', 'validate-sync', 'new-mirror', 'remove-mirror',
    'repair-mirror', 'rotate-keys', 'deploy-worker', 'set-mirror',
  ]) {
    assert.match(managerModule, new RegExp(`'${action}'\\s*=`));
  }
  assert.match(managerModule, /Unsupported Mirror Manager action/);
  assert.match(managerModule, /Unsupported argument\(s\)/);
});

test('local host enforces the loopback, origin, token, and operation boundaries', () => {
  assert.match(server, /http:\/\/127\.0\.0\.1:\$Port/);
  assert.match(server, /X-Mirror-Manager-Token/);
  assert.match(server, /The request origin is not the active Mirror Manager/);
  assert.match(server, /Another Mirror Manager operation is already running/);
  assert.match(server, /Content-Security-Policy/);
});

test('loopback OAuth completion attempts to close its browser window', () => {
  assert.match(session, /window\.close\(\)/);
  assert.match(session, /\[AllowNull\(\)\]\[string\]\$ClientSecret/);
});

test('configuration mutations preserve plan/apply behavior', () => {
  assert.match(setMirror, /SupportsShouldProcess/);
  assert.match(setMirror, /\[switch\]\$Apply/);
  assert.match(setMirror, /Planning only/);
  assert.match(setMirror, /Assert-MirrorConfiguration/);
});
