// 纯 JS 的 SSH 客户端：连上去、跑一条命令、拿输出。
//
// 为什么自己写：App 的 entitlements 只有 hid.client.event-dispatch，没有
// no-sandbox，沙盒内 exec 不了 /var/jb/usr/bin/ssh。所以这里用手机自己的
// sshd 当 shell 通道：App 内 Node 直接 TCP 连 127.0.0.1:22，跑命令拿结果。
//
// 只支持服务端普遍默认开启的算法子集，够连 OpenSSH 8.x：
//   密钥交换 curve25519-sha256
//   主机密钥 ssh-ed25519 / rsa-sha2-256 / rsa-sha2-512
//   加密     aes128-ctr
//   MAC      hmac-sha2-256
//   认证     password（默认）/ publickey
//
// 不做端口转发、SFTP、交互式终端。一条命令一份结果，用完就断。

import net from 'node:net';
import crypto from 'node:crypto';

const CLIENT_ID = 'SSH-2.0-DSHGo_1.0';
const CONNECT_TIMEOUT = 15_000;
const OUTPUT_LIMIT = 128 * 1024;
const MAX_PACKET = 35000;
const BLOCK = 16; // aes128-ctr 分组大小
const DEBUG = !!process.env.DSH_SSH_DEBUG;

export class SshError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

// ---- 编码工具 ----

const u32 = (n) => {
  const b = Buffer.allocUnsafe(4);
  b.writeUInt32BE(n >>> 0, 0);
  return b;
};

const str = (v) => {
  const body = Buffer.isBuffer(v) ? v : Buffer.from(String(v), 'utf8');
  return Buffer.concat([u32(body.length), body]);
};

// mpint：大端有符号整数。必须是最小表示：去掉前导 0，最高位为 1 时补一个 0。
function mpint(bytes) {
  let i = 0;
  while (i < bytes.length - 1 && bytes[i] === 0) i += 1;
  let out = bytes.subarray(i);
  if (out.length === 0) return str(Buffer.alloc(0));
  if (out[0] & 0x80) out = Buffer.concat([Buffer.from([0]), out]);
  return str(out);
}

class Reader {
  constructor(buf) {
    this.buf = buf;
    this.pos = 0;
  }
  get rest() {
    return this.buf.length - this.pos;
  }
  byte() {
    if (this.pos >= this.buf.length) throw new SshError('protocol', '报文提前结束');
    return this.buf[this.pos++];
  }
  uint32() {
    if (this.pos + 4 > this.buf.length) throw new SshError('protocol', '报文提前结束');
    const v = this.buf.readUInt32BE(this.pos);
    this.pos += 4;
    return v;
  }
  string() {
    const n = this.uint32();
    if (n > this.rest) throw new SshError('protocol', '字符串越界');
    const s = this.buf.subarray(this.pos, this.pos + n);
    this.pos += n;
    return s;
  }
  text() {
    return this.string().toString('utf8');
  }
  nameList() {
    return this.text().split(',').filter(Boolean);
  }
}

// ---- 连接与传输层 ----

class Transport {
  constructor(socket) {
    this.socket = socket;
    this.buf = Buffer.alloc(0);      // 尚未解密的原始字节
    this.decBuf = Buffer.alloc(0);   // 已解密、尚未解析的字节
    this.seqOut = 0;
    this.seqIn = 0;
    this.encOut = null;
    this.encIn = null;
    this.macOut = null;
    this.macIn = null;
    this.dispatch = null;
    this.closed = false;
    this.onClose = null;
    this.started = false;
    socket.on('data', (chunk) => { if (this.started) this.feed(chunk); });
    socket.on('error', (err) => this.fail(new SshError('network', err.message)));
    socket.on('close', () => {
      this.closed = true;
      this.onClose?.();
    });
  }

  fail(error) {
    if (this.closed) return;
    this.closed = true;
    this.dispatch?.(null, error);
    this.onClose?.();
  }

