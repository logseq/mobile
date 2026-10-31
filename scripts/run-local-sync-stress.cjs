#!/usr/bin/env node
// Run against an authenticated, disposable local fixture; never a personal graph.
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const readline = require('node:readline');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { promisify } = require('node:util');
const execFile = promisify(cp.execFile);
const fixture = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const seed = Number(process.argv[3] ?? 20261022);
const count = Number(process.argv[4] ?? 160);
const master = process.argv[5];
assert(master, 'Pass the master checkout used to build the CLI and local sync server');
assert(['127.0.0.1', 'localhost'].includes(new URL(fixture.baseUrl).hostname));
assert(path.resolve(fixture.cliRoot).startsWith(path.resolve(fixture.root) + path.sep));
assert(path.basename(fixture.root).startsWith('logseq-mobile-sync-stress-'));
const WebSocket = require(path.join(master, 'node_modules/ws'));
const cliPath = path.join(master, 'cli/_build/default/dist/logseq-cli.js');
const binary = path.resolve(__dirname, '../_build/default/shared/native/logseq_sync_client.exe');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let randomState = seed >>> 0;
const random = () => { randomState ^= randomState << 13; randomState ^= randomState >>> 17; randomState ^= randomState << 5; return (randomState >>> 0) / 4294967296; };
const pick = values => values[Math.floor(random() * values.length)];
const uuid = () => {
  const bytes = Buffer.alloc(16);
  for (let i = 0; i < 16; i++) bytes[i] = Math.floor(random() * 256);
  bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
};
const runRoot = path.join(fixture.root, `run-${seed}-${Date.now()}`);
fs.mkdirSync(runRoot);
const fixtureCliRoot = fixture.cliRoot;
fixture.cliRoot = path.join(runRoot, 'cli');
fs.mkdirSync(fixture.cliRoot);
for (const file of ['auth.json', 'cli.edn']) {
  const content = fs.readFileSync(path.join(fixtureCliRoot, file), 'utf8').replaceAll(fixtureCliRoot, fixture.cliRoot);
  fs.writeFileSync(path.join(fixture.cliRoot, file), content, { mode: 0o600 });
}
const tracePath = path.join(runRoot, `operations-${seed}.jsonl`);
const trace = event => fs.appendFileSync(tracePath, JSON.stringify(event) + '\n');
const coverage = {}, scenarios = [], assets = [];
const batchSizes = [], messageBytes = [];
const movements = { indent: 0, outdent: 0, up: 0, down: 0 };
let serverPaused = false;
const mobileIDs = new Set(), pageIDs = new Set(), tagIDs = new Set();
const baseTime = Date.now();
let sequence = 0;

