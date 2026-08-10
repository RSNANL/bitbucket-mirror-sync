const state = {
  token: null,
  snapshot: null,
  operation: null,
  poller: null,
  dialogAction: null,
  pendingPlan: null,
  authPopup: null,
  authorization: null,
  heartbeat: null,
  runtimeId: null,
  hostOnline: true,
};

const elements = {
  providers: document.querySelector('#providers'),
  mirrorList: document.querySelector('#mirror-list'),
  mirrorCount: document.querySelector('#mirror-count'),
  statusChecked: document.querySelector('#status-checked'),
  refreshStatus: document.querySelector('#refresh-status'),
  providerTemplate: document.querySelector('#provider-template'),
  mirrorTemplate: document.querySelector('#mirror-template'),
  operationState: document.querySelector('#operation-state'),
  operationName: document.querySelector('#operation-name'),
  operationLog: document.querySelector('#operation-log'),
  notice: document.querySelector('#notice'),
  cancelOperation: document.querySelector('#cancel-operation'),
  applyPlan: document.querySelector('#apply-plan'),
  dialog: document.querySelector('#action-dialog'),
  form: document.querySelector('#action-form'),
  dialogEyebrow: document.querySelector('#dialog-eyebrow'),
  dialogTitle: document.querySelector('#dialog-title'),
  dialogFields: document.querySelector('#dialog-fields'),
  dialogNote: document.querySelector('#dialog-note'),
  dialogSubmit: document.querySelector('#dialog-submit'),
  authorization: document.querySelector('#authorization'),
  authorizationTitle: document.querySelector('#authorization-title'),
  authorizationMessage: document.querySelector('#authorization-message'),
  authorizationCodeWrap: document.querySelector('#authorization-code-wrap'),
  authorizationCode: document.querySelector('#authorization-code'),
  copyAuthorizationCode: document.querySelector('#copy-authorization-code'),
  openAuthorization: document.querySelector('#open-authorization'),
};

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: {
      ...(options.body ? { 'Content-Type': 'application/json', 'X-Mirror-Manager-Token': state.token } : {}),
      ...options.headers,
    },
  });
  const body = await response.json();
  if (!response.ok) throw new Error(body.error || `Request failed with HTTP ${response.status}.`);
  return body;
}

function showError(error) {
  elements.notice.textContent = error instanceof Error ? error.message : String(error);
  elements.notice.classList.remove('hidden');
}

function clearError() {
  elements.notice.textContent = '';
  elements.notice.classList.add('hidden');
}

function openAuthenticationPopup() {
  const popup = window.open('', 'mirror-manager-provider-authorization', 'popup=yes,width=620,height=760,resizable=yes,scrollbars=yes');
  if (!popup) return null;
  popup.document.title = 'Mirror Manager authorization';
  popup.document.body.textContent = 'Preparing provider authorization…';
  popup.focus();
  return popup;
}

function navigateAuthenticationPopup(uri) {
  if (!uri) return;
  if (!state.authPopup || state.authPopup.closed) state.authPopup = openAuthenticationPopup();
  if (!state.authPopup) return;
  state.authPopup.location.replace(uri);
  state.authPopup.focus();
}

function closeAuthenticationPopup() {
  if (state.authPopup && !state.authPopup.closed) state.authPopup.close();
  state.authPopup = null;
}

function setHostUnavailable() {
  if (!state.hostOnline) return;
  state.hostOnline = false;
  closeAuthenticationPopup();
  renderAuthorization(null);
  if (state.poller) clearInterval(state.poller);
  state.poller = null;
  elements.cancelOperation.classList.add('hidden');
  elements.applyPlan.classList.add('hidden');
  elements.operationState.className = 'operation-state failed';
  elements.operationState.textContent = 'Stopped';
  elements.operationName.textContent = 'Mirror Manager host stopped';
  elements.operationLog.textContent = 'The local host stopped and cleared its in-process management session. Restart it to continue.';
  showError('Mirror Manager is no longer running. This page will reconnect automatically after the host is restarted.');
  if (state.snapshot) {
    renderProviders();
    renderMirrors();
  }
  for (const button of document.querySelectorAll('button')) button.disabled = true;
}