  feed(chunk) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : chunk;
    try {
      this.drain();
    } catch (error) {
      this.fail(error instanceof SshError ? error : new SshError('protocol', error.message));
    }
  }

  drain() {
    while (!this.closed) {
      const packet = this.readPacket();
      if (packet === null) return;
      if (DEBUG) console.error(`[<-- ${packet.length}] ${packet.toString('hex').slice(0, 160)}`);
      this.dispatch?.(packet, null);
    }
  }

  kick() {
    try {
      this.drain();
    } catch (error) {
      this.fail(error instanceof SshError ? error : new SshError('protocol', error.message));
    }
  }

  stripPadding(plain) {
    const padding = plain[4];
    const payloadEnd = plain.length - padding;
    if (payloadEnd < 5) throw new SshError('protocol', '填充长度异常');
    return plain.subarray(5, payloadEnd);
  }

  // 返回 payload Buffer，或 null（数据还不够）
  readPacket() {
    if (!this.encIn) {
      if (this.buf.length < 5) return null;
      const len = this.buf.readUInt32BE(0);
      if (len < 5 || len > MAX_PACKET) throw new SshError('protocol', '报文长度异常');
      const total = 4 + len;
      if (this.buf.length < total) return null;
      const plain = this.buf.subarray(0, total);
      this.buf = this.buf.subarray(total);
      this.seqIn = (this.seqIn + 1) >>> 0;
      return this.stripPadding(plain);
    }

    // CTR 是流密码：只按整分组解密，而且只解密当前报文范围内的字节。
    // 一旦多解一个字节，密钥流就和服务端错位，后面全成乱码。
    while (this.decBuf.length < 5) {
      if (this.buf.length < BLOCK) return null;
      this.decBuf = Buffer.concat([this.decBuf, this.encIn.update(this.buf.subarray(0, BLOCK))]);
      this.buf = this.buf.subarray(BLOCK);
    }
    const len = this.decBuf.readUInt32BE(0);
    if (len < 5 || len > MAX_PACKET) throw new SshError('protocol', '报文长度异常');
    const total = 4 + len;
    // 发送端保证 4+len 是分组大小的整数倍
    if (total % BLOCK !== 0) throw new SshError('protocol', '报文长度未对齐');
    while (this.decBuf.length < total) {
      if (this.buf.length < BLOCK) return null;
      this.decBuf = Buffer.concat([this.decBuf, this.encIn.update(this.buf.subarray(0, BLOCK))]);
      this.buf = this.buf.subarray(BLOCK);
    }
    const plain = this.decBuf.subarray(0, total);
    this.decBuf = this.decBuf.subarray(total);

    if (this.macIn) {
      const macLen = this.macIn.size;
      if (this.buf.length < macLen) return null;
      const received = this.buf.subarray(0, macLen);
      const expected = this.macIn.compute(this.seqIn, plain);
      if (!crypto.timingSafeEqual(received, expected)) throw new SshError('protocol', 'MAC 校验失败');
      this.buf = this.buf.subarray(macLen);
    }
    this.seqIn = (this.seqIn + 1) >>> 0;
    return this.stripPadding(plain);
  }

  send(payload) {
    const blockSize = this.encOut ? BLOCK : 8;
    // 4+len 必须是 blockSize 的整数倍：len = payload+padding+1
    let padding = blockSize - ((payload.length + 5) % blockSize);
    if (padding < 4) padding += blockSize;
    const len = payload.length + padding + 1;
    const head = Buffer.concat([u32(len), Buffer.from([padding])]);
    let packet = Buffer.concat([head, payload, crypto.randomBytes(padding)]);
    // MAC 是对明文报文算的，而且它本身不加密，明文附在密文后面
    const mac = this.macOut ? this.macOut.compute(this.seqOut, packet) : null;
    if (this.encOut) packet = this.encOut.update(packet);
    if (mac) packet = Buffer.concat([packet, mac]);
    this.seqOut = (this.seqOut + 1) >>> 0;
    this.socket.write(packet);
  }
}

