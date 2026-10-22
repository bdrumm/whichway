// node --test: rider reports through the relay, against a fake GitHub and a fake KV.
import { test } from "node:test";
import assert from "node:assert/strict";
import { handleRequest } from "../src/index.js";
import { validateReport, reportPath, nyDate } from "../src/reports.js";

const NOW = Date.UTC(2026, 9, 22, 21, 0, 0); // 2026-10-22 17:00 New York
const NOW_S = NOW / 1000;
const INSTALL = "45359D5A-0878-4C73-B233-8DE8EE1DE67B";
const env0 = { GITHUB_TOKEN: "ghp_test", GITHUB_REPO: "bdrumm/whichway-data", APP_KEY: "k-secret", REPORT_SALT: "salt" };

function fakeGitHub() {
  const files = {};
  const fetch = async (url, init = {}) => {
    const path = decodeURIComponent(url.split("/contents/")[1]);
    if (!init.method || init.method === "GET") {
      if (!(path in files)) return new Response("{}", { status: 404 });
      return new Response(JSON.stringify({ sha: "sha-" + path, content: files[path] }), { status: 200 });
    }
    const existed = path in files;
    files[path] = JSON.parse(init.body).content;
    return new Response("{}", { status: existed ? 200 : 201 });
  };
  return { files, fetch, json: (p) => JSON.parse(Buffer.from(files[p], "base64").toString()) };
}

function fakeKV() {
  const m = new Map();
  return { m, get: async (k, type) => (m.has(k) ? (type === "json" ? JSON.parse(m.get(k)) : m.get(k)) : null), put: async (k, v) => void m.set(k, v) };
}

function report(over = {}) {
  return { id: "R-7f3c2a10-held", ts: NOW_S - 30, kind: "held", route: "A", dir: "S", stop: "A41", trip: "112450_A..S", source: "trip", confidence: 0.86, ...over };
}

function post(body, install = INSTALL) {
  const text = JSON.stringify(body);
  return new Request("https://relay.test/v1/reports", { method: "POST", body: text,
    headers: { "content-type": "application/json", "content-length": String(text.length), "x-whichway-key": "k-secret", "x-whichway-install": install } });
}

test("a report is checked for its kind, place and time", () => {
  assert.equal(validateReport(report(), NOW_S, 2), null);
  assert.equal(validateReport(report({ kind: "aliens" }), NOW_S, 2), "kind unknown");
  assert.equal(validateReport(report({ kind: "crowded", sub: "packed" }), NOW_S, 2), null);
  assert.equal(validateReport(report({ kind: "held", sub: "packed" }), NOW_S, 2), "sub unknown");
  assert.equal(validateReport(report({ stop: "../x" }), NOW_S, 2), "stop missing");
  assert.equal(validateReport(report({ route: "a train" }), NOW_S, 2), "route missing");
  assert.equal(validateReport(report({ dir: "E" }), NOW_S, 2), "dir malformed");
  assert.equal(validateReport(report({ ts: NOW_S - 3 * 86400 }), NOW_S, 2), "ts out of range");
  assert.equal(validateReport(report({ confidence: 2 }), NOW_S, 2), "confidence malformed");
  assert.equal(validateReport(report({ route: "6X", stop: "631N", trip: undefined, dir: undefined }), NOW_S, 2), null);
});

test("reports are archived by the New York date", () => {
  assert.equal(nyDate(NOW_S), "2026-10-22");
  assert.equal(reportPath(NOW_S, "R-1"), `reports/2026/10/22/${NOW_S}-R-1.json`);
  assert.equal(reportPath(Date.UTC(2026, 9, 23, 3, 30) / 1000, "R-1").slice(0, 19), "reports/2026/10/22/"); // 23:30 New York
});

test("a report is archived with a reporter hash, listed publicly without it, and a repeat is dropped", async () => {
  const gh = fakeGitHub(), kv = fakeKV();
  const env = { ...env0, REPORTS: kv };
  const deps = { fetch: gh.fetch, now: () => NOW };
  let r = await handleRequest(post(report()), env, deps);
  assert.equal(r.status, 201);
  const out = await r.json();
  assert.equal(out.live, "added");
  const archived = gh.json(out.path);
  assert.match(archived.reporter, /^[0-9a-f]{16}$/);
  assert.match(archived.rider, /^[0-9a-f]{12}$/);
  assert.ok(!JSON.stringify(archived).includes(INSTALL), "the install id never leaves the relay");

  // the same rider, kind and stop a minute later is a repeat
  r = await handleRequest(post(report({ id: "R-second-held", ts: NOW_S })), env, deps);
  assert.equal(r.status, 200);
  assert.equal((await r.json()).status, "repeat");
  // another rider at the same stop counts
  r = await handleRequest(post(report({ id: "R-other-rider" }), "11111111-2222-3333-4444-555555555555"), env, deps);
  assert.equal(r.status, 201);

  r = await handleRequest(new Request("https://relay.test/v1/reports?since=" + (NOW_S - 600)), env, deps);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("access-control-allow-origin"), "*");
  const list = await r.json();
  assert.equal(list.reports.length, 2);
  assert.notEqual(list.reports[0].rider, list.reports[1].rider);
  for (const rep of list.reports) assert.equal(rep.reporter, undefined, "no stable reporter id in public");
  assert.equal(list.ttl.held, 1200);
});

test("the public rider hash changes with the day, the archived reporter hash does not", async () => {
  const gh = fakeGitHub(), kv = fakeKV();
  const env = { ...env0, REPORTS: kv };
  const a = await (await handleRequest(post(report()), env, { fetch: gh.fetch, now: () => NOW })).json();
  const later = NOW + 86400 * 1000;
  const b = await (await handleRequest(post(report({ id: "R-next-day-held", ts: later / 1000 - 30 })), env, { fetch: gh.fetch, now: () => later })).json();
  const ra = gh.json(a.path), rb = gh.json(b.path);
  assert.equal(ra.reporter, rb.reporter);
  assert.notEqual(ra.rider, rb.rider);
});

test("without KV the report is still archived and the list is empty", async () => {
  const gh = fakeGitHub();
  const r = await handleRequest(post(report()), env0, { fetch: gh.fetch, now: () => NOW });
  assert.equal(r.status, 201);
  assert.equal((await r.json()).live, "no-store");
  const g = await handleRequest(new Request("https://relay.test/v1/reports"), env0, { now: () => NOW });
  assert.deepEqual((await g.json()).reports, []);
});

test("reports need the app key, and a bad report never reaches GitHub", async () => {
  const gh = fakeGitHub();
  const deps = { fetch: gh.fetch, now: () => NOW };
  const bad = new Request("https://relay.test/v1/reports", { method: "POST", body: "{}", headers: { "x-whichway-key": "nope", "x-whichway-install": INSTALL } });
  assert.equal((await handleRequest(bad, env0, deps)).status, 401);
  assert.equal((await handleRequest(post(report({ kind: "x" })), env0, deps)).status, 400);
  assert.deepEqual(gh.files, {});
  const pre = await handleRequest(new Request("https://relay.test/v1/reports", { method: "OPTIONS" }), env0, deps);
  assert.equal(pre.status, 204);
});

test("a phone reporting too fast is told to wait", async () => {
  const gh = fakeGitHub();
  const env = { ...env0, RATE_REPORT: { limit: async () => ({ success: false }) } };
  assert.equal((await handleRequest(post(report()), env, { fetch: gh.fetch, now: () => NOW })).status, 429);
});
