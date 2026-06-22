#!/usr/bin/env node
// 集成测试:起 Swift daemon(spawn 真 codex app-server),连两个 ws 下游 A/B,
// A 驱动一个 turn,断言 A 和 B 都实时收到 turn/item/agentMessage(完全同步)。
// 清理:只 SIGTERM 自己起的 daemon(daemon 优雅关闭会 terminate 自己的 codex)。绝不 pkill。
const { spawn } = require('child_process');
const net = require('net');
const crypto = require('crypto');
const path = require('path');

const PORT = 8771;
const TOKEN = 'integtok';
const DAEMON = path.join(__dirname, '..', '.build', 'debug', 'codex-bridge-daemon');

const log = (...a) => console.log(...a);

// --- 极简 ws 客户端(连 daemon TCP ws,发/收 envelope 文本帧) ---
function wsClient(name, onEvent) {
  const key = crypto.randomBytes(16).toString('base64');
  const c = net.connect(PORT, '127.0.0.1');
  let up = false, rx = Buffer.alloc(0), jb = '';
  function sendText(s) {
    const p = Buffer.from(s), l = p.length, mask = crypto.randomBytes(4);
    let h;
    if (l < 126) h = Buffer.from([0x81, 0x80 | l]);
    else if (l < 65536) h = Buffer.from([0x81, 0x80 | 126, (l >> 8) & 255, l & 255]);
    else { h = Buffer.alloc(10); h[0] = 0x81; h[1] = 0x80 | 127; h.writeUInt32BE(0, 2); h.writeUInt32BE(l, 6); }
    const md = Buffer.alloc(l); for (let i = 0; i < l; i++) md[i] = p[i] ^ mask[i & 3];
    c.write(Buffer.concat([h, mask, md]));
  }
  const api = {
    request(payloadObj) { sendText(JSON.stringify({ type: 'request', payload: payloadObj })); },
    raw: sendText,
  };
  c.on('connect', () => c.write(
    `GET /?token=${TOKEN} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
    `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`));
  c.on('data', d => {
    if (!up) {
      rx = Buffer.concat([rx, d]); const i = rx.indexOf('\r\n\r\n');
      if (i >= 0) {
        if (!rx.slice(0, i).toString().includes('101')) { log(`[${name}] upgrade 失败:`, rx.slice(0, i).toString().split('\r\n')[0]); process.exitCode = 2; }
        up = true; rx = rx.slice(i + 4); parse();
      }
      return;
    }
    rx = Buffer.concat([rx, d]); parse();
  });
  function parse() {
    while (rx.length >= 2) {
      const b2 = rx[1]; let l = b2 & 0x7f, off = 2;
      if (l === 126) { if (rx.length < 4) return; l = rx.readUInt16BE(2); off = 4; }
      else if (l === 127) { if (rx.length < 10) return; l = Number(rx.readBigUInt64BE(2)); off = 10; }
      if (rx.length < off + l) return;
      const pl = rx.slice(off, off + l); rx = rx.slice(off + l);
      jb += pl.toString(); let j;
      while ((j = jb.indexOf('\n')) >= 0) { handle(jb.slice(0, j)); jb = jb.slice(j + 1); }
      if (jb.trim().endsWith('}')) { handle(jb); jb = ''; }
    }
  }
  function handle(line) {
    line = line.trim(); if (!line) return;
    let env; try { env = JSON.parse(line); } catch { return; }
    if (env.type === 'event') onEvent(env.seq, env.payload);
  }
  c.on('error', e => log(`[${name}] err`, e.message));
  return api;
}

// --- 主流程 ---
const daemon = spawn(DAEMON, ['--port', String(PORT), '--token', TOKEN], { stdio: ['ignore', 'ignore', 'inherit'] });
log(`[runner] daemon pid=${daemon.pid}`);

const A = { methods: [] }, B = { methods: [] };
let tid = null, inited = false;

function cleanupAndExit(code) {
  try { daemon.kill('SIGTERM'); } catch {}   // 只终止自己起的 daemon;绝不 pkill
  setTimeout(() => process.exit(code), 1500);
}

setTimeout(() => {
  const a = wsClient('A', (seq, p) => {
    if (p && p.method) A.methods.push(p.method);
    // A 的 initialize 响应(id:1 result) → 发 initialized + thread/start
    if (p && p.id === 1 && p.result && !inited) {
      inited = true;
      a.request({ jsonrpc: '2.0', method: 'initialized' });
      a.request({ jsonrpc: '2.0', id: 2, method: 'thread/start', params: {} });
    }
    if (p && p.id === 2 && p.result) {
      tid = p.result.threadId || (p.result.thread && p.result.thread.id) || p.result.id;
      log('[A] thread started:', tid);
      a.request({ jsonrpc: '2.0', id: 3, method: 'turn/start', params: { threadId: tid, input: [{ type: 'text', text: 'say hi briefly' }] } });
      log('[A] turn/start sent');
    }
  });
  const b = wsClient('B', (seq, p) => { if (p && p.method) B.methods.push(p.method); });

  // A 握手 app-server(daemon 的唯一连接只需 initialize 一次)
  setTimeout(() => a.request({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { clientInfo: { name: 'A', version: '0.1' }, capabilities: {} } }), 800);
}, 3500);

// 收集 18s 后断言
setTimeout(() => {
  const want = ['turn/started', 'turn/completed'];
  const hasAll = (arr) => want.every(m => arr.includes(m)) && arr.some(m => m.includes('agentMessage'));
  log('\n=== A 收到 methods(去重) ===', [...new Set(A.methods)].join(', '));
  log('=== B 收到 methods(去重) ===', [...new Set(B.methods)].join(', '));
  const aOK = hasAll(A.methods), bOK = hasAll(B.methods);
  log(`\n[RESULT] A 收到全套: ${aOK} | B(旁观)收到全套: ${bOK}`);
  if (aOK && bOK) { log('✅ 双向同步成立:A 发起 turn,A 和 B 都实时收到 turn/item/agentMessage'); cleanupAndExit(0); }
  else { log('❌ 同步未成立'); cleanupAndExit(1); }
}, 28000);
