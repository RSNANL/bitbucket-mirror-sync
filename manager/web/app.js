const state = {
  token: null,
  snapshot: null,
  operation: null,
  poller: null,
  dialogAction: null,
  pendingPlan: null,
};

const elements = {
  providers: document.querySelector('#providers'),
  mirrorList: document.querySelector('#mirror-list'),
  mirrorCount: document.querySelector('#mirror-count'),
  providerTemplate: document.querySelector('#provider-template'),
  mirrorTemplate: document.querySelector('#mirror-template'),
  operationState: document.querySelector('#operation-state'),
  operationName: document.querySelector('#operation-name'),
  operationLog: document.querySelector('#operation-log'),
  notice: document.querySelector('#notice'),
  applyPlan: document.querySelector('#apply-plan'),
  dialog: document.querySelector('#action-dialog'),
  form: document.querySelector('#action-form'),
  dialogEyebrow: document.querySelector('#dialog-eyebrow'),
  dialogTitle: document.querySelector('#dialog-title'),
  dialogFields: document.querySelector('#dialog-fields'),
  dialogNote: document.querySelector('#dialog-note'),
  dialogSubmit: document.querySelector('#dialog-submit'),
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
    button.disabled = provider.authenticated || state.operation?.status === 'running';
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

function renderMirrors() {
  elements.mirrorList.replaceChildren();
  const mirrors = state.snapshot.mirrors;
  elements.mirrorCount.textContent = `${mirrors.length} mirror${mirrors.length === 1 ? '' : 's'}`;
  for (const mirror of mirrors) {
    const card = elements.mirrorTemplate.content.firstElementChild.cloneNode(true);
    card.classList.toggle('disabled', !mirror.enabled);
    card.querySelector('h3').textContent = mirror.id;
    card.querySelector('.pill').textContent = mirror.enabled ? 'Enabled' : 'Disabled';
    card.querySelector('.route').textContent = `${mirror.bitbucket_repository}  →  ${mirror.github_repository}`;
    const flags = card.querySelector('.mirror-flags');
    flags.append(flag('Recovery', mirror.scheduled_recovery ? 'Scheduled' : 'Manual'));
    flags.append(flag('Target', 'GitHub'));
    card.querySelector('.validate').addEventListener('click', () => runOperation('validate', { MirrorId: mirror.id }));
    card.querySelector('.dispatch').addEventListener('click', () => runOperation('dispatch', { MirrorId: mirror.id, Dispatch: true }));
    card.querySelector('.manage').addEventListener('click', () => openManageDialog(mirror));
    for (const button of card.querySelectorAll('button')) button.disabled = state.operation?.status === 'running';
    elements.mirrorList.append(card);
  }
}

function renderOperation(operation) {
  state.operation = operation;
  const status = operation?.status || 'idle';
  elements.operationState.className = `operation-state ${status}`;
  elements.operationState.textContent = status[0].toUpperCase() + status.slice(1);
  elements.operationName.textContent = operation ? operation.action : 'No operation running';
  elements.applyPlan.classList.toggle('hidden', !(operation?.status === 'succeeded' && state.pendingPlan));
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
    document.querySelector('#activity').scrollIntoView({ behavior: 'smooth', block: 'start' });
    if (!state.poller) state.poller = setInterval(pollOperation, 800);
  } catch (error) {
    if (!isApply) state.pendingPlan = null;
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
    onSubmit: (values) => runOperation('connect-provider', { Provider: label, ...values }),
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
  if (event.submitter?.value !== 'default') return;
  event.preventDefault();
  if (!elements.form.reportValidity()) return;
  const values = formValues(elements.form);
  elements.dialog.close();
  state.dialogAction?.(values);
  state.dialogAction = null;
});

document.querySelector('#new-mirror').addEventListener('click', openNewMirrorDialog);
document.querySelector('#deploy-worker').addEventListener('click', openWorkerDialog);
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

for (const link of document.querySelectorAll('.nav-link')) {
  link.addEventListener('click', () => {
    for (const item of document.querySelectorAll('.nav-link')) item.classList.toggle('active', item === link);
  });
}

async function initialize() {
  try {
    state.token = (await api('/api/bootstrap')).request_token;
    await refreshSnapshot();
    const operation = await api('/api/operation');
    renderOperation(operation);
    if (operation?.status === 'running') state.poller = setInterval(pollOperation, 800);
  } catch (error) {
    showError(error);
  }
}

initialize();