class Client {
  constructor(root) {
    this.root = root;
    this.pending = [];
    this.process = cp.spawn(binary, [], { stdio: ['pipe', 'pipe', 'pipe'] });
    const log = fs.createWriteStream(path.join(fixture.root, `mobile-${path.basename(root)}.log`), { flags: 'a' });
    this.process.stderr.pipe(log);
    readline.createInterface({ input: this.process.stdout }).on('line', line => {
      const next = this.pending.shift();
      if (!next) throw new Error('Unexpected mobile client output');
      clearTimeout(next.timer);
      try {
        const value = JSON.parse(line);
        if (!value.ok) throw new Error(value.error);
        next.resolve(value.result);
      } catch (error) { next.reject(error); }
    });
    this.process.on('exit', code => {
      for (const waiter of this.pending.splice(0)) { clearTimeout(waiter.timer); waiter.reject(new Error(`Mobile client exited: ${code}`)); }
    });
  }
  call(command) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Mobile command timed out: ${command.command}`)), 30000);
      this.pending.push({ resolve, reject, timer });
      this.process.stdin.write(JSON.stringify(command) + '\n');
    });
  }
  async open() {
    const result = await this.call({ ...fixture, command: 'open', root: this.root });
    assert(result.ok, JSON.stringify(result.error));
  }
  async rpc(action, payload = {}) {
    const result = await this.call({ command: 'dispatch', action, payload });
    assert(result.ok, `${action}: ${JSON.stringify(result.error)}`);
    return result.result;
  }
  inspect() { return this.call({ command: 'inspect' }); }
  async crash() {
    const exited = new Promise(resolve => this.process.once('exit', resolve));
    this.process.kill('SIGKILL'); await exited;
  }
  async close() { await this.call({ command: 'close' }); this.process.stdin.end(); }
}

class Mobile extends Client {
  constructor(root) { super(root); this.transportTail = Promise.resolve(); this.generation = 0; this.online = false; this.batchSizes = batchSizes; this.messageBytes = messageBytes; }
  queueTransport(run) {
    this.transportTail = this.transportTail.then(run).catch(error => { this.failure = error; });
  }
  async event(type, fields = {}) {
    const result = await this.rpc('syncTransportEvent', { type, graphId: fixture.graphId, generation: this.generation, ...fields });
    await this.commands(result.syncTransport);
  }
  async commands(transport) {
    if (!transport) return;
    this.generation = transport.generation;
    for (const command of transport.commands) {
      if (command.type === 'connect' && this.online) {
        const socket = new WebSocket(command.url, { headers: { Authorization: `Bearer ${fixture.token}` } });
        this.socket = socket;
        socket.on('open', () => this.queueTransport(() => this.event('opened')));
        socket.on('message', body => this.queueTransport(async () => {
          const frame = JSON.parse(body.toString());
          if (this.upload && this.dropAcknowledgement && frame.type === 'tx/batch/ok') {
            this.upload.resolve({ status: 200, body: body.toString(), ok: true });
            return;
          }
          await this.event('frame', { body: body.toString() });
        }));
        socket.on('error', error => { if (this.online) this.queueTransport(() => this.event('failed', { message: error.message })); });
        socket.on('close', () => {
          if (this.upload?.socket === socket) this.upload.reject(new Error('Upload socket closed'));
          if (this.online && this.socket === socket) this.queueTransport(() => this.event('closed'));
        });
      } else if (command.type === 'send' && this.socket?.readyState === WebSocket.OPEN) this.socket.send(command.body);
      else if (command.type === 'close') { this.socket?.terminate(); this.socket = null; }
      else if (command.type === 'snapshot') throw new Error('Unexpected snapshot reset during local randomized sync');
      else if (command.type === 'pending-result' && this.upload?.id === command.id)
        this.upload.resolve({ status: 200, body: command.body, ok: true });
      // Retries are driven explicitly by reconnect(), so every attempt is recorded.
    }
  }
  async reconnect() { this.online = true; await this.commands((await this.rpc('beginSyncTransport')).syncTransport); await sleep(60); await this.transportTail; }
  async offline() {
    this.online = false;
    await this.event('network', { available: false });
    this.socket?.terminate(); this.socket = null;
    await this.transportTail;
  }
  async flush({ loseReply = false, crashAfterAccept = false } = {}) {
    assert(this.online, 'Cannot flush an offline client');
    for (let attempt = 0; attempt < 600; attempt++) {
      await this.transportTail;
      if (this.failure) throw this.failure;
      const snapshot = await this.rpc('beginPendingSync');
      const request = snapshot.pendingSyncRequest;
      if (!request) {
        const state = await this.inspect();
        const conflicts = state.pending.filter(op => op.state.startsWith('conflicted'));
        assert.equal(conflicts.length, 0, JSON.stringify(conflicts));
        if (state.pending.length === 0) return state;
        if (attempt % 10 === 9) await this.reconnect();
        await sleep(30); continue;
      }
      if (request.delayMs) await sleep(request.delayMs);
      let response, body;
      if (request.method === 'WS') {
        const transactions = JSON.parse(request.body).txs.length;
        const bytes = Buffer.byteLength(request.body, 'utf8');
        assert(transactions >= 1 && transactions <= 50, 'A sync batch must contain at most 50 transactions');
        assert(bytes <= 1_000_000, 'A WebSocket sync message must fit the 1 MB encoded byte budget');
        this.batchSizes.push(transactions); this.messageBytes.push(bytes);
        this.dropAcknowledgement = loseReply || crashAfterAccept;
        try {
          response = await new Promise((resolve, reject) => {
            assert.equal(this.socket?.readyState, WebSocket.OPEN, 'A graph upload needs its live subscription');
            const timer = setTimeout(() => reject(new Error('Upload response timed out')), 10_000);
            this.upload = { id: request.id, socket: this.socket,
              resolve: value => { clearTimeout(timer); resolve(value); },
              reject: error => { clearTimeout(timer); reject(error); } };
            this.socket.send(request.body);
          });
          body = response.body;
        } finally { this.upload = null; this.dropAcknowledgement = false; }
      } else {
        response = await fetch(request.url, { method: request.method,
          headers: { ...request.headers, Authorization: `Bearer ${request.token}`, 'Content-Type': request.contentType }, body: request.filePath ? fs.readFileSync(request.filePath) : request.body });
        body = await response.text();
      }
      trace({ event: request.method === 'WS' ? 'websocket' : 'http', status: response.status, requestId: request.id, response: body });
      let completion;
      if (crashAfterAccept && response.ok && JSON.parse(body).type === 'tx/batch/ok') {
        this.online = false; this.socket?.terminate(); this.socket = null;
        scenarios.push('mobile crash after server acceptance before acknowledgement');
        await this.crash(); return { crashed: true };
      }
      if (loseReply && response.ok && JSON.parse(body).type === 'tx/batch/ok') {
        loseReply = false; scenarios.push('server accepted but WebSocket acknowledgement was lost');
        completion = { id: request.id, status: 503, body: 'Injected lost response', error: null };
      } else completion = { id: request.id, status: response.status, body, error: null };
      await this.rpc('completePendingSync', completion);
      await sleep(1);
    }
    throw new Error('Mobile queue did not drain');
  }
}

function entities(state) {
  const values = new Map();
  for (const [id, attr, value] of state.datoms) {
    if (!values.has(id)) values.set(id, { uuid: id });
    const row = values.get(id);
    if (!row[attr]) row[attr] = [];
    row[attr].push(value);
  }
  return values;
}
const one = (row, key) => row?.[key]?.[0];
const ref = value => value && typeof value === 'object' ? value.ref : null;
const semantic = value => value == null ? null : ref(value) ? { type: 'ref-uuid', value: value.ref }
  : { type: typeof value === 'number' ? 'instant' : typeof value, value };

async function cli(args, graph = fixture.name) {
  const { stdout } = await execFile('node', [cliPath, '--root-dir', fixture.cliRoot, '--graph', graph, '--output', 'json', ...args],
    { cwd: master, env: { ...process.env, CLI_E2E_TEST: '1' }, maxBuffer: 16 * 1024 * 1024 })
    .catch(error => { throw new Error(`CLI ${args[0]} failed: ${error.stdout || error.stderr || error.message}`); });
  const result = JSON.parse(stdout.trim());
  assert.equal(result.status, 'ok', JSON.stringify(result));
  return result.data;
}

let mobile, verifier, cliStopped = false;
async function stage(intent) {
  const operationId = uuid();
  trace({ event: 'operation', sequence: sequence++, operationId, intent });
  const state = await mobile.call({ command: 'stage', operationId, intent });
  coverage[intent.type] = (coverage[intent.type] ?? 0) + 1;
  return state;
}
async function order(rows, parent) {
  const siblings = [...rows.values()].filter(row => ref(one(row, 'block/parent')) === parent);
  const left = siblings.map(row => one(row, 'block/order')).filter(Boolean).sort().at(-1) ?? null;
  return mobile.call({ command: 'order', left, right: null });
}
async function insert(page, title = `Mobile ${sequence} 中文 😀 [docs](https://example.test/${sequence})`) {
  const rows = entities(await mobile.inspect());
  const id = uuid(); mobileIDs.add(id);
  await stage({ type: 'insert-block', uuid: id, title, pageUuid: page, parentUuid: page,
    order: await order(rows, page), createdAt: baseTime + sequence });
  return id;
}
async function createPage(title) {
  const id = uuid(); pageIDs.add(id);
  await stage({ type: 'create-page', uuid: id, title, createdAt: baseTime + sequence });
  return id;
}
async function operation(type, page) {
  let rows = entities(await mobile.inspect());
  let nodes = [...rows.values()].filter(row => mobileIDs.has(row.uuid) && row['block/parent'] && ref(one(row, 'block/page')) === page && !row['logseq.property/deleted-at'] && !row['logseq.property.asset/type']);
  if (!nodes.length) { await insert(page); rows = entities(await mobile.inspect()); nodes = [...rows.values()].filter(row => mobileIDs.has(row.uuid) && row['block/parent']); }
  const row = pick(nodes), id = row.uuid, title = one(row, 'block/title');
  if (type === 'save-title') await stage({ type, uuid: id, expectedTitle: title, title: pick(['', `Edited ${sequence} 中文 😀`, `[[${page}]] #topic`, 'Line one\nLine two']) });
  else if (type === 'insert-block') await insert(page);
  else if (type === 'create-page') await createPage(`Random page ${seed} ${sequence} 中文`);
  else if (type === 'create-tag') { const tag = uuid(); tagIDs.add(tag); await stage({ type, uuid: tag, title: `Tag ${seed} ${sequence}`, createdAt: baseTime + sequence }); }
  else if (type === 'create-journal') {
    const date = new Date(Date.UTC(2027, 0, sequence));
    await stage({ type, pageUuid: uuid(), blockUuid: uuid(), title: date.toISOString().slice(0, 10),
      journalDay: Number(date.toISOString().slice(0, 10).replaceAll('-', '')), createdAt: baseTime + sequence });
  } else if (type === 'add-tag') {
    if (!tagIDs.size) await operation('create-tag', page);
    await stage({ type, uuid: id, tagUuid: pick([...tagIDs]) });
  } else if (type === 'set-property' || type === 'set-properties') {
    const status = pick(['todo', 'doing', 'done', 'canceled']);
    const change = { attr: 'logseq.property/status', expected: semantic(one(row, 'logseq.property/status')),
      value: { type: 'ref-ident', value: `logseq.property/status.${status}` } };
    if (type === 'set-property') await stage({ type, uuid: id, ...change });
    else await stage({ type, uuid: id, changes: [change, { attr: 'logseq.property/priority', expected: semantic(one(row, 'logseq.property/priority')),
      value: { type: 'ref-ident', value: 'logseq.property/priority.high' } }] });
  } else if (type === 'move-block' || type === 'move-blocks') {
    const leaves = nodes.filter(node => ![...rows.values()].some(child => ref(one(child, 'block/parent')) === node.uuid));
    if (!leaves.length) return operation('insert-block', page);
    const chosen = type === 'move-blocks' ? leaves.slice(0, 2) : [pick(leaves)];
    const parent = pick([page, ...nodes.filter(node => !chosen.some(selected => selected.uuid === node.uuid)).map(node => node.uuid)]);
    const siblings = [...rows.values()].filter(node => ref(one(node, 'block/parent')) === parent && !chosen.some(selected => selected.uuid === node.uuid))
      .map(node => one(node, 'block/order')).filter(Boolean).sort();
    const index = Math.floor(random() * (siblings.length + 1));
    const right = siblings[index] ?? null;
    let previous = siblings[index - 1] ?? null;
    const moves = [];
    for (const node of chosen) {
      const next = await mobile.call({ command: 'order', left: previous, right });
      moves.push({ uuid: node.uuid, pageUuid: page, parentUuid: parent, order: next });
      if (ref(one(node, 'block/parent')) !== parent) movements[parent === page ? 'outdent' : 'indent']++;
      else if (next !== one(node, 'block/order')) movements[next < one(node, 'block/order') ? 'up' : 'down']++;
      previous = next;
    }
    await stage(type === 'move-block' ? { type, ...moves[0] } : { type, moves });
  } else if (type === 'split-block') {
    const newId = uuid(); mobileIDs.add(newId);
    const characters = Array.from(title), split = Math.floor(characters.length / 2);
    const siblings = [...rows.values()].filter(node => ref(one(node, 'block/parent')) === ref(one(row, 'block/parent')))
      .map(node => one(node, 'block/order')).filter(Boolean).sort();
    const ownOrder = one(row, 'block/order'), next = siblings.find(order => order > ownOrder) ?? null;
    await stage({ type, uuid: id, expectedTitle: title, before: characters.slice(0, split).join(''), after: characters.slice(split).join(''),
      newUuid: newId, newOrder: await mobile.call({ command: 'order', left: ownOrder, right: next }), createdAt: baseTime + sequence });
  } else if (type === 'merge-backward') {
    const previous = await insert(page, `Previous ${sequence}`), current = await insert(page, `Merge ${sequence}`);
    rows = entities(await mobile.inspect());
    const currentTitle = one(rows.get(current), 'block/title'), previousTitle = one(rows.get(previous), 'block/title');
    await stage({ type, uuid: current, expectedTitle: currentTitle, title: currentTitle, previousUuid: previous,
      expectedPreviousTitle: previousTitle, mergedTitle: previousTitle + currentTitle });
  } else if (type === 'delete-blocks') await stage({ type, uuids: [id] });
  else if (type === 'delete-page') {
    const disposable = await createPage(`Recycle ${seed} ${sequence}`);
    await insert(disposable, 'A child must follow its page to recycle');
    await stage({ type, pageUuid: disposable, order: await order(rows, '00000004-7238-1304-3000-000000000000'), deletedAt: baseTime + sequence });
  } else if (type === 'set-favorite') {
    const target = pick([id, page]);
    const existing = [...rows.values()].find(row => ref(one(row, 'block/link')) === target);
    await stage({ type, pageUuid: target, favoriteUuid: existing?.uuid ?? uuid(), favorite: !existing,
      order: await order(rows, '00000004-1018-5888-4100-000000000000'), createdAt: baseTime + sequence });
  } else if (type === 'create-asset') {
    const asset = uuid(), transcript = uuid();
    const bytes = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1XcAAAAASUVORK5CYII=', 'base64');
    const localPath = path.join(runRoot, `source-${asset}.png`);
    fs.writeFileSync(localPath, bytes);
    const deferredTranscript = random() < 0.5;
    const payload = { uuid: asset, title: `photo-${sequence}.png`, now: baseTime + sequence,
      assetType: 'png', assetSize: bytes.length, assetChecksum: crypto.createHash('sha256').update(bytes).digest('hex'),
      localPath, targetBlockId: id, ...(deferredTranscript ? {} : { transcript: 'Transcript 中文 😀', transcriptUUID: transcript }) };
    trace({ event: 'asset-capture', sequence: sequence++, payload });
    await mobile.rpc('addAsset', payload);
    if (deferredTranscript) {
      await mobile.rpc('completeAssetTranscription', { parentId: asset, text: `Deferred transcript ${sequence} 中文 😀` });
      coverage['asset-transcription'] = (coverage['asset-transcription'] ?? 0) + 1;
    }
    coverage[type] = (coverage[type] ?? 0) + 1;
    assets.push({ uuid: asset, bytes });
  } else throw new Error(`Unknown generated operation: ${type}`);
}

async function main() {
  const creator = new Client(path.join(runRoot, 'creator'));
  fixture.name = `Mobile Stress ${seed} ${baseTime}`;
  fixture.graphId = (await creator.call({ ...fixture, command: 'create', name: fixture.name })).graphId;
  await creator.close();
  await cli(['sync', 'download']);
  await cli(['sync', 'start']);
  trace({ event: 'start', seed, count, graphId: fixture.graphId, baseTime });
  mobile = new Mobile(path.join(runRoot, 'mobile'));
  await mobile.open(); await mobile.reconnect(); await mobile.flush();
  const page = await createPage(`Mobile random ${seed}`);
  await insert(page); await mobile.flush();
  const backlogStart = mobile.batchSizes.length;
  for (let index = 0; index < 101; index++) await insert(page, `Batch backlog ${index} 中文 😀`);
  await mobile.flush();
  assert.deepEqual(mobile.batchSizes.slice(backlogStart), [50, 50, 1], '101 queued edits must drain in three WebSocket batches');
  scenarios.push('101 queued edits upload as 50 + 50 + 1 transactions');
  const cliPage = `CLI random ${seed}`;
  await cli(['upsert', 'page', '--page', cliPage]);
  const cliSecondary = cliPage + ' secondary';
  await cli(['upsert', 'page', '--page', cliSecondary]);
  const cliIDs = [];
  let cliMutations = 2;
  const types = ['save-title', 'set-property', 'set-properties', 'insert-block', 'create-asset', 'move-block', 'move-blocks',
    'split-block', 'merge-backward', 'delete-blocks', 'create-tag', 'create-page', 'create-journal', 'add-tag', 'set-favorite', 'delete-page'];
  for (let index = 0; index < count; index++) {
    if (index === 32) { await mobile.offline(); scenarios.push('mobile offline while CLI writes'); }
    if (index === 56) {
      const offline = await mobile.inspect();
      assert(offline.pending.length > 0, 'Offline edits must remain queued before restart');
      const beforeRestart = offline.pending.map(op => op.id).sort();
      const old = mobile; await old.crash();
      mobile = new Mobile(old.root); await mobile.open();
      assert.deepEqual((await mobile.inspect()).pending.map(op => op.id).sort(), beforeRestart, 'Restart cannot lose offline operations');
      await mobile.reconnect(); scenarios.push('mobile crash preserves offline edits and captures'); await mobile.flush();
    }
    if (index === 40) {
      await cli(['sync', 'stop']);
      process.kill(Number(fs.readFileSync(path.join(fixture.root, 'server.pid'), 'utf8')), 'SIGSTOP'); serverPaused = true;
      await assert.rejects(fetch(fixture.baseUrl + '/health', { signal: AbortSignal.timeout(200) }));
      scenarios.push('both clients edit while the local server is unavailable');
    }
    if (index === 48) {
      process.kill(Number(fs.readFileSync(path.join(fixture.root, 'server.pid'), 'utf8')), 'SIGCONT'); serverPaused = false;
      await cli(['sync', 'start']);
    }
    if (index === 80) { await cli(['sync', 'stop']); scenarios.push('CLI offline while mobile writes'); }
    if (index === 104) {
      await mobile.flush();
      const offlineCLI = entities(await mobile.inspect());
      assert(![...offlineCLI.values()].some(row => one(row, 'block/title') === `CLI ${seed} 96 中文 😀`), 'CLI changes must actually remain offline');
      await cli(['sync', 'start']); scenarios.push('both clients reconnect and merge queued operations');
    }
    await operation(index < types.length ? types[index] : pick(types), page);
    if (index % 24 === 0) {
      const rows = entities(await mobile.inspect());
      const builtin = ident => [...rows.values()].find(row => one(row, 'db/ident') === ':' + ident).uuid;
      const capture = uuid();
      await mobile.rpc('send', { uuid: capture, text: `Quick capture ${index} 中文 😀`, now: baseTime + sequence++ });
      coverage.capture = (coverage.capture ?? 0) + 1;
      await mobile.rpc('sendTask', { uuid: uuid(), text: `Task capture ${index}`, now: baseTime + sequence++,
        status: { uuid: builtin('logseq.property/status.todo'), title: 'Todo', ident: 'logseq.property/status.todo' } });
      coverage['task-capture'] = (coverage['task-capture'] ?? 0) + 1;
      const card = await insert(page, `Card ${index} {{cloze answer}}`);
      await stage({ type: 'add-tag', uuid: card, tagUuid: builtin('logseq.class/Card') });
      for (const rating of ['again', 'hard', 'good', 'easy']) {
        const operationId = uuid();
        await mobile.rpc('reviewFlashcard', { uuid: card, rating, now: baseTime + sequence++ * 60000, operationId });
        coverage['review-' + rating] = (coverage['review-' + rating] ?? 0) + 1;
      }
    }
    if (index % 8 === 0) {
      const write = cli(['upsert', 'block', '--target-page', cliPage, '--content', `CLI ${seed} ${index} 中文 😀`]);
      const [created] = await Promise.all([write, ...(mobile.online ? [mobile.flush()] : [])]);
      // Entity IDs can change when the CLI rebases its offline overlay. Keep UUIDs.
      const inserted = await cli(['query', '--query', '[:find ?uuid :in $ ?title :where [?e :block/title ?title] [?e :block/uuid ?uuid]]',
        '--inputs', JSON.stringify([`CLI ${seed} ${index} 中文 😀`])]);
      assert.equal(inserted.result.length, 1);
      cliIDs.push(inserted.result[0][0]); cliMutations++;
      trace({ event: 'cli-insert', index, id: created.result[0], uuid: cliIDs.at(-1) });
      if (index % 16 === 0 && cliIDs.length > 2) {
        await cli(['upsert', 'block', '--uuid', cliIDs[0], '--content', `CLI edited ${index}`]); cliMutations++;
      }
      if (index % 24 === 16 && cliIDs.length > 2) {
        await cli(['upsert', 'block', '--uuid', cliIDs[1], '--target-page', cliSecondary]); cliMutations++;
      }
      if (index % 40 === 24 && cliIDs.length > 3) {
        await cli(['remove', 'block', '--uuid', cliIDs.shift()]); cliMutations++;
      }
    }
    if (index === 144) {
      await mobile.flush();
      await insert(page, 'Crash after acceptance must preserve this block exactly once');
      const old = mobile;
      assert((await old.flush({ crashAfterAccept: true })).crashed);
      mobile = new Mobile(old.root); await mobile.open();
      assert((await mobile.inspect()).pending.length > 0, 'The unacknowledged transaction must survive a process crash');
      await mobile.reconnect(); await mobile.flush();
    }
    if (index === 176 && fixture.restartSignalSupported) {
      await mobile.flush(); await mobile.offline();
      await insert(page, 'Queued while the local server restarts');
      const previousPID = fs.readFileSync(path.join(fixture.root, 'server.pid'), 'utf8');
      process.kill(Number(fs.readFileSync(path.join(fixture.root, 'manager.pid'), 'utf8')), 'SIGUSR2');
      let ready = false;
      for (let attempt = 0; attempt < 100; attempt++) {
        await sleep(100);
        if (fs.readFileSync(path.join(fixture.root, 'server.pid'), 'utf8') === previousPID) continue;
        try { if ((await fetch(fixture.baseUrl + '/health')).ok) { ready = true; break; } } catch {}
      }
      assert(ready, 'The real sync server must recover after SIGKILL');
      await mobile.reconnect(); await mobile.flush(); scenarios.push('local sync server crash and restart');
    }
    if (index === 120) await insert(page, 'Lost WebSocket acknowledgement must not lose this edit');
    if (mobile.online && index % 5 === 0) await mobile.flush({ loseReply: index === 120 });
    if (index % 16 === 15) console.log(`seed=${seed} operations=${index + 1}/${count} coverage=${Object.keys(coverage).length}`);
  }
  await cli(['sync', 'start']);
  if (!mobile.online) await mobile.reconnect();
  await mobile.flush();
  await sleep(500); await mobile.transportTail; await mobile.flush();
  const syncStatus = await mobile.rpc('beginPendingSync');
  assert.equal(syncStatus.pendingSyncError, null, 'Completed operations cannot leave a stale sync error');
  const local = await mobile.inspect();
  for (const asset of assets) {
    if (!local.datoms.some(([id]) => id === asset.uuid)) continue;
    const response = await fetch(`${fixture.baseUrl}/assets/${fixture.graphId}/${asset.uuid}.png`, { headers: { Authorization: `Bearer ${fixture.token}` } });
    assert.equal(response.status, 200, `Captured asset ${asset.uuid} must upload`);
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), asset.bytes, 'Captured asset bytes must survive offline restart and upload');
  }
  verifier = new Client(path.join(runRoot, 'server-verification'));
  await verifier.open();
  const server = await verifier.inspect();
  assert.equal(local.pending.length, 0);
  assert.equal(server.pending.length, 0, 'Server snapshot must already contain the current journal');
  assert.deepEqual(local.datoms, server.datoms, 'Mobile and a fresh server snapshot must have identical UUID-normalized datoms');
  let cliStatus;
  for (let attempt = 0; attempt < 100; attempt++) {
    cliStatus = await cli(['sync', 'status']);
    if (cliStatus['ws-state'] === 'open' && !cliStatus['pending-local'] && !cliStatus['pending-server'] && !cliStatus['pending-asset']) break;
    await sleep(100);
  }
  assert.equal(cliStatus['pending-local'], 0, 'CLI local changes must finish uploading');
  assert.equal(cliStatus['pending-server'], 0, 'CLI incoming changes must finish applying');
  const cliTitles = (await cli(['query', '--query', '[:find ?uuid ?title :where [?e :block/uuid ?uuid] [?e :block/title ?title]]'])).result;
  // The worker uses exclusive SQLite locking. Stop it cleanly before taking a backup.
  await cli(['server', 'stop']);
  cliStopped = true;
  const { DatabaseSync, backup } = require('node:sqlite');
  const database = new DatabaseSync(path.join(fixture.cliRoot, 'graphs', fixture.name, 'db.sqlite'), { readOnly: true });
  const cliSnapshot = path.join(runRoot, 'cli-confirmed.sqlite');
  try { await backup(database, cliSnapshot); } finally { database.close(); }
  const cliState = await verifier.call({ command: 'inspectFile', path: cliSnapshot });
  // Match master deps/db-sync/src/logseq/db_sync/checksum.cljs: these two
  // attributes are client-derived indexes, excluded from server checksums.
  const syncedDatoms = state => state.datoms.filter(([, attr]) => !['block/tx-id', 'block/refs'].includes(attr));
  assert.deepEqual(syncedDatoms(cliState), syncedDatoms(server), 'CLI, mobile, and server must converge on every synced UUID-normalized datom');
  const mobileTitles = local.datoms.filter(([, attr]) => attr === 'block/title').map(([uuid, , title]) => [uuid, title]);
  assert.deepEqual(cliTitles.sort(), mobileTitles.sort(), 'CLI and mobile titles must converge');
  for (const type of types) assert(coverage[type] > 0, `Missing mobile operation coverage: ${type}`);
  if (count >= 121) assert(scenarios.includes('server accepted but WebSocket acknowledgement was lost'));
  const summary = { seed, operations: sequence, cliMutations, coverage, movements, scenarios, assetUploads: assets.length,
    websocketBatches: { count: mobile.batchSizes.length, maximumOperations: Math.max(...mobile.batchSizes), maximumBytes: Math.max(...mobile.messageBytes) }, serverT: local.serverT,
    datoms: local.datoms.length, pending: local.pending.length, graphId: fixture.graphId, tracePath };
  fs.writeFileSync(path.join(runRoot, `summary-${seed}.json`), JSON.stringify(summary, null, 2));
  await mobile.rpc('openNode', { uuid: page });
  const snapshot = await mobile.call({ command: 'snapshot' });
  assert.equal(snapshot.result.pendingSyncRequest, null);
  delete snapshot.result.syncTransport;
  fs.writeFileSync(path.join(runRoot, 'confirmed-snapshot.json'), JSON.stringify(snapshot), { mode: 0o600 });
  await verifier.close();
  verifier = null;
  console.log('PASS', JSON.stringify(summary));
}
main().catch(error => { console.error('FAIL', error.stack); process.exitCode = 1; }).finally(async () => {
  if (serverPaused) process.kill(Number(fs.readFileSync(path.join(fixture.root, 'server.pid'), 'utf8')), 'SIGCONT');
  if (mobile) { try { await mobile.offline(); await mobile.close(); } catch {} }
  if (verifier) { try { await verifier.close(); } catch {} }
  if (fixture.name && !cliStopped) { try { await cli(['server', 'stop']); } catch (error) { console.error('CLI cleanup failed:', error.message); } }
});
