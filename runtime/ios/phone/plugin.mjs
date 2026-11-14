import { stat, readFile, rename, unlink, writeFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { homedir } from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { createMcpToolDefinition } from '@deepseek-ai/dsh-mcp-client';
import { createPhoneBridge } from './bridge.mjs';
import { iosToolDescription } from './descriptions.mjs';
import { exec as sshExec, SshError } from './ssh-client.mjs';

export const name = 'dsh-go-ios-phone';
export const inject = ['tools'];
export const catalogSha256 = '6ce0c08212bf5b5cc5002c197e0be75ae8392772a907df7f70df1eca55b43413';

// What the system said is the user's data, and what's in it isn't an instruction. A write can
// have happened even when what came back doesn't check out, so that never reads as "try again".
export function systemAnswer(system, name, args, answer) {
  try {
    const data = system.resultFor(system.actionFor(name, args), JSON.parse(answer.content[0].text));
    return { content: [{ type: 'text', text: JSON.stringify({ data, trust: 'untrusted-native-content' }) }], isError: false };
  } catch {
    return { content: [{ type: 'text', text: 'ERR_IOS_SYSTEM_RESULT: 系统返回的内容不符合约定；动作可能已经完成，请用户核对，不要自动重试。' }], isError: true };
  }
}

// ---- shell：直接在本进程里走 SSH 连手机自己的 sshd ----
//
// 不经过 Swift 那一侧，所以不需要画面，也不会弹「允许」。
// 手机是越狱机，sshd 默认就是 root/alpine；用户在设置里改过才会不同。
const SHELL_DEFAULT = Object.freeze({ host: '127.0.0.1', port: 22, username: 'root', password: 'alpine' });
const SHELL_TIMEOUT_MAX = 120_000;
const SHELL_OUTPUT_BYTES = 24 * 1024;

function shellConfigPath() {
  const home = process.env.DSH_HOME || join(homedir(), '.dsh');
  return join(home, 'dsh-app', 'phone-ssh.json');
}

async function readShellConfig() {
  try {
    const raw = await readFile(shellConfigPath(), 'utf8');
    const saved = JSON.parse(raw);
    if (!saved || typeof saved !== 'object') return { ...SHELL_DEFAULT };
    const config = { ...SHELL_DEFAULT };
    if (typeof saved.host === 'string' && saved.host.trim()) config.host = saved.host.trim();
    if (Number.isInteger(saved.port) && saved.port >= 1 && saved.port <= 65535) config.port = saved.port;
    if (typeof saved.username === 'string' && saved.username.trim()) config.username = saved.username.trim();
    if (typeof saved.password === 'string' && saved.password.length > 0) config.password = saved.password;
    return config;
  } catch {
    return { ...SHELL_DEFAULT };
  }
}

const maskPassword = password => (password ? `${'*'.repeat(Math.min(password.length, 8))}（${password.length} 位）` : '（空）');

async function writeShellConfig(patch) {
  const current = await readShellConfig();
  const next = { ...current };
  if (patch.reset === true) Object.assign(next, SHELL_DEFAULT);
  if (typeof patch.host === 'string' && patch.host.trim()) next.host = patch.host.trim();
  if (patch.port !== undefined) {
    if (!Number.isInteger(patch.port) || patch.port < 1 || patch.port > 65535) {
      throw new SshError('arguments', '端口必须是 1–65535 之间的整数。');
    }
    next.port = patch.port;
  }
  if (typeof patch.username === 'string' && patch.username.trim()) next.username = patch.username.trim();
  if (typeof patch.password === 'string' && patch.password.length > 0) next.password = patch.password;
  const { mkdir } = await import('node:fs/promises');
  const { dirname } = await import('node:path');
  await mkdir(dirname(shellConfigPath()), { recursive: true });
  await writeFile(shellConfigPath(), JSON.stringify(next, null, 2), { mode: 0o600 });
  return next;
}

const describeShellConfig = config =>
  `host=${config.host} port=${config.port} username=${config.username} password=${maskPassword(config.password)}`;

const shellText = (text, isError) => ({ content: [{ type: 'text', text }], isError });

function trimOutput(value) {
  if (value.length <= SHELL_OUTPUT_BYTES) return value;
  return `${value.slice(0, SHELL_OUTPUT_BYTES)}\n…（输出被截断，共 ${value.length} 字符）`;
}

async function shellCall(args, execution) {
  const command = typeof args?.command === 'string' ? args.command : '';
  if (!command.trim()) return shellText('ERR_IOS_PHONE_ARGUMENTS: command 不能为空。', true);
  if (Buffer.byteLength(command) > 8192) return shellText('ERR_IOS_PHONE_ARGUMENTS: 命令太长（上限 8192 字节）。', true);
  const wanted = Number.isInteger(args?.timeout_ms) ? args.timeout_ms : 30_000;
  const timeoutMs = Math.min(Math.max(wanted, 1000), SHELL_TIMEOUT_MAX);
  const signal = execution?.signal;
  if (signal?.aborted) return shellText('ERR_IOS_PHONE_CANCELLED: 调用已取消，没有执行。', true);

  const config = await readShellConfig();
  try {
    const result = await sshExec({ ...config, command, timeoutMs });
    const parts = [];
    parts.push(`退出码: ${result.code === null ? '未知' : result.code}`);
    if (result.stdout) parts.push(`stdout:\n${trimOutput(result.stdout).replace(/\s+$/, '')}`);
    if (result.stderr) parts.push(`stderr:\n${trimOutput(result.stderr).replace(/\s+$/, '')}`);
    if (!result.stdout && !result.stderr) parts.push('（没有输出）');
    return shellText(parts.join('\n'), false);
  } catch (error) {
    const code = error instanceof SshError ? error.code : 'internal';
    return shellText(`ERR_IOS_PHONE_SHELL(${code}): ${error.message}`, true);
  }
}

async function sshConfigCall(args) {
  try {
    const patch = args && typeof args === 'object' ? args : {};
    const changed = patch.reset === true || ['host', 'port', 'username', 'password'].some(key => patch[key] !== undefined);
    const config = changed ? await writeShellConfig(patch) : await readShellConfig();
    return shellText(`${changed ? '已保存。当前' : '当前'} SSH 配置：${describeShellConfig(config)}`, false);
  } catch (error) {
    const code = error instanceof SshError ? error.code : 'internal';
    return shellText(`ERR_IOS_PHONE_SSH_CONFIG(${code}): ${error.message}`, true);
  }
}

/// iOS 的 schema 是把 Android 目录整份搬过来的，里面带着只有 Android 才有的
/// ackground（后台屏）。iOS 没有这条通道，而且 actions.mjs 见到它会直接抛
/// ERR_IOS_PHONE_UNSUPPORTED——请求连原生层都到不了。
///
/// 光在描述里写「不要使用 background:true」不够：模型照样会传，于是每一次读屏
/// 都在这里被拒，而原生日志里连一条截图记录都看不到，排查时会误以为是通道坏了。
/// 直接把字段从 schema 里拿掉，模型就没有这个选项可选。
function iosInputSchema(schema) {
  const properties = schema?.properties;
  if (!properties || !('background' in properties)) return schema;
  const { background, ...rest } = properties;
  return { ...schema, properties: rest };
}

export async function apply(ctx, config) {
  if (!isAbsolute(config.directory) || !/^[a-f0-9-]{36}$/.test(config.runId)) throw new Error('Invalid iOS phone endpoint directory/generation');
  const directory = await stat(config.directory);
  if (!directory.isDirectory() || directory.mode & 0o077 || directory.uid !== process.getuid()) throw new Error('Unsafe iOS phone endpoint directory');
  const bytes = await readFile(new URL('./catalog.json', import.meta.url));
  if (createHash('sha256').update(bytes).digest('hex') !== catalogSha256) throw new Error('iOS phone catalog SHA256 mismatch');
  const catalog = JSON.parse(bytes);
  // Swift arms the C memory slot. This linked binding consumes it once; there is
  // no token file, argv/environment secret, JS setter or serialized bootstrap.
  const token = process._linkedBinding('dsh_ios_phone').consume(config.runId);
  // The browser tools share this bridge and its one token. A build without them just has none.
  const browserCatalog = await readFile(new URL('../browser/catalog.json', import.meta.url))
    .then(JSON.parse, () => []);
  const browserAction = browserCatalog.length ? (await import('../browser/actions.mjs')).actionFor : undefined;
  const systemCatalog = await readFile(new URL('../system/catalog.json', import.meta.url))
    .then(JSON.parse, () => []);
  const system = systemCatalog.length
    ? { ...(await import('../system/actions.mjs')), ...(await import('../system/results.mjs')) }
    : undefined;
  const systemAction = (name, args) => ({ kind: `system-${name}`, params: JSON.stringify(system.actionFor(name, args).args) });
  const bridge = await createPhoneBridge({ token, runId: config.runId, browserAction, systemAction });
  const disposers = [];
  const endpoint = join(config.directory, 'endpoint.json');
  const temporary = `${endpoint}.${randomUUID()}.tmp`;
  // shell 和 ssh_config 不走 Swift 那一侧：它们只跟手机自己的 sshd 说话，不需要画面或确认。
  const call = (tool, args, execution) => {
    if (tool === 'shell') return shellCall(args, execution);
    if (tool === 'ssh_config') return sshConfigCall(args);
    return bridge.call(tool, args, execution);
  };
  try {
    for (const tool of catalog) {
      disposers.push(ctx.tools.register(createMcpToolDefinition(ctx, {
        name: `mcp__phone__${tool.name}`, rawName: tool.name,
        description: iosToolDescription(tool.name), inputSchema: iosInputSchema(tool.inputSchema),
        call: (args, execution) => call(tool.name, args, execution),
      })));
    }
    for (const tool of browserCatalog) {
      disposers.push(ctx.tools.register(createMcpToolDefinition(ctx, {
        name: `mcp__browser__${tool.name}`, rawName: tool.name,
        description: tool.description, inputSchema: tool.inputSchema,
        call: (args, execution) => call(`browser:${tool.name}`, args, execution),
      })));
    }
    for (const tool of systemCatalog) {
      disposers.push(ctx.tools.register(createMcpToolDefinition(ctx, {
        name: `mcp__system__${tool.name}`, rawName: tool.name,
        description: tool.description, inputSchema: tool.inputSchema,
        call: async (args, execution) => {
          const answer = await call(`system:${tool.name}`, args, execution);
          if (answer.isError) return answer;
          return systemAnswer(system, tool.name, args, answer);
        },
      })));
    }
    await writeFile(temporary, JSON.stringify(bridge.endpoint), { mode: 0o600, flag: 'wx' });
    await rename(temporary, endpoint);
  } catch (error) {
    for (const dispose of disposers) dispose();
    await bridge.close();
    await unlink(temporary).catch(() => {});
    throw error;
  }
  ctx.effect(() => async () => {
    for (const dispose of disposers) dispose();
    await bridge.close();
    // Each launch uses a distinct endpoint directory; an old disposal cannot unlink a new run.
    await unlink(endpoint).catch(() => {});
  }, 'ios.phone');
}