function hmac(alg, key) {
  const size = alg === 'hmac-sha1' ? 20 : crypto.createHmac('sha256', key).digest().length;
  return {
    size,
    compute(seq, packet) {
      const mac = crypto.createHmac(alg, key);
      mac.update(u32(seq));
      mac.update(packet);
      return mac.digest();
    },
  };
}

// HASH(K || H || letter || session_id)
function derive(hashName, kMpint, exchangeHash, letter, sessionId, length) {
  let out = crypto.createHash(hashName)
    .update(Buffer.concat([mpint(kMpint), exchangeHash, Buffer.from(letter), sessionId]))
    .digest();
  while (out.length < length) {
    out = Buffer.concat([out, crypto.createHash(hashName)
      .update(Buffer.concat([mpint(kMpint), exchangeHash, out]))
      .digest()]);
  }
  return out.subarray(0, length);
}

// ---- 密钥交换：curve25519-sha256 ----

function x25519() {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('x25519');
  const raw = publicKey.export({ type: 'spki', format: 'der' });
  // SPKI 末尾 32 字节是裸公钥
  const pub = raw.subarray(raw.length - 32);
  return {
    public: pub,
    agree(peerPub) {
      if (peerPub.length !== 32) throw new SshError('kex', '服务端公钥长度不是 32 字节。');
      const spki = Buffer.concat([
        Buffer.from('302a300506032b656e032100', 'hex'),
        peerPub,
      ]);
      const key = crypto.createPublicKey({ key: spki, format: 'der', type: 'spki' });
      return crypto.diffieHellman({ privateKey, publicKey: key });
    },
  };
}

// ---- 公钥认证签名 ----

function signData(pem, data, algorithm) {
  if (algorithm === 'ssh-ed25519') {
    const key = crypto.createPrivateKey(pem);
    return crypto.sign(null, data, key);
  }
  if (algorithm === 'rsa-sha2-256' || algorithm === 'rsa-sha2-512') {
    const key = crypto.createPrivateKey(pem);
    const hash = algorithm === 'rsa-sha2-512' ? 'sha512' : 'sha256';
    return crypto.sign(hash, data, { key, padding: crypto.constants.RSA_PKCS1_PADDING });
  }
  throw new SshError('auth', `不支持的签名算法 ${algorithm}`);
}

// ---- 对外入口 ----

/**
 * 跑一条命令，返回 { stdout, stderr, code }。
 * 一次一个连接，用完就断；不在手机上留半开状态。
 *
 * 认证：给 password 就走密码；给 privateKey 就走公钥。
 */
export async function exec({
  host, port = 22, username, password, privateKey, passphrase, command, timeoutMs = 30_000,
}) {
  if (typeof host !== 'string' || !host.trim()) throw new SshError('arguments', '主机地址不能为空。');
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new SshError('arguments', '端口无效。');
  if (typeof username !== 'string' || !username.trim()) throw new SshError('arguments', '用户名不能为空。');
  if (typeof command !== 'string' || !command.trim()) throw new SshError('arguments', '命令不能为空。');
  if (Buffer.byteLength(command) > 8192) throw new SshError('arguments', '命令太长。');

  const usePassword = typeof password === 'string' && password.length > 0;
  let pem = null;
  let algorithm = null;
  if (!usePassword) {
    if (typeof privateKey !== 'string' || !privateKey.includes('PRIVATE KEY')) {
      throw new SshError('arguments', '没有可用的密码或私钥。');
    }
    const key = passphrase
      ? crypto.createPrivateKey({ key: privateKey, passphrase })
      : crypto.createPrivateKey(privateKey);
    pem = key.export({ type: 'pkcs8', format: 'pem' });
    algorithm = key.asymmetricKeyType === 'ed25519' ? 'ssh-ed25519'
      : key.asymmetricKeyType === 'rsa' ? 'rsa-sha2-256' : null;
    if (!algorithm) throw new SshError('auth', '只支持 ed25519 或 RSA 私钥。');
  }

  const socket = net.connect({ host, port });
  socket.setNoDelay(true);
  const transport = new Transport(socket);

  const deadline = setTimeout(() => transport.fail(new SshError('timeout', 'SSH 超时。')), timeoutMs);

  try {
    await new Promise((resolve, reject) => {
      const onError = (e) => reject(new SshError('network', e.message));
      socket.once('error', onError);
      const t = setTimeout(() => reject(new SshError('timeout', '连接超时。')), CONNECT_TIMEOUT);
      socket.once('connect', () => {
        clearTimeout(t);
        socket.off('error', onError);
        resolve();
      });
    });

    await exchangeIdentification(transport);
    const session = await keyExchange(transport);
    await waitServiceAccept(transport);

    if (usePassword) await authenticatePassword(transport, username, password);
    else await authenticatePublicKey(transport, session, { username, pem, algorithm });

    return await runCommand(transport, command);
  } finally {
    clearTimeout(deadline);
    socket.destroy();
  }
}

