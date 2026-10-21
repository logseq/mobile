#!/usr/bin/env node
// Start the real Node sync adapter with an isolated database and local JWT issuer.
// Usage: node scripts/local-sync-fixture.cjs MASTER_CHECKOUT [PORT]
// Run run-local-sync-stress.cjs with the printed fixture path. Stop with Ctrl-C.
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const crypto = require('node:crypto');
const cp = require('node:child_process');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');

async function unusedPort() {
  const probe = net.createServer();
  await new Promise(resolve => probe.listen(0, '127.0.0.1', resolve));
  const port = probe.address().port;
  await new Promise(resolve => probe.close(resolve));
  return port;
}

async function main() {
  const master = path.resolve(process.argv[2]);
  const serverEntry = path.join(master, 'deps/db-sync/worker/dist/node-adapter.js');
  assert(fs.existsSync(serverEntry), 'Build db-sync-node in master before starting the fixture');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'logseq-mobile-sync-stress-'));
  fs.chmodSync(root, 0o700);
  const port = Number(process.argv[3] ?? await unusedPort());
  const baseUrl = `http://127.0.0.1:${port}`;
  const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const kid = 'local-mobile-sync-test';
  const jwk = { ...publicKey.export({ format: 'jwk' }), kid, alg: 'RS256', use: 'sig' };
  const issuerServer = http.createServer((_request, response) => {
    response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify({ keys: [jwk] }));
  });
  await new Promise(resolve => issuerServer.listen(0, '127.0.0.1', resolve));
  const issuer = `http://127.0.0.1:${issuerServer.address().port}`;
  const subject = crypto.randomUUID();
  const expires = Math.floor(Date.now() / 1000) + 86400;
  const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT', kid })).toString('base64url');
  const claims = Buffer.from(JSON.stringify({ sub: subject, iss: issuer, aud: 'mobile-sync-stress',
    client_id: 'mobile-sync-stress', token_use: 'id', exp: expires, email: 'stress@example.test',
    'cognito:username': 'Mobile sync test' })).toString('base64url');
  const payload = header + '.' + claims;
  const token = payload + '.' + crypto.sign('RSA-SHA256', Buffer.from(payload), privateKey).toString('base64url');
  const cliRoot = path.join(root, 'cli'); fs.mkdirSync(cliRoot);
  const authPath = path.join(cliRoot, 'auth.json');
  fs.writeFileSync(authPath, JSON.stringify({ provider: 'cognito', 'id-token': token, 'access-token': token,
    'refresh-token': 'local-disposable-refresh-token', 'expires-at': expires * 1000, sub: subject,
    email: 'stress@example.test', 'updated-at': Date.now() }), { mode: 0o600 });
  fs.writeFileSync(path.join(cliRoot, 'cli.edn'), `{:root-dir ${JSON.stringify(cliRoot)} :http-base ${JSON.stringify(baseUrl)} :ws-url ${JSON.stringify(baseUrl.replace('http:', 'ws:') + '/sync/%s')} :auth-path ${JSON.stringify(authPath)}}`);
  const fixturePath = path.join(root, 'fixture.json');
  fs.writeFileSync(fixturePath, JSON.stringify({ root, cliRoot, token, subject, baseUrl, restartSignalSupported: true }), { mode: 0o600 });
  const serverEnvironment = {
    ...process.env, DB_SYNC_PORT: String(port), DB_SYNC_BASE_URL: baseUrl, DB_SYNC_DATA_DIR: path.join(root, 'server'),
    DB_SYNC_LOG_LEVEL: 'warn', COGNITO_ISSUER: issuer, COGNITO_CLIENT_ID: 'mobile-sync-stress',
    COGNITO_JWKS_URL: issuer + '/.well-known/jwks.json', ASSET_LINK_SECRET: crypto.randomBytes(32).toString('hex'),
  };
  let child, restarting = false, stopping = false;
  const spawnServer = () => {
    const log = fs.openSync(path.join(root, 'server.log'), 'a');
    child = cp.spawn('node', [serverEntry], { cwd: path.join(master, 'deps/db-sync'),
      env: serverEnvironment, stdio: ['ignore', log, log] });
    fs.closeSync(log);
    fs.writeFileSync(path.join(root, 'server.pid'), String(child.pid));
    child.on('exit', code => {
      if (!restarting) { issuerServer.close(); process.exitCode = stopping ? 0 : code || 1; }
    });
  };
  spawnServer();
  fs.writeFileSync(path.join(root, 'manager.pid'), String(process.pid));
  const stop = () => { stopping = true; try { child.kill('SIGCONT'); child.kill(); } finally { issuerServer.close(); } };
  process.on('SIGINT', stop); process.on('SIGTERM', stop);
  process.on('SIGUSR2', async () => {
    if (restarting || stopping) return;
    restarting = true;
    const exited = new Promise(resolve => child.once('exit', resolve));
    child.kill('SIGKILL'); await exited;
    if (!stopping) spawnServer();
    restarting = false;
  });
  for (let attempt = 0; attempt < 100; attempt++) {
    if (child.exitCode !== null) throw new Error('Local server exited; inspect ' + path.join(root, 'server.log'));
    try {
      const response = await fetch(baseUrl + '/health');
      if (response.ok) { console.log('FIXTURE', fixturePath); return; }
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  stop(); throw new Error('Local server did not become ready');
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
