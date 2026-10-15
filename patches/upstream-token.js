// =============================================================================
// upstream-token.js — patched for ghcr.io/tpattivo/dsh-docker
// =============================================================================
// Overrides /app/proxy/upstream-token.js from the base image
// (ghcr.io/smanx/deepseek-harness:admin-latest, repo smanx/deepseek-harness-docker).
//
// PATCH (2026-10): on a root-path 401, the upstream version scans the DSH log
// for a launch token exactly once (state.done) and caches it forever. After the
// `dsh` process restarts inside the container (admin-page restart, plugin
// install, crash respawn), the cached token is stale, the automatic token
// exchange keeps returning 401, and the browser is locked out with
// "dsh web authentication required; reopen the URL printed by dsh web".
//
// This patch: when the cached token is rejected with 401, force a fresh scan of
// the log tail (the log is append-only across in-container restarts and the
// newest token is the last match) and retry once more before giving up. Also
// forces a scan when no token was ever captured.
//
// When bumping the base image tag, diff this file against the new upstream
// proxy/upstream-token.js and re-apply the patch if upstream changed.
// =============================================================================
//
// Upstream auto-auth (forward-compatible with official DSH 0.1.2+ launch tokens).
//
// Design goal: the token is fully handled by this image so that LAN users who
// pass Basic Auth never need any extra action. Key point: never inject the
// token on every forwarded request — the official model is "launch token
// exchanged once for a browser session cookie"; carrying the token on every
// request would make the upstream mint a brand-new identity per request.
const fs = require('fs');

const LOG_FILE = process.env.DSH_WEB_LOG || '/app/.dsh-web.log';
const TOKEN_FILE_AUTO = process.env.DSH_TOKEN_FILE_AUTO || '/app/.dsh-launch-token';
// Official DSH 0.1.2+ passes the launch token via "?token=" on the home URL in
// exchange for a session cookie; the token is not accepted in request headers,
// so it is appended to the query string here.
const TOKEN_QUERY_KEY = process.env.DSH_TOKEN_QUERY_KEY || 'token';

const HARD_TOKEN = process.env.DSH_TOKEN || '';
const HARD_TOKEN_FILE = process.env.DSH_TOKEN_FILE || '';

