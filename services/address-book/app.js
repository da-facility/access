'use strict';
const $ = id => document.getElementById(id);
let token = '', guid = '', peers = [], kvms = [], editing = null;
$('apiUrl').textContent = location.origin;
function message(value, error = false) { $('message').textContent = value; $('message').className = error ? 'error' : ''; }
function signedOut() { token = ''; guid = ''; peers = []; kvms = []; $('book').hidden = true; $('auth').hidden = false; $('logout').hidden = true; $('connections').replaceChildren(); resetEditor(); }
async function api(path, method = 'GET', body) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(15000), redirect: 'error' });
  const raw = await response.text(); const data = raw ? JSON.parse(raw) : null;
  if (!response.ok) { if (response.status === 401 && token) signedOut(); throw new Error(data?.error || `Request failed (${response.status})`); }
  return data;
}
async function run(button, action) { button.disabled = true; message(''); try { await action(); } catch (error) { message(error.message, true); } finally { button.disabled = false; } }
api('/api/access/capabilities').then(c => { $('register').hidden = !c.registration; $('registrationHint').hidden = !c.registration; }).catch(e => message(e.message, true));
$('login').onsubmit = event => { event.preventDefault(); run(event.submitter, async () => {
  const form = new FormData($('login'));
  const data = await api('/api/login', 'POST', { username: form.get('username'), password: form.get('password'), type: 'account', autoLogin: false });
  token = data.access_token; $('login').elements.password.value = '';
  guid = (await api('/api/ab/personal', 'POST')).guid;
  $('owner').textContent = `${data.user.name}'s connections`;
  $('auth').hidden = true; $('book').hidden = false; $('logout').hidden = false;
  await refresh();
}); };
$('register').onclick = () => run($('register'), async () => { const form = new FormData($('login')); await api('/api/access/register', 'POST', {username: form.get('username'), password: form.get('password')}); message('Account created. You can now sign in.'); });
$('logout').onclick = () => run($('logout'), async () => { try { await api('/api/logout', 'POST'); } finally { signedOut(); } });
$('refresh').onclick = () => run($('refresh'), refresh);
async function refresh() {
  const all = []; let page = 1, result;
  do { result = await api(`/api/ab/peers?ab=${encodeURIComponent(guid)}&current=${page++}&pageSize=100`, 'POST'); all.push(...result.data); } while (all.length < result.total);
  const devices = await api('/api/access/kvms');
  peers = all; kvms = devices.items; render();
}
function render() {
  $('connections').replaceChildren(); $('empty').hidden = peers.length + kvms.length > 0;
  for (const [kind, items] of [['rustdesk', peers], ['kvm', kvms]]) for (const item of items) {
    const li = document.createElement('li'), title = document.createElement('strong'), details = document.createElement('p'), actions = document.createElement('div');
    title.textContent = kind === 'rustdesk' ? item.alias || item.id : item.name;
    details.textContent = kind === 'rustdesk' ? `RustDesk · ${item.id}` : `${item.model === 'RM4PE' ? 'Comet X' : 'Comet Q'} · ${item.address}`;
    actions.className = 'actions';
    for (const label of ['Edit', 'Remove']) { const button = document.createElement('button'); button.className = 'secondary'; button.textContent = label; button.onclick = () => label === 'Edit' ? edit(kind, item) : run(button, async () => { if (!confirm(`Remove ${title.textContent} from your address book?`)) return; await api(kind === 'rustdesk' ? `/api/ab/peer/${guid}` : '/api/access/kvms', 'DELETE', kind === 'rustdesk' ? [item.id] : {id: item.id}); if (editing?.item.id === item.id) resetEditor(); await refresh(); }); actions.append(button); }
    li.append(title, details, actions); $('connections').append(li);
  }
}
const fields = $('entry').elements;
function kindChanged() { const isKvm = fields.kind.value !== 'rustdesk'; $('usernameField').hidden = !isKvm; $('addressLabel').firstChild.textContent = isKvm ? 'KVM address' : 'RustDesk ID or address'; fields.address.placeholder = isKvm ? 'https://glkvm.example.ts.net' : '123456789'; }
fields.kind.onchange = kindChanged;
function resetEditor() { editing = null; $('entry').reset(); fields.kind.disabled = false; fields.kind.options[0].disabled = false; fields.address.disabled = false; $('cancel').hidden = true; $('editorTitle').textContent = 'Add a connection'; kindChanged(); }
function edit(kind, item) { editing = {kind, item}; fields.kind.value = kind === 'rustdesk' ? kind : item.model; fields.kind.disabled = kind === 'rustdesk'; fields.kind.options[0].disabled = kind !== 'rustdesk'; fields.name.value = kind === 'rustdesk' ? item.alias || item.id : item.name; fields.address.value = kind === 'rustdesk' ? item.id : item.address; fields.address.disabled = kind === 'rustdesk'; fields.username.value = item.username || 'admin'; $('cancel').hidden = false; $('editorTitle').textContent = 'Edit connection'; kindChanged(); fields.name.focus(); }
$('cancel').onclick = resetEditor;
$('entry').onsubmit = event => { event.preventDefault(); run(event.submitter, async () => {
  if (fields.kind.value === 'rustdesk') {
    await api(`/api/ab/peer/${editing ? 'update' : 'add'}/${guid}`, editing ? 'PUT' : 'POST', {id: fields.address.value.trim(), alias: fields.name.value.trim()});
  } else {
    let address = fields.address.value.trim(); if (!address.includes('://')) address = `https://${address}`;
    await api('/api/access/kvms', editing ? 'PUT' : 'POST', {id: editing?.item.id || crypto.randomUUID(), name: fields.name.value.trim(), address, model: fields.kind.value, username: fields.username.value.trim(), certificateSha256: editing?.item.certificateSha256 || null});
  }
  resetEditor(); await refresh(); message('Connection saved.');
}); };
kindChanged();