function renderAuthorization(authorization) {
  state.authorization = authorization || null;
  elements.authorization.classList.toggle('hidden', !authorization);
  if (!authorization) return;

  const label = authorization.provider[0].toUpperCase() + authorization.provider.slice(1);
  elements.authorizationTitle.textContent = `Complete ${label} authentication`;
  elements.authorizationMessage.textContent = authorization.user_code
    ? 'Copy this code into GitHub. This popup closes as soon as authorization succeeds.'
    : 'Complete the provider consent flow in the popup. It closes automatically after the callback.';
  elements.authorizationCode.textContent = authorization.user_code || '';
  elements.authorizationCodeWrap.classList.toggle('hidden', !authorization.user_code);
  elements.copyAuthorizationCode.classList.toggle('hidden', !authorization.user_code);
}

async function copyAuthorizationCode() {
  const code = state.authorization?.user_code;
  if (!code) return;
  try {
    await navigator.clipboard.writeText(code);
    elements.copyAuthorizationCode.textContent = 'Copied';
    setTimeout(() => { elements.copyAuthorizationCode.textContent = 'Copy code'; }, 1400);
  } catch {
    showError(`Copy failed. Select the code manually: ${code}`);
  }
}

function formatExpiry(value) {
  if (!value) return 'Session token active';
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? 'Session token active' : `Expires ${date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
}

function renderProviders() {
  elements.providers.replaceChildren();
  for (const provider of state.snapshot.providers) {
    const card = elements.providerTemplate.content.firstElementChild.cloneNode(true);
    card.classList.toggle('authenticated', provider.authenticated);
    card.querySelector('.provider-icon').textContent = provider.id.slice(0, 2).toUpperCase();
    card.querySelector('h3').textContent = provider.id[0].toUpperCase() + provider.id.slice(1);
    card.querySelector('p').textContent = provider.authenticated ? formatExpiry(provider.expires_at) : 'Authorization required';
    const button = card.querySelector('button');
    button.textContent = provider.authenticated ? 'Connected' : 'Connect';
    button.disabled = !state.hostOnline || provider.authenticated || state.operation?.status === 'running';
    button.addEventListener('click', () => connectProvider(provider.id));
    elements.providers.append(card);
  }
}

function flag(label, value) {
  const wrapper = document.createElement('span');
  wrapper.className = 'flag';
  const caption = document.createElement('span');
  caption.textContent = label;
  const strong = document.createElement('strong');
  strong.textContent = value;
  wrapper.append(caption, strong);
  return wrapper;
}

function formatDateTime(value, fallback = 'Unknown') {
  if (!value) return fallback;
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return fallback;
  return date.toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' });
}

function statusLabel(check) {
  if (!check) return 'Not checked';
  if (check.conclusion) return check.conclusion[0].toUpperCase() + check.conclusion.slice(1);
  if (check.status && check.status !== 'completed') return check.status.replaceAll('_', ' ');
  return { healthy: 'Healthy', unhealthy: 'Issue detected', unknown: 'Unknown' }[check.state] || 'Unknown';
}

function statusDetail(kind, check) {
  if (!check) return 'Connect providers and refresh live status.';
  if (kind === 'bitbucket_repository' || kind === 'github_repository') {
    return check.updated_at ? `Updated ${formatDateTime(check.updated_at)}` : check.reason;
  }
  if (kind === 'cloudflare_worker' && check.state === 'healthy') return `Binding ${check.secret_binding}`;
  if (kind === 'github_actions' && check.run_number) {
    return `Run #${check.run_number} · ${formatDateTime(check.updated_at || check.started_at)}`;
  }
  return check.reason;
}

function renderStatusItem(item, kind, check) {
  const stateName = check?.state || 'unknown';
  item.dataset.state = stateName;
  item.title = check?.reason || 'Live status has not been checked.';
  item.querySelector('strong').textContent = statusLabel(check);
  item.querySelector('p').textContent = statusDetail(kind, check);
  const link = item.querySelector('a');
  link.classList.toggle('hidden', !check?.url);
  if (check?.url) link.href = check.url;
  else link.removeAttribute('href');
}

function getMirrorStatus(mirrorId) {
  return state.snapshot.status?.mirrors?.find((item) => item.id === mirrorId) || null;
}