// 版本交换要抢在 Transport 解析之前完成：先把收到的字节攒着，
// 找到换行后把剩余部分交回 Transport，避免两条 data 监听打架。
function exchangeIdentification(transport) {
  return new Promise((resolve, reject) => {
    const socket = transport.socket;
    socket.pause();
    let buf = Buffer.alloc(0);
    let settled = false;
    let sentBanner = false;

    const done = (error, line) => {
      if (settled) return;
      settled = true;
      socket.off('data', onData);
      socket.off('error', onError);
      if (error) reject(error);
      else resolve(line);
    };

    const onError = (e) => done(new SshError('network', e.message));

    const onData = (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      // 服务端可能先发若干行注释，再发真正的 SSH- 行
      for (;;) {
        const idx = buf.indexOf(0x0a);
        if (idx < 0) {
          if (buf.length > 8192) done(new SshError('protocol', '服务端标识过长。'));
          return;
        }
        const line = buf.subarray(0, idx).toString('utf8').replace(/\r$/, '');
        buf = buf.subarray(idx + 1);
        if (!line.startsWith('SSH-')) continue; // 跳过注释行
        if (!sentBanner) {
          sentBanner = true;
          socket.write(`${CLIENT_ID}\r\n`);
        }
        const rest = buf;
        transport.serverId = line;
        done(null, line);
        transport.started = true;
        // 不要在这里 drain：此时上层还没装好 dispatch，会把这个包丢掉。
        // 先攒进 buf，等 keyExchange 装好 dispatch 再 kick()。
        if (rest.length) transport.buf = rest;
        socket.resume();
        return;
      }
    };

    socket.on('data', onData);
    socket.on('error', onError);
    socket.write(`${CLIENT_ID}\r\n`);
    sentBanner = true;
    socket.resume();
  });
}

function buildKexInit() {
  const cookie = crypto.randomBytes(16);
  return Buffer.concat([
    Buffer.from([20]),
    cookie,
    str('curve25519-sha256,curve25519-sha256@libssh.org'),
    str('ssh-ed25519,rsa-sha2-256,rsa-sha2-512'),
    str('aes128-ctr'), str('aes128-ctr'),
    str('hmac-sha2-256'), str('hmac-sha2-256'),
    str('none'), str('none'),
    str(''), str(''),
    Buffer.from([0]),
    u32(0),
  ]);
}

