'use strict';
// node --test tests/test-webui.js. Execute the shipped inline script, not a copy of its logic.
// The small DOM, clock, XHR, clipboard and named KernelSU callback below are all in-memory.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const {spawnSync} = require('node:child_process');
const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'webroot/index.html'), 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
assert.equal(scripts.length, 1);
const ui = new vm.Script(scripts[0][1], {filename: 'webroot/index.html'});
const epoch = 1700000000;
const bare = 'http://127.0.0.1:3430/';
const fixtureKey = 'test_only-placeholder';
const login = bare + '?k=' + fixtureKey;
const snapshot = (extra = {}) => ({updatedEpoch: epoch, running: true, pid: '123',
  lanOpen: true, apiUrl: 'http://127.0.0.1:3425/v1', lanApiUrl: 'http://192.0.2.5:3425/v1',
  webUrl: bare, ...extra});

class Events {
  constructor() { this.events = {}; }
  addEventListener(type, cb) { (this.events[type] ||= []).push(cb); }
  emit(type) { for (const cb of this.events[type] || []) cb.call(this, {target: this}); }
}
class Element extends Events {
  constructor(tag, attrs) {
    super(); this.tag = tag; this.attrs = attrs; this.style = {}; this.textContent = '';
    this.disabled = 'disabled' in attrs; this.classList = new Set((attrs.class || '').split(' '));
    this.classList.remove = this.classList.delete;
    this.classList.toggle = (c, on) => on ? this.classList.add(c) : this.classList.delete(c);
  }
  getAttribute(k) { return this.attrs[k]; }
  click() { if (!this.disabled) this.emit('click'); }
}
function app(options = {}) {
  // Derive the actual IDs, navigation buttons, copy targets and initial disabled state from the HTML.
  const nodes = [...html.slice(0, scripts[0].index).matchAll(/<(\w+)\b([^<>]*)>/g)].map(m =>
    new Element(m[1], Object.fromEntries([...m[2].matchAll(/([^\s=]+)(?:="([^"]*)")?/g)]
      .map(a => [a[1], a[2] ?? '']))));
  const ids = Object.fromEntries(nodes.filter(n => n.attrs.id).map(n => [n.attrs.id, n]));
  const nav = nodes.filter(n => n.attrs['data-page']);
  const buttons = nodes.filter(n => n.attrs['data-copy']);
  const doc = new Events(), win = new Events();
  const requests = [], commands = [], opened = [], clipboard = [], writes = [];
  const timers = new Map(); let now = epoch * 1000, sequence = 0;
  const later = (fn, ms) => { timers.set(++sequence, {at: now + ms, fn}); return sequence; };
  const clear = id => timers.delete(id);
  function tick(ms) {
    const end = now + ms;
    for (;;) {
      const next = [...timers].sort((a, b) => a[1].at - b[1].at)[0];
      if (!next || next[1].at > end) break;
      clear(next[0]); now = next[1].at; next[1].fn();
    }
    now = end;
  }
  class Xhr {
    constructor() { if (options.xhrError) throw Error('mock XHR unavailable'); }
    setRequestHeader(name, value) { this.header = [name, value]; }
    open(method, url, async) {
      assert.equal(method, 'GET'); assert.equal(async, true);
      this.url = url; this.file = url.split('?')[0];
      assert.ok(['status.json', 'lastlog.txt'].includes(this.file));
    }
    send() {
      requests.push(this);
      if (options.sendError) throw Error('mock send failure');
      if (this.timeout) this.timer = later(() => this.ontimeout(), this.timeout);
    }
    reply(data, status = 200) {
      clear(this.timer); this.status = status;
      this.responseText = typeof data === 'string' ? data : JSON.stringify(data);
      // May also deliver an event already queued before timeout/abort.
      this.onload();
    }
    error() { clear(this.timer); this.onerror(); }
    abort() { this.aborted = true; clear(this.timer); this.onabort(); }
  }
  let area;
  Object.assign(doc, {
    hidden: !!options.hidden,
    getElementById: id => ids[id],
    querySelectorAll: selector => ({'.nav-i': nav, '[data-copy]': buttons}[selector]),
    createElement: tag => { assert.equal(tag, 'textarea'); return {style: {}, select() {}}; },
    body: {appendChild: n => { area = n; }, removeChild: n => { assert.equal(n, area); area = null; }},
    execCommand: op => { assert.equal(op, 'copy'); clipboard.push(area.value); return options.copyOK !== false; },
  });
  Object.defineProperty(doc, 'cookie', {set() { writes.push('cookie'); }});
  const storage = {setItem() { writes.push('storage'); }};
  const context = Object.assign(win, {window: win, document: doc, XMLHttpRequest: Xhr,
    Date: class extends Date { static now() { return now; } },
    setTimeout: later, clearTimeout: clear, scrollTo() {},
    location: {hash: options.hash ?? '#status', protocol: options.protocol || 'https:',
      replace(s) { if (options.replaceError) throw Error('mock navigation rejection'); opened.push(s); }},
    navigator: {clipboard: options.clipboard}, localStorage: storage, sessionStorage: storage,
    console: {log() { writes.push('console'); }, error() { writes.push('console'); }},
  });
  if (options.bridge) context.ksu = {exec(cmd, opts, name) {
    commands.push({cmd, opts, name, cb: win[name]});
    return typeof options.bridge === 'function' ? options.bridge() : undefined;
  }};
  ui.runInNewContext(context);
  return {ids, win, doc, buttons, requests, commands, opened, clipboard, writes, tick,
    request: () => requests.at(-1), command: () => commands.at(-1),
    page(name) { nav.find(n => n.attrs['data-page'] === 'page-' + name).click(); },
    hide(hidden) { doc.hidden = hidden; doc.emit('visibilitychange'); },
    text: id => ids[id].textContent,
  };
}
function noAddresses(a) {
  for (const b of a.buttons) {
    assert.equal(b.disabled, true); assert.equal(a.text(b.attrs['data-copy']), '—');
  }
  assert.equal(a.ids.fLanApi.style.display, 'none');
  assert.doesNotMatch(a.text('barSub'), /PID 123/);
}

test('only the visible tab reads; one complete request precedes the next poll', () => {
  const a = app(); const first = a.request();
  assert.equal(first.file, 'status.json'); assert.deepEqual(first.header, ['Cache-Control', 'no-store']);
  a.tick(5000); a.page('home');
  assert.equal(a.requests.length, 1);
  a.page('log'); const log = a.request();
  assert.ok(first.aborted); assert.equal(log.file, 'lastlog.txt');
  first.reply(snapshot()); log.reply(' old log \n'); assert.equal(a.text('log'), 'old log');
  a.tick(4999); assert.equal(a.requests.length, 2);
  a.tick(1); const next = a.request(); assert.equal(next.file, 'lastlog.txt');
  a.tick(8000); assert.match(a.text('log'), /无法读取/); assert.doesNotMatch(a.text('log'), /old log/);
  a.tick(5000); const retry = a.request(); retry.reply('new log');
  next.reply('late log'); assert.equal(a.text('log'), 'new log');
  a.page('home'); a.request().reply(snapshot()); assert.match(a.text('statusText'), /运行中/);
});

test('hidden and pagehide stop I/O, abort old reads/bridge callbacks, and resume immediately', () => {
  const a = app({hidden: true, bridge: true, hash: ''}); a.tick(60000);
  assert.equal(a.requests.length, 0); assert.equal(a.commands.length, 0);
  a.hide(false); const old = a.request(), auto = a.command();
  assert.equal(a.requests.length, 1); assert.equal(a.commands.length, 1);
  a.hide(true); assert.ok(old.aborted); assert.equal(a.win[auto.name], undefined);
  old.reply(snapshot()); auto.cb(0, login); a.tick(60000);
  noAddresses(a); assert.equal(a.opened.length, 0); assert.equal(a.requests.length, 1);
  a.hide(false); const newer = a.request(); newer.reply(snapshot()); old.error();
  assert.match(a.text('statusText'), /运行中/); assert.equal(a.commands.length, 1);
  a.win.emit('pagehide'); a.tick(60000); assert.equal(a.requests.length, 2);
  a.win.emit('pageshow'); a.hide(false); assert.equal(a.requests.length, 3);
  noAddresses(a); a.win.emit('pageshow'); assert.equal(a.requests.length, 3);
});

test('read/HTTP/parse/schema/timeout failures clear every previous PID, candidate and copy action', () => {
  const failures = [r => r.error(), r => r.reply(snapshot(), 503), r => r.reply('{'),
    r => r.reply({running: 'false'}), (r, a) => a.tick(8000)];
  for (const fail of failures) {
    const a = app({bridge: true}); a.request().reply(snapshot({configWarning: 'fixture warning'}));
    assert.match(a.text('barSub'), /PID 123/); assert.match(a.text('barSub'), /fixture warning/);
    assert.ok(a.buttons.every(b => !b.disabled)); a.tick(5000);
    const failed = a.request(); fail(failed, a); noAddresses(a);
    assert.equal(a.ids.statusDot.className, 'dot'); assert.match(a.text('statusText'), /读取失败/);
    assert.doesNotMatch(a.text('barSub'), /fixture warning/); assert.equal(a.text('tipApi'), '');
    assert.equal(a.ids.btnOpen.disabled, false); assert.match(a.text('btnOpen'), /进入本体面板/);
    a.tick(5000); a.request().reply(snapshot({running: false})); failed.reply(snapshot());
    assert.match(a.text('statusText'), /已停止/); assert.equal(a.ids.copyWebUrl.disabled, true);
  }
});

test('static file hosts may lack a status code; HTTP status zero and synchronous I/O errors remain unknown', () => {
  const local = app({protocol: 'file:'}); local.request().reply(snapshot(), 0);
  assert.match(local.text('statusText'), /运行中/); assert.equal(local.request().header, undefined);
  local.tick(5000); local.request().reply('', 0); noAddresses(local);
  const http = app(); http.request().reply(snapshot(), 0); noAddresses(http);
  for (const bad of [{xhrError: true}, {sendError: true}]) {
    const a = app({...bad, bridge: true, hash: ''});
    assert.match(a.text('statusText'), /读取失败/); noAddresses(a);
    assert.equal(a.commands.length, 1); a.command().cb(0, login); assert.deepEqual(a.opened, [login]);
  }
});

test('an unchanged successful read ages out; no midnight guess, future clock, or false stopped badge', () => {
  const a = app(), d = snapshot({updatedEpoch: epoch - 298}); a.request().reply(d);
  assert.match(a.text('statusText'), /快照.*运行中/); a.tick(5000); a.request().reply(d);
  assert.match(a.text('statusText'), /已过期/); noAddresses(a);
  for (const ts of [null, undefined, epoch + 600, 'invalid', 0]) {
    a.tick(5000); a.request().reply(snapshot({updated: '23:59:58', updatedEpoch: ts}));
    assert.match(a.text('statusText'), /时间未知/); noAddresses(a);
  }
  a.tick(5000); a.request().reply(snapshot({configError: '端口冲突'}));
  assert.match(a.text('barSub'), /端口冲突/); noAddresses(a);
});

test('P2 displays only clean addresses; unsupported host cannot enter P1', () => {
  const a = app({hash: ''}); assert.equal(a.ids.btnOpen.tag, 'button');
  a.request().reply(snapshot({webUrl: login, apiUrl: login, lanApiUrl: login}));
  for (const b of a.buttons) assert.ok(b.disabled);
  assert.equal(a.ids.btnOpen.disabled, true); assert.match(a.text('btnOpen'), /不支持/);
  assert.ok(Object.values(a.ids).every(n => !n.textContent.includes(fixtureKey)));
  a.tick(5000); a.request().reply(snapshot()); a.ids.copyWebUrl.click();
  assert.deepEqual(a.clipboard, [bare]); assert.deepEqual(a.opened, []);
});

test('P1 auto/manual use only the fresh controller callback; no DOM, copy or storage of the login link', () => {
  for (const [hash, base] of [['', bare], ['#status', 'http://[::1]:1/'], ['#status', 'http://127.7.0.42:65535/']]) {
    const a = app({bridge: true, hash}); a.request().reply(snapshot({webUrl: ''}));
    if (hash) { assert.equal(a.commands.length, 0); a.ids.btnOpen.click(); }
    const c = a.command(); assert.equal(c.cmd, 'sh /data/adb/modules/magpie/scripts/magpie.service webui-url');
    assert.equal(c.opts, '{}'); a.ids.btnOpen.click(); assert.equal(a.commands.length, 1);
    assert.ok(a.ids.btnOpen.disabled); assert.match(a.text('btnOpen'), /正在核验/);
    a.tick(5000); a.request().error(); assert.match(a.text('btnOpen'), /正在核验/);
    c.cb(0, base + '?k=' + fixtureKey + '\n'); assert.equal(a.win[c.name], undefined);
    assert.deepEqual(a.opened, [base + '?k=' + fixtureKey]); assert.deepEqual(a.clipboard, []);
    assert.deepEqual(a.writes, []); assert.ok(Object.values(a.ids).every(n => !n.textContent.includes(fixtureKey)));
    c.cb(0, login); assert.equal(a.opened.length, 1);
  }
});

test('P1 fails closed on controller failure or non-contract output, reports failure, allows retry', () => {
  const a = app({bridge: true});
  const samples = [[1, login], [0, bare], [0, 'http://localhost:3430/?k=x'],
    [0, 'http://192.0.2.8:3430/?k=x'], [0, 'http://127.0.0.1:65536/?k=x'],
    [0, 'http://127.0.0.256:3430/?k=x'], [0, 'http://127.00.0.1:3430/?k=x'],
    [0, login + '\nsecond line'], [0, login + '&extra=x']];
  for (const [rc, out] of samples) {
    a.ids.btnOpen.click(); const c = a.command(); c.cb(rc, out);
    assert.equal(a.win[c.name], undefined); assert.equal(a.ids.btnOpen.disabled, false);
    assert.deepEqual(a.opened, []); assert.match(a.text('toast'), /重试/);
  }
  assert.equal(a.commands.length, samples.length);
});

test('P1 timeout, late/double callbacks, and a hash change before dispatch cannot navigate', () => {
  const a = app({bridge: true, hash: ''}); const auto = a.command();
  a.win.location.hash = '#status'; auto.cb(0, login); assert.deepEqual(a.opened, []);
  a.ids.btnOpen.click(); const old = a.command(); a.tick(10000);
  assert.equal(a.win[old.name], undefined); assert.equal(a.ids.btnOpen.disabled, false);
  a.ids.btnOpen.click(); const next = a.command(); assert.notEqual(next.name, old.name);
  old.cb(0, login); assert.deepEqual(a.opened, []); assert.ok(a.ids.btnOpen.disabled);
  a.page('log'); next.cb(0, login); assert.deepEqual(a.opened, []);
  a.page('home'); a.ids.btnOpen.click(); a.command().cb(0, login); assert.deepEqual(a.opened, [login]);
});

test('bridge throw, async rejection and navigation rejection restore usable button without echoing errors', async () => {
  for (const bridge of [() => { throw Error(fixtureKey); }, () => Promise.reject(Error(fixtureKey))]) {
    const a = app({bridge}); a.ids.btnOpen.click(); await Promise.resolve();
    assert.equal(a.ids.btnOpen.disabled, false); assert.match(a.text('toast'), /重试/);
    assert.doesNotMatch(a.text('toast'), /test_only/); assert.deepEqual(a.opened, []);
    assert.equal(a.win[a.command().name], undefined);
  }
  const a = app({bridge: true, replaceError: true}); a.ids.btnOpen.click(); a.command().cb(0, login);
  assert.equal(a.ids.btnOpen.disabled, false); assert.match(a.text('toast'), /重试/);
});

test('clipboard rejection/false is not success and a late rejection never copies an invalidated address', async () => {
  let deny;
  const a = app({copyOK: false, clipboard: {writeText() { return new Promise((_, r) => { deny = r; }); }}});
  a.request().reply(snapshot()); a.ids.copyWebUrl.click(); deny(); await Promise.resolve();
  assert.match(a.text('toast'), /复制失败/); assert.deepEqual(a.clipboard, [bare]);
  a.ids.copyWebUrl.click(); a.tick(5000); a.request().error(); deny(); await Promise.resolve();
  assert.deepEqual(a.clipboard, [bare]);
});

test('an older clipboard rejection never overwrites a more recent copy', async () => {
  const replies = [];
  const a = app({clipboard: {writeText() { return new Promise((resolve, reject) => replies.push({resolve, reject})); }}});
  a.request().reply(snapshot()); a.ids.copyApiUrl.click(); a.ids.copyWebUrl.click();
  replies[1].resolve(); await Promise.resolve(); assert.match(a.text('toast'), /已复制/);
  replies[0].reject(); await Promise.resolve(); assert.deepEqual(a.clipboard, []);
});

test('producer emits the legacy clock plus an absolute sample time, mode 0600 and no raw bad config', () => {
  const w = fs.mkdtempSync(path.join(os.tmpdir(), 'magpie-webui.'));
  try {
    for (const d of ['scripts', 'webroot', 'run', 'stub']) fs.mkdirSync(path.join(w, d));
    fs.copyFileSync(path.join(root, 'scripts/status.sh'), path.join(w, 'scripts/status.sh'));
    fs.copyFileSync(path.join(root, 'scripts/lib.sh'), path.join(w, 'scripts/lib.sh'));
    // No service or network probes. A 'running' fixture uses only the test shell's PID and a stub controller.
    fs.appendFileSync(path.join(w, 'scripts/lib.sh'), '\nmagpie_main_pid() { [ "$TEST_RUNNING" = 1 ] && echo "$$"; }\n' +
      'magpie_rss_mb() { echo 1; }\nlan_ip() { return 1; }\n');
    fs.writeFileSync(path.join(w, 'scripts/magpie.service'), '#!/bin/sh\n[ "$1" = panel-url ] || exit 9\n' +
      'printf "%s\\n" "$TEST_PANEL"\nexit "$TEST_RC"\n');
    const conf = path.join(w, 'scripts/magpie.config');
    // The temporary path is provided via environment, never inserted as shell source.
    fs.writeFileSync(conf, 'echo fixture-config-chatter\nmagpie_path="$TEST_DATA"\nMAGPIE_ADDR="$TEST_ADDR"\nMAGPIE_WEB_ADDR="127.0.0.1:3430"\n');
    const produce = (addr, panel, rc = 0) => spawnSync('sh', ['scripts/status.sh', '--webonly'], {cwd: w, timeout: 10000,
      env: {PATH: path.join(w, 'stub') + ':/usr/bin:/bin', MAGPIE_CONF: conf, TEST_DATA: w, TEST_ADDR: addr,
        TEST_RUNNING: panel === undefined ? '0' : '1', TEST_PANEL: panel || '', TEST_RC: String(rc)}});
    const f = path.join(w, 'webroot/status.json');
    fs.writeFileSync(path.join(w, 'stub/date'), `#!/bin/sh\necho '${epoch} 22:13:20'\n`, {mode: 0o700});
    for (const [addr, bad] of [['127.0.0.1:3425', false], [login, true], ['127.0.0.1:3430', true]]) {
      const result = produce(addr); assert.equal(result.status, 0); assert.equal(result.stdout.length, 0);
      const raw = fs.readFileSync(f, 'utf8'), d = JSON.parse(raw); assert.ok(!raw.includes(fixtureKey));
      assert.equal(d.updatedEpoch, epoch); assert.equal(d.updated, '22:13:20'); assert.equal(d.running, false);
      assert.equal(!!d.configError, bad); assert.equal(!!d.apiUrl, !bad); assert.equal(d.webUrl, '');
      assert.equal(fs.statSync(f).mode & 0o777, 0o600);
      assert.equal(fs.statSync(path.join(w, 'webroot/lastlog.txt')).mode & 0o777, 0o600);
    }
    for (const [panel, rc, expected] of [[bare, 0, bare], ['http://[::1]:3430/', 0, 'http://[::1]:3430/'],
      [login, 0, ''], ['note: ' + fixtureKey + '\n' + bare, 0, ''], ['http://127.0.0.1:7777/', 0, ''], [bare, 1, '']]) {
      assert.equal(produce('127.0.0.1:3425', panel, rc).status, 0);
      const raw = fs.readFileSync(f, 'utf8'); assert.ok(!raw.includes(fixtureKey));
      assert.equal(JSON.parse(raw).webUrl, expected);
    }
    fs.writeFileSync(path.join(w, 'stub/date'), '#!/bin/sh\nexit 1\n');
    assert.equal(produce('127.0.0.1:3425').status, 0); assert.equal(JSON.parse(fs.readFileSync(f)).updatedEpoch, 0);
    const previous = fs.readFileSync(f, 'utf8');
    fs.writeFileSync(path.join(w, 'stub/chmod'), '#!/bin/sh\nexit 1\n', {mode: 0o700});
    assert.equal(produce('127.0.0.1:3430').status, 1); assert.equal(fs.readFileSync(f, 'utf8'), previous);
    assert.deepEqual(fs.readdirSync(path.join(w, 'webroot')).sort(), ['lastlog.txt', 'status.json']);
  } finally { fs.rmSync(w, {recursive: true, force: true}); }
});