function renderStatusHeading() {
  const status = state.snapshot.status;
  if (!status?.checked_at) elements.statusChecked.textContent = 'Status not checked';
  else elements.statusChecked.textContent = `${status.is_stale ? 'Status may be stale · ' : 'Checked '}${formatDateTime(status.checked_at)}`;
  const refreshing = state.operation?.action === 'refresh-status' && state.operation?.status === 'running';
  elements.refreshStatus.textContent = refreshing ? 'Refreshing…' : 'Refresh status';
  elements.refreshStatus.disabled = !state.hostOnline || state.operation?.status === 'running';
}

function renderMirrors() {
  elements.mirrorList.replaceChildren();
  const mirrors = state.snapshot.mirrors;
  renderStatusHeading();
  elements.mirrorCount.textContent = `${mirrors.length} mirror${mirrors.length === 1 ? '' : 's'}`;
  for (const mirror of mirrors) {
    const card = elements.mirrorTemplate.content.firstElementChild.cloneNode(true);
    const liveStatus = getMirrorStatus(mirror.id);
    card.classList.toggle('disabled', !mirror.enabled);
    card.dataset.state = liveStatus?.overall?.state || 'unknown';
    card.title = liveStatus?.overall?.reason || 'Live status has not been checked.';
    card.querySelector('h3').textContent = mirror.id;
    card.querySelector('.pill').textContent = mirror.enabled ? 'Enabled' : 'Disabled';
    card.querySelector('.route').textContent = `${mirror.bitbucket_repository}  →  ${mirror.github_repository}`;
    const flags = card.querySelector('.mirror-flags');
    flags.append(flag('Recovery', mirror.scheduled_recovery ? 'Scheduled' : 'Manual'));
    flags.append(flag('Last sync', formatDateTime(liveStatus?.last_successful_sync?.completed_at, 'No successful run')));
    for (const item of card.querySelectorAll('.status-item')) {
      const kind = item.dataset.statusKind;
      renderStatusItem(item, kind, liveStatus?.[kind]);
    }
    card.querySelector('.validate').addEventListener('click', () => runOperation('validate', { MirrorId: mirror.id }));
    card.querySelector('.dispatch').addEventListener('click', () => runOperation('dispatch', { MirrorId: mirror.id, Dispatch: true }));
    card.querySelector('.manage').addEventListener('click', () => openManageDialog(mirror));
    for (const button of card.querySelectorAll('button')) button.disabled = !state.hostOnline || state.operation?.status === 'running';
    elements.mirrorList.append(card);
  }
}

function renderOperation(operation) {
  state.operation = operation;
  const status = operation?.status || 'idle';
  elements.operationState.className = `operation-state ${status}`;
  elements.operationState.textContent = status[0].toUpperCase() + status.slice(1);
  elements.operationName.textContent = operation ? operation.action : 'No operation running';
  elements.cancelOperation.classList.toggle('hidden', operation?.status !== 'running');
  elements.applyPlan.classList.toggle('hidden', !(operation?.status === 'succeeded' && state.pendingPlan));
  if (operation?.action === 'connect-provider') {
    if (operation.authorization?.authorization_uri !== state.authorization?.authorization_uri) {
      renderAuthorization(operation.authorization);
      if (operation.authorization) navigateAuthenticationPopup(operation.authorization.authorization_uri);
    }
    if (['succeeded', 'failed', 'cancelled'].includes(operation.status)) {
      closeAuthenticationPopup();
      renderAuthorization(null);
    }
  } else if (operation) {
    renderAuthorization(null);
  }
  if (operation) {
    const lines = [...(operation.output || [])];
    if (operation.error) lines.push('', `ERROR: ${operation.error}`);
    elements.operationLog.textContent = lines.join('\n') || 'Operation started…';
    elements.operationLog.scrollTop = elements.operationLog.scrollHeight;
  }
  if (state.snapshot) {
    renderProviders();
    renderMirrors();
  }
}

async function refreshSnapshot() {
  state.snapshot = await api('/api/snapshot');
  renderProviders();
  renderMirrors();
}

async function pollOperation() {
  try {
    const operation = await api('/api/operation');
    renderOperation(operation);
    if (operation?.status === 'running') return;
    clearInterval(state.poller);
    state.poller = null;
    await refreshSnapshot();
  } catch (error) {
    clearInterval(state.poller);
    state.poller = null;
    showError(error);
  }
}

async function checkHost() {
  try {
    const health = await api('/api/health');
    if (state.runtimeId && health.runtime_id !== state.runtimeId) {
      window.location.reload();
      return;
    }
    if (!state.hostOnline) window.location.reload();
  } catch {
    setHostUnavailable();
  }
}