function keyExchange(transport) {
  return new Promise((resolve, reject) => {
    const curve = x25519();
    const clientKexInit = buildKexInit();
    let pendingKeys = null;
    let newKeysSent = false;
    let newKeysReceived = false;
    let hostKeyAlg = null;

    const finish = (error, value) => {
      transport.dispatch = null;
      if (error) reject(error);
      else resolve(value);
    };

    transport.dispatch = (payload, error) => {
      if (error) { finish(error); return; }
      const type = payload[0];

      // 20 = KEXINIT
      if (type === 20 && !newKeysSent) {
        transport.serverKexInitPayload = payload;
        let r;
        try {
          // cookie 是 16 字节裸数据，不是 SSH string，直接跳过
          r = new Reader(payload.subarray(17));
        } catch (e) { finish(e); return; }
        const kex = r.nameList();
        const hostKey = r.nameList();
        if (!kex.includes('curve25519-sha256') && !kex.includes('curve25519-sha256@libssh.org')) {
          finish(new SshError('algorithm', `服务端不支持 curve25519-sha256，它提供 ${kex.slice(0, 4).join(',')}`));
          return;
        }
        hostKeyAlg = ['ssh-ed25519', 'rsa-sha2-256', 'rsa-sha2-512'].find((a) => hostKey.includes(a));
        if (!hostKeyAlg) {
          finish(new SshError('algorithm', `服务端主机密钥算法不受支持：${hostKey.slice(0, 4).join(',')}`));
          return;
        }
        transport.clientKexInitPayload = clientKexInit;
        transport.pendingHostKeyAlg = hostKeyAlg;
        // ECDH_INIT (30)
        transport.send(Buffer.concat([Buffer.from([30]), str(curve.public)]));
        newKeysSent = true;
        return;
      }

      // 31 = ECDH_REPLY
      if (type === 31 && !pendingKeys) {
        try {
          const r = new Reader(payload.subarray(1));
          const hostKeyBlob = r.string();
          const serverPub = r.string();
          r.string(); // signature，这台手机是本机连接，不校验主机密钥签名

          const shared = curve.agree(serverPub);

          // H = HASH(V_C || V_S || I_C || I_S || K_S || Q_C || Q_S || K)
          const vc = Buffer.from(CLIENT_ID);
          const vs = Buffer.from(transport.serverId ?? '');
          const h = crypto.createHash('sha256').update(Buffer.concat([
            str(vc), str(vs), str(clientKexInit),
            str(transport.serverKexInitPayload ?? Buffer.alloc(0)),
            str(hostKeyBlob), str(curve.public), str(serverPub), mpint(shared),
          ])).digest();

          const sessionId = h;
          pendingKeys = {
            sessionId,
            exchangeHash: h,
            hostKeyBlob,
            ivC2S: derive('sha256', shared, h, 'A', sessionId, 16),
            ivS2C: derive('sha256', shared, h, 'B', sessionId, 16),
            keyC2S: derive('sha256', shared, h, 'C', sessionId, 16),
            keyS2C: derive('sha256', shared, h, 'D', sessionId, 16),
            macC2S: derive('sha256', shared, h, 'E', sessionId, 32),
            macS2C: derive('sha256', shared, h, 'F', sessionId, 32),
          };

          // NEWKEYS (21)：发出后立刻切出站密钥
          transport.send(Buffer.from([21]));
          transport.encOut = crypto.createCipheriv('aes-128-ctr', pendingKeys.keyC2S, pendingKeys.ivC2S);
          transport.macOut = hmac('sha256', pendingKeys.macC2S);
        } catch (e) {
          finish(e instanceof SshError ? e : new SshError('kex', e.message));
        }
        return;
      }

      // 21 = NEWKEYS：这一包还是旧密钥发的，处理完才切入站密钥
      if (type === 21 && pendingKeys && !newKeysReceived) {
        newKeysReceived = true;
        transport.encIn = crypto.createDecipheriv('aes-128-ctr', pendingKeys.keyS2C, pendingKeys.ivS2C);
        transport.macIn = hmac('sha256', pendingKeys.macS2C);
        transport.sessionId = pendingKeys.sessionId;
        transport.exchangeHash = pendingKeys.exchangeHash;
        transport.serverHostKey = pendingKeys.hostKeyBlob;
        // 7 = EXT_INFO，忽略
        finish(null, pendingKeys);
        return;
      }

      if (type === 7) return; // EXT_INFO
    };

    transport.send(clientKexInit);
    transport.kick();
  });
}

