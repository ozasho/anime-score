const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const html = fs.readFileSync(require('node:path').join(__dirname, '../index.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1].split('// Init')[0];

function fixture(send) {
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, {
      value: '', style: {}, dataset: {}, textContent: '', hidden: false,
      checkValidity: () => true, focus() {},
    });
    return elements.get(id);
  };
  const context = vm.createContext({
    localStorage: { getItem: () => null },
    document: { getElementById: element, querySelector: () => null, addEventListener() {} },
    window: {}, console, URL, Date,
    location: { href: 'https://ozasho.github.io/anime-score/index.html?from=mobile#token' },
    setInterval: () => 1, clearInterval() {},
  });
  vm.runInContext(script, context);
  context.client = { auth: { signInWithOtp: send } };
  vm.runInContext('ensureCloudClient = async () => client; showToast = () => {};', context);
  element('cloud-email').value = ' user@example.com ';
  return { context, element, login: () => vm.runInContext('cloudLogin()', context) };
}

test('successful login normalizes the redirect and blocks immediate resend', async () => {
  let calls = 0;
  const f = fixture(async request => {
    calls++;
    assert.equal(request.email, 'user@example.com');
    assert.equal(request.options.emailRedirectTo, 'https://ozasho.github.io/anime-score/');
    return { error: null };
  });
  await f.login();
  await f.login();
  assert.equal(calls, 1);
  assert.equal(f.element('cloud-login-btn').disabled, true);
  assert.match(f.element('cloud-login-feedback').textContent, /送信しました/);
});

test('pending login prevents simultaneous email requests', async () => {
  let finish;
  let calls = 0;
  const f = fixture(() => { calls++; return new Promise(resolve => { finish = resolve; }); });
  const pending = f.login();
  await Promise.resolve();
  await f.login();
  finish({ error: null });
  await pending;
  assert.equal(calls, 1);
});

test('network failure remains visible and releases the button', async () => {
  const f = fixture(async () => { throw new TypeError('Failed to fetch'); });
  await f.login();
  assert.match(f.element('cloud-login-feedback').textContent, /認証サーバーに接続できません/);
  assert.equal(f.element('cloud-login-feedback').dataset.error, 'true');
  assert.equal(f.element('cloud-login-btn').disabled, false);
});

test('email quota error explains the problem and throttles resends', async () => {
  const f = fixture(async () => ({ error: { code: 'over_email_send_rate_limit', status: 429 } }));
  await f.login();
  assert.match(f.element('cloud-login-feedback').textContent, /メール送信上限/);
  assert.equal(f.element('cloud-login-btn').disabled, true);
});

test('invalid email is rejected before making a request', async () => {
  let calls = 0;
  const f = fixture(async () => { calls++; });
  f.element('cloud-email').checkValidity = () => false;
  await f.login();
  assert.equal(calls, 0);
  assert.match(f.element('cloud-login-feedback').textContent, /正しいメールアドレス/);
});

test('client initialization failure is caught', async () => {
  const f = fixture(async () => { throw new Error('not reached'); });
  vm.runInContext('ensureCloudClient = async () => { throw new TypeError("Failed to fetch dynamically imported module"); };', f.context);
  await f.login();
  assert.match(f.element('cloud-login-feedback').textContent, /認証サーバーに接続できません/);
  assert.equal(f.element('cloud-login-btn').disabled, false);
});