async function cancelOperation() {
  clearError();
  try {
    const operation = await api('/api/operation/cancel', {
      method: 'POST',
      body: '{}',
    });
    closeAuthenticationPopup();
    renderAuthorization(null);
    renderOperation(operation);
    await refreshSnapshot();
  } catch (error) {
    showError(error);
  }
}

async function runOperation(action, args = {}, isApply = false) {
  clearError();
  const plannedActions = ['new-mirror', 'remove-mirror', 'deploy-worker', 'set-mirror'];
  if (!isApply) state.pendingPlan = plannedActions.includes(action) ? { action, args } : null;
  try {
    const operation = await api('/api/operation', {
      method: 'POST',
      body: JSON.stringify({ action, arguments: args }),
    });
    renderOperation(operation);
    if (action !== 'refresh-status') document.querySelector('#activity').scrollIntoView({ behavior: 'smooth', block: 'start' });
    if (!state.poller) state.poller = setInterval(pollOperation, 800);
  } catch (error) {
    if (!isApply) state.pendingPlan = null;
    if (action === 'connect-provider') {
      closeAuthenticationPopup();
      renderAuthorization(null);
    }
    showError(error);
  }
}

function field({ name, label, type = 'text', value = '', required = false, full = false, options = null }) {
  const wrapper = document.createElement('div');
  wrapper.className = `field${full ? ' full' : ''}`;
  const caption = document.createElement('label');
  caption.htmlFor = `field-${name}`;
  caption.textContent = label;
  let input;
  if (options) {
    input = document.createElement('select');
    for (const [optionValue, optionLabel] of options) {
      const option = document.createElement('option');
      option.value = optionValue;
      option.textContent = optionLabel;
      input.append(option);
    }
  } else {
    input = document.createElement('input');
    input.type = type;
  }
  input.id = `field-${name}`;
  input.name = name;
  input.value = value;
  input.required = required;
  input.autocomplete = type === 'password' ? 'off' : 'on';
  wrapper.append(caption, input);
  return wrapper;
}

function checkField(name, label, checked = false) {
  const wrapper = document.createElement('label');
  wrapper.className = 'check-field';
  const input = document.createElement('input');
  input.type = 'checkbox';
  input.name = name;
  input.checked = checked;
  wrapper.append(input, document.createTextNode(label));
  return wrapper;
}

function openDialog({ eyebrow, title, note, submit = 'Continue', danger = false, fields = [], onSubmit }) {
  state.dialogAction = onSubmit;
  elements.dialogEyebrow.textContent = eyebrow;
  elements.dialogTitle.textContent = title;
  elements.dialogNote.textContent = note || '';
  elements.dialogSubmit.textContent = submit;
  elements.dialogSubmit.className = `button ${danger ? 'danger' : 'primary'}`;
  elements.dialogFields.replaceChildren(...fields);
  elements.dialog.showModal();
}

function closeDialog() {
  state.dialogAction = null;
  if (elements.dialog.open) elements.dialog.close();
}

function formValues(form) {
  const values = {};
  for (const [name, value] of new FormData(form).entries()) values[name] = value;
  for (const checkbox of form.querySelectorAll('input[type="checkbox"]')) values[checkbox.name] = checkbox.checked;
  return values;
}

function connectProvider(provider) {
  const label = provider[0].toUpperCase() + provider.slice(1);
  const fields = provider === 'bitbucket'
    ? [field({ name: 'BitbucketClientSecret', label: 'OAuth consumer secret', type: 'password', required: true, full: true })]
    : [];
  openDialog({
    eyebrow: 'Management session',
    title: `Connect ${label}`,
    note: provider === 'github'
      ? 'GitHub uses a device code. Copy the code shown in Activity into the provider page.'
      : 'The provider authorization page opens in your browser and closes after a successful callback.',
    submit: 'Start authorization',
    fields,
    onSubmit: (values) => {
      closeAuthenticationPopup();
      renderAuthorization(null);
      state.authPopup = openAuthenticationPopup();
      runOperation('connect-provider', { Provider: label, ...values });
    },
  });
}