// 密钥交换后必须先请求 ssh-userauth 服务，OpenSSH 才会受理认证请求。
function waitServiceAccept(transport) {
  return new Promise((resolve, reject) => {
    const finish = (error) => {
      transport.dispatch = null;
      if (error) reject(error);
      else resolve();
    };
    transport.dispatch = (payload, error) => {
      if (error) { finish(error); return; }
      const type = payload[0];
      if (type === 6) { finish(null); return; }     // SERVICE_ACCEPT
      if (type === 7) return;                        // EXT_INFO
    };
    transport.send(Buffer.concat([Buffer.from([5]), str('ssh-userauth')]));
  });
}

function authenticatePassword(transport, username, password) {
  return new Promise((resolve, reject) => {
    const finish = (error) => {
      transport.dispatch = null;
      if (error) reject(error);
      else resolve();
    };
    transport.dispatch = (payload, error) => {
      if (error) { finish(error); return; }
      const type = payload[0];
      if (type === 52) { finish(null); return; }   // USERAUTH_SUCCESS
      if (type === 51) {                            // USERAUTH_FAILURE
        let methods = [];
        try { methods = new Reader(payload.subarray(1)).nameList(); } catch { /* 忽略 */ }
        finish(new SshError('auth', `密码被拒；服务端接受 ${methods.join(',') || '无'}。`));
        return;
      }
      if (type === 53) return;                      // USERAUTH_BANNER
    };

    transport.send(Buffer.concat([
      Buffer.from([50]),                            // USERAUTH_REQUEST
      str(username),
      str('ssh-connection'),
      str('password'),
      Buffer.from([0]),                             // FALSE = 不是改密码
      str(password),
    ]));
  });
}

function authenticatePublicKey(transport, session, { username, pem, algorithm }) {
  return new Promise((resolve, reject) => {
    let publicKeyBlob = null;

    const finish = (error) => {
      transport.dispatch = null;
      if (error) reject(error);
      else resolve();
    };

    transport.dispatch = (payload, error) => {
      if (error) { finish(error); return; }
      const type = payload[0];
      if (type === 51) {
        let methods = [];
        try { methods = new Reader(payload.subarray(1)).nameList(); } catch { /* 忽略 */ }
        finish(new SshError('auth', `公钥认证被拒；服务端接受 ${methods.join(',') || '无'}。`));
        return;
      }
      if (type === 53) return; // BANNER
      if (type === 60) {
        // USERAUTH_PK_OK：带上签名再发一次
        try {
          if (!publicKeyBlob) throw new SshError('auth', '内部错误：未记录公钥');
          const sig = signData(pem, Buffer.concat([
            str(session.sessionId), Buffer.from([50]), str(username), str('ssh-connection'),
            str(algorithm), str(publicKeyBlob),
          ]), algorithm);
          transport.send(Buffer.concat([
            Buffer.from([50]), str(username), str('ssh-connection'), str(algorithm),
            str(publicKeyBlob),
            str(Buffer.concat([str(algorithm), str(sig)])),
          ]));
        } catch (e) {
          finish(e instanceof SshError ? e : new SshError('auth', e.message));
        }
        return;
      }
      if (type === 52) { finish(null); return; }
    };

    // 从私钥导出 SSH 公钥 blob
    const key = crypto.createPrivateKey(pem);
    if (algorithm === 'ssh-ed25519') {
      const spki = key.export({ type: 'spki', format: 'der' });
      const pub = spki.subarray(spki.length - 32);
      publicKeyBlob = Buffer.concat([str('ssh-ed25519'), str(pub)]);
    } else {
      const jwk = key.export({ format: 'jwk' });
      const n = Buffer.from(jwk.n, 'base64url');
      const e = Buffer.from(jwk.e, 'base64url');
      publicKeyBlob = Buffer.concat([str('rsa-sha2-256'), mpint(e), mpint(n)]);
    }

    // 先只发公钥试探，服务端回 PK_OK 再签名
    transport.send(Buffer.concat([
      Buffer.from([50]), str(username), str('ssh-connection'),
      str(algorithm), str(publicKeyBlob),
    ]));
  });
}

