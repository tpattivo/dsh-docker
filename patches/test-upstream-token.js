// Behavioral smoke test for patches/upstream-token.js (no dependencies).
//
// Run:  node patches/test-upstream-token.js
//
// Stubs the upstream `dsh web` server via a mocked global fetch and drives the
// real serveIndex() through the failure sequence behind
// "dsh web authentication required; reopen the URL printed by dsh web":
//
//   phase 0: fresh dsh, token OLD  → auto bootstrap works, session works
//   phase 1: dsh restarts in-container (admin-page restart / plugin install):
//            token NEW printed to the log, all sessions voided, but the proxy
//            still caches OLD → the patched code must re-scan the log and
//            recover with NEW
//   phase 2: restart crash before the new token is flushed → stale-only tail
//            must pass the first 401 through instead of looping
//   phase 3: no token in the log at all → clean 401 passthrough
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const LOG_FILE = path.join(os.tmpdir(), `dsh-test-log-${process.pid}.txt`);
// The module reads DSH_WEB_LOG at require time.
process.env.DSH_WEB_LOG = LOG_FILE;

const MOD_PATH = require.resolve('./upstream-token.js');
let { serveIndex } = require(MOD_PATH);

// ---- mock upstream dsh ------------------------------------------------------
let currentToken = null; // token the currently running dsh process accepts
let validSessions = new Set(); // sessions the current dsh process accepts
let sessionCounter = 0;

function mintSession() {
  const sid = `sess-${++sessionCounter}`;
  validSessions.add(sid);
  return sid;
}

function mockFetch(url, init) {
  const u = new URL(String(url));
  const token = u.searchParams.get('token');
  const cookie = (init.headers && init.headers.cookie) || '';
  const m = /(?:^|;\s*)dsh_session=([^;]+)/.exec(cookie);
  const sid = m ? m[1] : null;

  const respond = (status, body, cookies) => {
    const h = new Headers();
    for (const c of cookies || []) h.append('set-cookie', c);
    return Promise.resolve(new Response(body, { status, headers: h }));
  };

  if (token) {
    if (token === currentToken) {
      return respond(303, '', [`dsh_session=${mintSession()}; HttpOnly; Path=/; SameSite=Strict`]);
    }
    return respond(401, 'auth required');
  }
  if (sid && validSessions.has(sid)) return respond(200, 'ok page');
  return respond(401, 'auth required');
}

global.fetch = (url, init) => mockFetch(url, init);

// ---- minimal req/res doubles -------------------------------------------------
function makeReq(cookieValue) {
  return {
    method: 'GET',
    url: '/',
    headers: cookieValue ? { cookie: cookieValue } : {},
  };
}

function makeRes() {
  return {
    statusCode: null,
    headers: null,
    body: null,
    writeHead(code, hdrs) { this.statusCode = code; this.headers = hdrs; return this; },
    end(b) { this.body = b == null ? '' : b; },
  };
}

const ctx = { origin: 'http://127.0.0.1:3079', transformHtml: null };

function printTokenToLog(token) {
  // Mirrors what `dsh web` prints and the manager appends to /app/.dsh-web.log.
  fs.appendFileSync(LOG_FILE, `dsh web listening on http://127.0.0.1:3079/?token=${token}\n`);
}

function sidFromSetCookie(res) {
  const sc = String((res.headers && res.headers['Set-Cookie']) || '');
  const m = /dsh_session=([^;]+)/.exec(sc);
  return m ? m[1] : null;
}

function freshModule() {
  delete require.cache[MOD_PATH];
  ({ serveIndex } = require(MOD_PATH));
}

(async () => {
  try {
    // ── Phase 0: fresh dsh, token OLD ────────────────────────────────────────
    currentToken = 'OLDTOKENaaaaaaaaaaaaaaaaaaaa';
    validSessions = new Set();
    fs.writeFileSync(LOG_FILE, '');
    printTokenToLog(currentToken);

    // 1) No cookie → proxy auto-bootstraps with the log token → 303 + session
    let res = makeRes();
    assert.ok(await serveIndex(makeReq(null), res, ctx), '1: serveIndex handled the request');
    assert.strictEqual(res.statusCode, 303, '1: token exchange returns the upstream redirect');
    const goodSid = sidFromSetCookie(res);
    assert.ok(goodSid && validSessions.has(goodSid), '1: browser received a valid session cookie');

    // 2) Browser carries the fresh session → plain 200 passthrough
    res = makeRes();
    await serveIndex(makeReq(`dsh_session=${goodSid}`), res, ctx);
    assert.strictEqual(res.statusCode, 200, '2: valid session passes through untouched');

    // ── Phase 1: in-container dsh restart (THE BUG) ──────────────────────────
    // New token printed AFTER the old line; restart voids all sessions.
    currentToken = 'NEWTOKENbbbbbbbbbbbbbbbbbbbb';
    validSessions = new Set();
    printTokenToLog(currentToken);

    // 3) Stale browser cookie + stale cached token → patch must re-scan and
    //    recover with the NEW token instead of locking the browser out.
    res = makeRes();
    assert.ok(await serveIndex(makeReq(`dsh_session=${goodSid}`), res, ctx), '3: serveIndex handled the request');
    assert.strictEqual(res.statusCode, 303, '3: recovered with the refreshed token');
    const freshSid = sidFromSetCookie(res);
    assert.ok(freshSid && validSessions.has(freshSid), '3: browser received a NEW valid session cookie');

    // ── Phase 2: restart crash before the new token reaches the log ─────────
    // Fresh proxy state; log tail holds only the stale OLD token, upstream
    // already accepts only NEW → no recovery possible → pass the 401 through.
    currentToken = 'NEWTOKENbbbbbbbbbbbbbbbbbbbb';
    validSessions = new Set();
    freshModule();
    fs.writeFileSync(LOG_FILE, '');
    printTokenToLog('OLDTOKENaaaaaaaaaaaaaaaaaaaa');

    res = makeRes();
    assert.ok(await serveIndex(makeReq('dsh_session=sess-99'), res, ctx), '4: serveIndex handled the request');
    assert.strictEqual(res.statusCode, 401, '4: unrecoverable case passes the upstream 401 through');

    // ── Phase 3: log has no token at all → clean 401 passthrough ─────────────
    freshModule();
    fs.writeFileSync(LOG_FILE, '');

    res = makeRes();
    assert.ok(await serveIndex(makeReq(null), res, ctx), '5: serveIndex handled the request');
    assert.strictEqual(res.statusCode, 401, '5: no-token case passes the upstream 401 through');

    fs.unlinkSync(LOG_FILE);
    console.log('ALL TESTS PASSED (5/5)');
  } catch (err) {
    console.error('TEST FAILED:', err && err.stack || err);
    process.exitCode = 1;
  }
})();