function openManageDialog(mirror) {
  openDialog({
    eyebrow: mirror.id,
    title: 'Manage mirror',
    note: 'Choose a bounded operation. Configuration changes retain plan/apply behavior; destructive removal requires a separate confirmation.',
    submit: 'Open operation',
    fields: [field({
      name: 'operation', label: 'Operation', full: true, options: [
        ['validate-sync', 'Validate full synchronization'],
        ['enabled', mirror.enabled ? 'Disable mirror' : 'Enable mirror'],
        ['recovery', mirror.scheduled_recovery ? 'Disable scheduled recovery' : 'Enable scheduled recovery'],
        ['repair', 'Repair credentials'],
        ['repair-webhook', 'Repair credentials and webhook'],
        ['rotate-prepare', 'Prepare key rotation'],
        ['rotate-finalize', 'Finalize key rotation'],
        ['remove', 'Remove mirror infrastructure'],
      ],
    })],
    onSubmit: ({ operation }) => openMirrorOperation(mirror, operation),
  });
}

function openMirrorOperation(mirror, operation) {
  if (operation === 'validate-sync') {
    openDialog({
      eyebrow: mirror.id, title: 'Validate synchronization', submit: 'Run validation',
      note: 'Creates and prunes temporary validation references in the selected local Bitbucket checkout.',
      fields: [field({ name: 'SourceRepositoryPath', label: 'Local source repository path', required: true, full: true })],
      onSubmit: (values) => runOperation('validate-sync', { MirrorId: mirror.id, ValidateSync: true, ...values }),
    });
    return;
  }
  if (operation === 'enabled' || operation === 'recovery') {
    const setting = operation === 'enabled' ? 'Enabled' : 'ScheduledRecovery';
    const value = operation === 'enabled' ? !mirror.enabled : !mirror.scheduled_recovery;
    openDialog({
      eyebrow: mirror.id, title: `${value ? 'Enable' : 'Disable'} ${operation === 'enabled' ? 'mirror' : 'scheduled recovery'}`,
      submit: 'Show plan', note: 'This first runs in planning mode. Apply the reviewed plan as a separate action.',
      onSubmit: () => runOperation('set-mirror', { MirrorId: mirror.id, Setting: setting, Value: value }),
    });
    return;
  }
  if (operation.startsWith('repair')) {
    openDialog({
      eyebrow: mirror.id, title: 'Repair mirror', submit: 'Start repair',
      note: 'Creates replacement credentials and dispatches a test. Finalize the key rotation only after that workflow succeeds.',
      danger: operation === 'repair-webhook',
      onSubmit: () => runOperation('repair-mirror', { MirrorId: mirror.id, RepairWebhook: operation === 'repair-webhook' }),
    });
    return;
  }
  if (operation.startsWith('rotate-')) {
    const phase = operation === 'rotate-prepare' ? 'Prepare' : 'Finalize';
    openDialog({
      eyebrow: mirror.id, title: `${phase} key rotation`, submit: `${phase} rotation`,
      note: phase === 'Finalize' ? 'This removes the superseded managed deploy keys.' : 'This creates replacement deploy keys and dispatches a verification run.',
      danger: phase === 'Finalize',
      onSubmit: () => runOperation('rotate-keys', { MirrorId: mirror.id, Phase: phase }),
    });
    return;
  }
  openDialog({
    eyebrow: mirror.id, title: 'Remove mirror infrastructure', submit: 'Show removal plan',
    note: 'Planning is non-mutating. The Bitbucket source repository is never deleted.', danger: true,
    fields: [checkField('DeleteTargetRepository', 'Include deletion of the GitHub target repository')],
    onSubmit: (values) => runOperation('remove-mirror', { MirrorId: mirror.id, ...values }),
  });
}

function openNewMirrorDialog() {
  openDialog({
    eyebrow: 'Provisioning', title: 'New mirror', submit: 'Show provisioning plan',
    note: 'Planning is non-mutating. Review the complete resource plan in Activity before applying it.',
    fields: [
      field({ name: 'MirrorId', label: 'Mirror ID', required: true }),
      field({ name: 'BitbucketRepository', label: 'Bitbucket source', required: true }),
      field({ name: 'GitHubRepository', label: 'GitHub target', required: true, full: true }),
      checkField('UseExistingTarget', 'Adopt an existing private GitHub target'),
      checkField('ScheduledRecovery', 'Enable scheduled recovery after provisioning'),
    ],
    onSubmit: (values) => runOperation('new-mirror', values),
  });
}