function runCommand(transport, command) {
  return new Promise((resolve, reject) => {
    const stdout = [];
    const stderr = [];
    let bytes = 0;
    let code = null;
    let done = false;
    let remoteChannel = null;

    const finish = () => {
      if (done) return;
      done = true;
      transport.dispatch = null;
      resolve({
        stdout: Buffer.concat(stdout).toString('utf8'),
        stderr: Buffer.concat(stderr).toString('utf8'),
        code,
      });
    };

    const failWith = (err) => {
      if (done) return;
      done = true;
      transport.dispatch = null;
      reject(err);
    };

    // 把吃掉的窗口补回去，否则输出超过 32KB 服务端就卡住不发。
    const adjustWindow = (n) => {
      if (!n || remoteChannel === null) return;
      transport.send(Buffer.concat([Buffer.from([93]), u32(remoteChannel), u32(n)]));
    };

    transport.onClose = () => {
      if (done) return;
      if (code === null) {
        failWith(new SshError('network', '连接在命令结束前断开。'));
        return;
      }
      finish();
    };

    transport.dispatch = (payload, error) => {
      if (error) { failWith(error); return; }
      const type = payload[0];
      switch (type) {
        case 91: { // CHANNEL_OPEN_CONFIRMATION
          const r = new Reader(payload.subarray(1));
          r.uint32();
          remoteChannel = r.uint32();
          transport.channelRemote = remoteChannel;
          transport.send(Buffer.concat([
            Buffer.from([98]), // CHANNEL_REQUEST
            u32(remoteChannel),
            str('exec'),
            Buffer.from([1]),  // want reply
            str(command),
          ]));
          break;
        }
        case 92: { // CHANNEL_OPEN_FAILURE
          const r = new Reader(payload.subarray(1));
          r.uint32();
          const reason = r.uint32();
          let desc = '';
          try { desc = r.text(); } catch { /* 忽略 */ }
          failWith(new SshError('channel', `服务端拒绝打开会话（${reason}）${desc ? '：' + desc : ''}`));
          break;
        }
        case 93: // CHANNEL_WINDOW_ADJUST
        case 99: // CHANNEL_SUCCESS
          break;
        case 94: { // CHANNEL_DATA
          const r = new Reader(payload.subarray(1));
          r.uint32();
          const data = r.string();
          bytes += data.length;
          if (bytes <= OUTPUT_LIMIT) stdout.push(data);
          adjustWindow(data.length);
          break;
        }
        case 95: { // CHANNEL_EXTENDED_DATA（stderr）
          const r = new Reader(payload.subarray(1));
          r.uint32();
          r.uint32();
          const data = r.string();
          bytes += data.length;
          if (bytes <= OUTPUT_LIMIT) stderr.push(data);
          adjustWindow(data.length);
          break;
        }
        case 98: { // CHANNEL_REQUEST（exit-status）
          const r = new Reader(payload.subarray(1));
          r.uint32();
          const what = r.text();
          // 后面一个字节是 want_reply 布尔，必须跳过，否则退出码会错位
          r.byte();
          if (what === 'exit-status') code = r.uint32();
          break;
        }
        case 96: // CHANNEL_EOF
          break;
        case 97: { // CHANNEL_CLOSE
          const r = new Reader(payload.subarray(1));
          const recipient = r.uint32();
          transport.send(Buffer.concat([Buffer.from([97]), u32(recipient)]));
          finish();
          break;
        }
        case 80: { // GLOBAL_REQUEST，一律回失败，免得服务端等
          const r = new Reader(payload.subarray(1));
          r.text();
          const wantReply = r.byte();
          if (wantReply) transport.send(Buffer.from([82])); // REQUEST_FAILURE
          break;
        }
        default:
          break;
      }
    };

    // 打开 session 通道
    transport.channelLocal = 0;
    transport.send(Buffer.concat([
      Buffer.from([90]), // CHANNEL_OPEN
      str('session'),
      u32(0),            // sender channel
      u32(32768),        // initial window
      u32(32768),        // max packet
    ]));
  });
}