let PATTERN = null;
if (process.env.DSH_LAUNCH_TOKEN_PATTERN) {
  try { PATTERN = new RegExp(process.env.DSH_LAUNCH_TOKEN_PATTERN); } catch {}
}
const DEFAULT_TOKEN_RE = /(?:[?&,]|^)token[=:]\s*["']?([A-Za-z0-9._~-]{16,})/i;

let state = { token: '', source: null, scanning: false, attempts: 0, done: false };
const SCAN_INTERVAL = 2000;
const MAX_SCAN_ATTEMPTS = 30;

function readTail(p, maxBytes) {
  try {
    const st = fs.statSync(p);
    if (!st.size) return '';
    const start = Math.max(0, st.size - maxBytes);
    const fd = fs.openSync(p, 'r');
    const buf = Buffer.alloc(st.size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    fs.closeSync(fd);
    return buf.toString('utf8');
  } catch {
    return '';
  }
}

// Returns the LAST regex match in the text (the log may hold tokens printed by
// several past starts; the newest print is the furthest down, so the last match
// is the current token). Returns null when there is no match.
function lastMatch(text, regex) {
  let re;
  try {
    re = new RegExp(regex.source, regex.flags.includes('g') ? regex.flags : regex.flags + 'g');
  } catch {
    return null;
  }
  let last = null;
  let m;
  while ((m = re.exec(text)) !== null) {
    last = m;
    if (m[0] === '') re.lastIndex += 1;
  }
  return last;
}

// Token masking for logs: keep the first/last 4 chars, pad the middle with '*'.
function maskToken(t) {
  const s = String(t || '');
  if (s.length <= 8) return s ? s.slice(0, 1) + '****' : '(empty)';
  return s.slice(0, 4) + '****' + s.slice(-4);
}

// Extract the newest (last) launch token from log text.
function extractFromText(text) {
  if (PATTERN) {
    const m = lastMatch(text, PATTERN);
    if (m) return (m[1] !== undefined ? m[1] : m[0]).trim();
  }
  const m = lastMatch(text, DEFAULT_TOKEN_RE);
  return m ? m[1] : null;
}

// One salvage pass: read the tail of the DSH log, extract the token, and on a
// hit persist it to TOKEN_FILE_AUTO and record it as the current token.
function scanOnce() {
  const token = extractFromText(readTail(LOG_FILE, 512 * 1024));
  if (token) {
    const t = token.trim();
    try { fs.writeFileSync(TOKEN_FILE_AUTO, t); } catch {}
    state.token = t;
    state.source = 'auto';
    state.done = true;
    console.log(`[upstream-token] captured DSH launch token (length ${t.length}) from the log; it is only used to exchange a session on root-path 401`);
    return t;
  }
  return null;
}

function readHardToken() {
  if (HARD_TOKEN) return HARD_TOKEN;
  if (HARD_TOKEN_FILE) {
    try { return fs.readFileSync(HARD_TOKEN_FILE, 'utf8').trim(); } catch {}
  }
  return '';
}

// Make sure we have a token: manual first, then auto-salvage (with periodic
// polling while dsh is still printing its startup output).
function ensureToken() {
  if (state.done && state.token) return state.token;
  const hard = readHardToken();
  if (hard) {
    state.token = hard;
    state.source = 'manual';
    state.done = true;
    return hard;
  }
  const fromLog = scanOnce();
  if (fromLog) return fromLog;
  if (state.scanning) return state.token;
  if (state.attempts >= MAX_SCAN_ATTEMPTS) {
    state.done = true;
    return '';
  }
  state.scanning = true;
  const timer = setInterval(() => {
    const t = scanOnce();
    state.attempts += 1;
    if (t || state.attempts >= MAX_SCAN_ATTEMPTS) {
      clearInterval(timer);
      state.scanning = false;
      state.done = true;
    }
  }, SCAN_INTERVAL);
  timer.unref();
  return state.token;
}

// PATCH: force a fresh scan of the log tail, ignoring any cached token. Called
// when the cached token was rejected with 401 (stale after an in-container dsh
// restart) or when no token was ever captured.
function refreshToken() {
  return scanOnce() || '';
}

// Version probe: for diagnostics; normally not needed.
const VERSION_PATHS = [
  process.env.DSH_VERSION,
  '/usr/local/lib/node_modules/@deepseek-ai/dsh/package.json',
  '/opt/dsh/lib/node_modules/@deepseek-ai/dsh/package.json',
];
function detectDshVersion() {
  for (const p of VERSION_PATHS) {
    if (!p) continue;
    if (String(p).includes('package.json')) {
      try { return JSON.parse(fs.readFileSync(p, 'utf8')).version || null; } catch {}
    } else {
      return p;
    }
  }
  return null;
}

// ── Root-path auth bootstrap (401 → retry with token → pass set-cookie through) ──
const FORWARD_HEADERS = [
  'accept', 'accept-language', 'user-agent', 'cookie', 'referer',
  'sec-fetch-dest', 'sec-fetch-mode', 'sec-fetch-site',
  'sec-ch-ua', 'sec-ch-ua-mobile', 'sec-ch-ua-platform',
];
function pickIndexHeaders(req, dropCookie) {
  const src = req.headers || {};
  const out = { accept: '*/*', 'accept-encoding': 'identity' };
  for (let i = 0; i < FORWARD_HEADERS.length; i++) {
    const n = FORWARD_HEADERS[i];
    // The token exchange mints a brand-new session; if the browser's old cookie
    // (expired/invalid session) is forwarded, upstream may 401 the retry
    // itself. So the retry strips the cookie.
    if (dropCookie && n === 'cookie') continue;
    if (src[n]) out[n] = src[n];
  }
  return out;
}

async function fetchRaw(origin, headers, path) {
  const url = path && path !== '/' ? origin + path : origin + '/';
  const res = await fetch(url, { method: 'GET', headers, redirect: 'manual' });
  const getSetCache = res.headers.getSetCookie ? res.headers.getSetCookie() : [];
  return {
    status: res.status,
    headers: res.headers,
    setCookies: Array.isArray(getSetCache) ? getSetCache : [],
    body: await res.text(),
  };
}

// Inject a snippet into HTML right after the first <head> (or at the very start).
function injectIntoHead(content, snippet) {
  const i = content.toLowerCase().indexOf('<head');
  if (i !== -1) {
    const e = content.indexOf('>', i);
    return e !== -1 ? content.slice(0, e + 1) + snippet + content.slice(e + 1) : snippet + content;
  }
  return snippet + content;
}

// Pass an upstream response through to the browser unchanged (keeping
// set-cookie so the browser can establish its session; HTML gets the injection
// rewrite).
function sendRaw(r, res, transformHtml) {
  const hs = {};
  for (const [k, v] of r.headers) {
    const lk = k.toLowerCase();
    if (['content-length', 'content-encoding', 'connection', 'transfer-encoding', 'keep-alive', 'upgrade', 'set-cookie'].includes(lk)) continue;
    hs[k] = v;
  }
  hs['Cache-Control'] = hs['Cache-Control'] || 'no-store';
  if (r.setCookies.length) hs['Set-Cookie'] = r.setCookies;

  let body = r.body;
  const ct = String(r.headers.get ? r.headers.get('content-type') : '').toLowerCase();
  if (ct.includes('text/html') && transformHtml) body = transformHtml(body);
  // 3xx/empty-body responses (e.g. a 303 redirect) get no Content-Type, so the
  // browser is not misled into treating them as HTML.
  if (body && body.length) {
    hs['Content-Type'] = ct || 'text/html; charset=utf-8';
  }

  res.writeHead(r.status, hs);
  res.end(body);
  return true;
}

// PATCH: one launch-token exchange attempt against the current path.
// Returns the upstream response object, or null on network failure.
async function attemptTokenExchange(origin, req, reqUrl, token) {
  console.log(`[upstream-token] retrying with launch token (${maskToken(token)}) to exchange it for a session cookie`);
  const sep = reqUrl.includes('?') ? '&' : '?';
  const authUrl = `${reqUrl}${sep}${TOKEN_QUERY_KEY}=${encodeURIComponent(token)}`;
  try {
    return await fetchRaw(origin, pickIndexHeaders(req, true), authUrl);
  } catch {
    return null;
  }
}

function logExchangeOutcome(attempt, token, tag) {
  if (!attempt) {
    console.log(`[upstream-token] ${tag}-token exchange failed (network error or unresponsive upstream)`);
    return;
  }
  const sc = attempt.setCookies.length;
  if (attempt.status === 401) {
    console.log(`[upstream-token] ${tag}-token auto-login failed: still 401 with launch token (${maskToken(token)}); token likely expired/invalidated, already consumed, or this upstream version does not accept query tokens`);
  } else if (attempt.status >= 300 && attempt.status < 400) {
    const loc = String(attempt.headers.get ? attempt.headers.get('location') : attempt.headers.location || '');
    console.log(`[upstream-token] ${tag}-token auto-login succeeded: upstream ${attempt.status} redirect to "${loc || '/'}" with ${sc} session cookie(s), passed through for the browser to follow`);
  } else {
    console.log(`[upstream-token] ${tag}-token exchange returned ${attempt.status} with ${sc} session cookie(s), passing through`);
  }
}

// Root-path GET handler: forward normally; on upstream 401, retry once carrying
// the launch token and pass the returned set-cookie through, after which the
// browser carries the cookie automatically.
// PATCH: if that retry is still 401 (stale cached token after an in-container
// dsh restart), force a fresh scan of the DSH log and retry once more with the
// newest token before giving up.
// Returns true when the response was handled; false means fall back to plain
// proxying.
async function serveIndex(req, res, ctx) {
  const origin = ctx.origin;
  const transformHtml = ctx.transformHtml;
  const reqUrl = req.url || '/';
  let first;
  try {
    first = await fetchRaw(origin, pickIndexHeaders(req), reqUrl);
  } catch {
    return false;
  }
  if (first.status !== 401) {
    if (first.status !== 200) {
      console.log(`[upstream-token] root path returned ${first.status} (not 401), passing through unchanged`);
    }
    return sendRaw(first, res, transformHtml);
  }

  let token = ensureToken();
  if (!token) {
    console.log('[upstream-token] no launch token captured yet, forcing a fresh scan of the DSH log');
    token = refreshToken();
  }
  if (!token) {
    console.log('[upstream-token] no launch token available, skipping retry, passing the first 401 through');
    return sendRaw(first, res, transformHtml);
  }

  // 1st attempt: cached (or manual) token.
  let attempt = await attemptTokenExchange(origin, req, reqUrl, token);
  if (!attempt) {
    console.log('[upstream-token] token retry failed (network error or unresponsive upstream), passing the first 401 through');
    return sendRaw(first, res, transformHtml);
  }
  if (attempt.status !== 401) {
    logExchangeOutcome(attempt, token, 'cached');
    return sendRaw(attempt, res, transformHtml);
  }

  // PATCH: cached token rejected — dsh likely restarted inside the container
  // and printed a new token. Re-scan the log and retry once with the fresh one.
  console.log('[upstream-token] cached token rejected (401); re-scanning the DSH log for a fresh launch token');
  const fresh = refreshToken();
  if (fresh && fresh !== token) {
    attempt = await attemptTokenExchange(origin, req, reqUrl, fresh);
    if (attempt) {
      logExchangeOutcome(attempt, fresh, 'refreshed');
      return sendRaw(attempt, res, transformHtml);
    }
    console.log('[upstream-token] refreshed-token retry failed (network error), passing the first 401 through');
  } else if (fresh === token) {
    console.log('[upstream-token] log tail still holds the same (stale) token; passing the first 401 through');
  } else {
    console.log('[upstream-token] no fresh token found in the DSH log; passing the first 401 through');
  }
  return sendRaw(first, res, transformHtml);
}

module.exports = { serveIndex, ensureToken, refreshToken, injectIntoHead, detectDshVersion };