function openWorkerDialog() {
  openDialog({
    eyebrow: 'Cloudflare', title: 'Deploy Worker', submit: 'Show deployment plan',
    note: 'The planning pass does not deploy or mutate provider resources.',
    fields: [field({ name: 'GitHubAppPrivateKeyPath', label: 'Private key path (only when rotating)', full: true })],
    onSubmit: (values) => runOperation('deploy-worker', values),
  });
}

elements.form.addEventListener('submit', (event) => {
  event.preventDefault();
  if (!elements.form.reportValidity()) return;
  const values = formValues(elements.form);
  const action = state.dialogAction;
  closeDialog();
  action?.(values);
});

for (const button of elements.dialog.querySelectorAll('[data-dialog-dismiss]')) {
  button.addEventListener('click', closeDialog);
}

elements.dialog.addEventListener('cancel', (event) => {
  event.preventDefault();
  closeDialog();
});

elements.dialog.addEventListener('click', (event) => {
  if (event.target !== elements.dialog) return;
  const bounds = elements.dialog.getBoundingClientRect();
  const inside = event.clientX >= bounds.left && event.clientX <= bounds.right
    && event.clientY >= bounds.top && event.clientY <= bounds.bottom;
  if (!inside) closeDialog();
});

document.querySelector('#new-mirror').addEventListener('click', openNewMirrorDialog);
document.querySelector('#deploy-worker').addEventListener('click', openWorkerDialog);
elements.refreshStatus.addEventListener('click', () => runOperation('refresh-status'));
elements.applyPlan.addEventListener('click', () => {
  if (!state.pendingPlan) return;
  const plan = state.pendingPlan;
  openDialog({
    eyebrow: 'Reviewed plan', title: 'Apply this operation?', submit: 'Apply plan', danger: plan.action === 'remove-mirror',
    note: 'This executes the exact operation and inputs shown in the completed planning pass.',
    onSubmit: () => {
      state.pendingPlan = null;
      runOperation(plan.action, { ...plan.args, Apply: true }, true);
    },
  });
});
document.querySelector('#disconnect').addEventListener('click', () => openDialog({
  eyebrow: 'Management session', title: 'Disconnect all providers', submit: 'Disconnect', danger: true,
  note: 'Clears all management credentials from the local host process.',
  onSubmit: () => runOperation('disconnect-session'),
}));
elements.copyAuthorizationCode.addEventListener('click', copyAuthorizationCode);
elements.cancelOperation.addEventListener('click', cancelOperation);
elements.openAuthorization.addEventListener('click', () => {
  if (!state.authorization) return;
  closeAuthenticationPopup();
  state.authPopup = openAuthenticationPopup();
  navigateAuthenticationPopup(state.authorization.authorization_uri);
});

for (const link of document.querySelectorAll('.nav-link')) {
  link.addEventListener('click', () => {
    for (const item of document.querySelectorAll('.nav-link')) item.classList.toggle('active', item === link);
  });
}

async function initialize() {
  try {
    const bootstrap = await api('/api/bootstrap');
    state.token = bootstrap.request_token;
    state.runtimeId = bootstrap.runtime_id;
    state.hostOnline = true;
    await refreshSnapshot();
    const operation = await api('/api/operation');
    renderOperation(operation);
    if (operation?.status === 'running') state.poller = setInterval(pollOperation, 800);
    state.heartbeat = setInterval(checkHost, 1000);
  } catch (error) {
    showError(error);
  }
}

window.addEventListener('pagehide', closeAuthenticationPopup);

async function startExclusiveClient() {
  if (!navigator.locks?.request) {
    await initialize();
    return;
  }

  await navigator.locks.request('mirror-manager-active-ui', { ifAvailable: true }, async (lock) => {
    if (!lock) {
      window.close();
      elements.operationState.className = 'operation-state failed';
      elements.operationState.textContent = 'Duplicate';
      elements.operationName.textContent = 'Mirror Manager is already open';
      elements.operationLog.textContent = 'Use the existing Mirror Manager tab and close this duplicate.';
      showError('Another Mirror Manager tab already owns this local session.');
      return;
    }

    await initialize();
    await new Promise((resolve) => window.addEventListener('pagehide', resolve, { once: true }));
  });
}

startExclusiveClient();
