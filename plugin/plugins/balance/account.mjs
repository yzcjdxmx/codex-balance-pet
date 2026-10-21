#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";

const TIMEOUT_MS = 12000;
const SAFE_ERROR = Symbol("safe-account-error");
const RECHECK_ACCOUNT = Symbol("recheck-current-account");
const ACCOUNT_FINGERPRINT = Symbol("private-account-fingerprint");
const OFFICIAL_BALANCE_HOSTS = new Set(["api.deepseek.com"]);
const ERROR_MESSAGES = {
  CONFIG_INVALID: "当前服务商配置无法识别。",
  AUTH_MISSING: "当前服务商缺少 API 凭据。",
  BALANCE_UNSUPPORTED: "当前服务商未提供已配置的余额接口。",
  BALANCE_HTTP: "余额接口请求失败。",
  BALANCE_DATA: "余额接口未返回可识别的余额数据。",
  NETWORK_FAILED: "无法连接当前服务商的余额接口。",
  REQUEST_TIMEOUT: "实时查询超时，请稍后重试。",
  CODEX_NOT_FOUND: "未找到可用的 Codex 程序，暂时无法读取官方额度。",
  CODEX_START_FAILED: "Codex 额度读取程序无法启动。",
  CODEX_PROTOCOL: "Codex 暂时无法读取官方额度。",
  QUOTA_UNAVAILABLE: "官方账号暂未返回可用的额度窗口。",
  ACCOUNT_MISMATCH: "当前官方账号认证状态已变化，请刷新后重试。",
  ACCOUNT_CHANGED: "当前模型服务商已变化，请重新查询。",
};

function safeError(code, suffix = "") {
  const error = new Error((ERROR_MESSAGES[code] || ERROR_MESSAGES.CODEX_PROTOCOL) + suffix);
  error.code = code;
  error[SAFE_ERROR] = true;
  return error;
}

function homeFor(env) {
  const homes = [env.CODEX_HOME, (env.USERPROFILE || env.HOME) && path.join(env.USERPROFILE || env.HOME, ".codex")].filter(Boolean);
  return homes.find((p) => fs.existsSync(path.join(p, "config.toml"))) || homes[0] || null;
}

function readText(file) {
  try { return fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""); } catch { return ""; }
}

function readAuth(home) {
  try { return JSON.parse(readText(path.join(home, "auth.json"))); } catch { return {}; }
}

function readBalanceSource(home) {
  try {
    const setting = JSON.parse(readText(path.join(home, "balance-source.json")));
    return setting?.source === "chatgpt" ? "chatgpt" : "";
  } catch { return ""; }
}

// Only root assignments select a provider. Values inside an unrelated table
// cannot activate a stale provider or supply its credentials.
function parseConfig(text) {
  const root = {}, sections = new Map();
  let current = root;
  for (const raw of String(text).replace(/^\uFEFF/, "").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.startsWith("[")) {
      const section = line.match(/^\[model_providers\.(?:([A-Za-z0-9_-]+)|"([^"\\]+)"|'([^']+)')\]\s*(?:#.*)?$/);
      current = section ? {} : null;
      if (section) sections.set(section[1] || section[2] || section[3], current);
      continue;
    }
    if (!current) continue;
    const field = line.match(/^([A-Za-z0-9_]+)\s*=\s*(.*)$/);
    if (!field) continue;
    const value = field[2].match(/^("(?:[^"\\]|\\.)*"|'[^']*'|true|false)\s*(?:#.*)?$/);
    if (!value) {
      if (current === root && ["model", "model_provider"].includes(field[1])) root.invalid = true;
      continue;
    }
    try {
      current[field[1]] = value[1].startsWith("'") ? value[1].slice(1, -1) : JSON.parse(value[1]);
    } catch { if (current === root) root.invalid = true; }
  }
  return { root, sections };
}

function safeEndpoint(value) {
  try {
    const url = new URL(value);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) return "";
    url.search = ""; url.hash = "";
    return url.toString();
  } catch { return ""; }
}

function sourceFor(account) {
  return `${account.kind}/${account.provider}/${account.endpoint || "unavailable"}#${account[ACCOUNT_FINGERPRINT]}`;
}

function isOfficialChatGPTAlias(section) {
  if (section.requires_openai_auth !== true) return false;
  const endpoint = safeEndpoint(section.base_url);
  if (!endpoint) return false;
  const url = new URL(endpoint);
  return url.origin === "https://chatgpt.com" && url.pathname.replace(/\/+$/, "") === "/backend-api/codex";
}

export function resolveAccount(options = {}) {
  const env = options.env || process.env;
  const home = options.home || homeFor(env);
  const parsed = parseConfig(options.configText ?? (home ? readText(path.join(home, "config.toml")) : ""));
  const auth = options.auth ?? (home ? readAuth(home) : {});
  const explicit = typeof parsed.root.model_provider === "string" && parsed.root.model_provider.length > 0;
  const provider = explicit ? parsed.root.model_provider : "openai";
  const model = typeof parsed.root.model === "string" ? parsed.root.model : "";
  const section = explicit ? parsed.sections.get(provider) || {} : {};
  const balanceSource = options.balanceSource || (home ? readBalanceSource(home) : "");
  const official = provider === "openai" || isOfficialChatGPTAlias(section);
  const chatgpt = (official || balanceSource === "chatgpt") && auth?.auth_mode === "chatgpt";
  const endpoint = chatgpt ? "https://chatgpt.com" : safeEndpoint(section.base_url || (official ? "https://api.openai.com/v1" : ""));
  const account = { kind: chatgpt ? "quota" : "balance", provider, model, endpoint, home, key: "", balanceUrl: "", errorCode: null };
  if (parsed.root.invalid || ("model_provider" in parsed.root && (!explicit || typeof parsed.root.model_provider !== "string")) || ("model" in parsed.root && typeof parsed.root.model !== "string")) account.errorCode = "CONFIG_INVALID";
  if (!chatgpt) {
    // Overrides are explicit; there is never a fallback to a different provider.
    const deepseek = endpoint && OFFICIAL_BALANCE_HOSTS.has(new URL(endpoint).hostname);
    account.key = env.BALANCE_API_KEY || (section.env_key && env[section.env_key]) || section.experimental_bearer_token ||
      (auth?.auth_mode !== "chatgpt" ? auth?.OPENAI_API_KEY : "") || (deepseek ? env.DEEPSEEK_API_KEY : "") || "";
    const override = env.BALANCE_URL;
    if (override) {
      const safe = safeEndpoint(override);
      // Reject hidden URL credentials/query tokens rather than leak them in IDs.
      if (safe && new URL(override).search === "" && new URL(override).hash === "") account.balanceUrl = safe;
      else account.errorCode = "CONFIG_INVALID";
    } else if (endpoint && OFFICIAL_BALANCE_HOSTS.has(new URL(endpoint).hostname)) {
      account.balanceUrl = new URL("/user/balance", endpoint).toString();
    }
    if (!account.errorCode && !account.balanceUrl) account.errorCode = "BALANCE_UNSUPPORTED";
    if (!account.errorCode && !account.key) account.errorCode = "AUTH_MISSING";
    // A proxy or unknown platform must explicitly configure its balance URL;
    // never send that platform's key to the DeepSeek host by guessing a default.
    if (account.balanceUrl) account.endpoint = account.balanceUrl;
  }
  const identity = chatgpt ? auth?.tokens?.account_id || auth?.tokens?.access_token || auth?.tokens?.id_token || auth?.tokens?.refresh_token || "unresolved" : account.key || "unresolved";
  account[ACCOUNT_FINGERPRINT] = createHash("sha256").update(account.kind + ":" + String(identity)).digest("hex").slice(0, 16);
  account.source_id = sourceFor(account);
  if (options.configText === undefined && options.auth === undefined) account[RECHECK_ACCOUNT] = () => resolveAccount(options);
  return account;
}

function publicSource(account) {
  return { kind: account.kind, provider: account.provider, model: account.model, source_id: account.source_id };
}

function existingExecutable(candidate) {
  if (!candidate || typeof candidate !== "string" || !path.isAbsolute(candidate)) return false;
  try { return fs.statSync(candidate).isFile(); } catch { return false; }
}

async function runningCodexPaths(timeoutMs) {
  if (process.platform !== "win32") return [];
  return new Promise((resolve) => {
    let output = "", child, finished = false;
    const done = () => { if (finished) return; finished = true; clearTimeout(timer); resolve(output.split(/\r?\n/).map((p) => p.trim()).filter(Boolean)); };
    try {
      child = spawn("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "Get-Process -Name codex -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending | Select-Object -ExpandProperty Path -Unique"], { windowsHide: true, stdio: ["ignore", "pipe", "ignore"] });
    } catch { resolve([]); return; }
    const timer = setTimeout(() => { child.kill(); done(); }, Math.min(timeoutMs, 1500));
    child.stdout.on("data", (chunk) => { if (output.length < 65536) output += chunk.toString(); });
    child.once("error", done); child.once("exit", done);
  });
}

async function findCodex(options, deadline) {
  const env = options.env || process.env;
  for (const candidate of [options.codexPath, env.BALANCE_CODEX_PATH, env.CODEX_CLI_PATH, env.CODEX_EXECUTABLE_PATH]) {
    if (existingExecutable(candidate)) return candidate;
  }
  for (const candidate of await runningCodexPaths(Math.max(1, deadline - Date.now()))) {
    if (existingExecutable(candidate)) return candidate;
  }
  const base = env.LOCALAPPDATA && path.join(env.LOCALAPPDATA, "OpenAI", "Codex", "bin");
  if (base) {
    try {
      const paths = fs.readdirSync(base, { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => path.join(base, entry.name, "codex.exe")).filter(existingExecutable);
      paths.sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
      if (paths[0]) return paths[0];
    } catch { /* unavailable installation */ }
  }
  throw safeError("CODEX_NOT_FOUND");
}

async function nativeQuota(options, deadline) {
  const executable = await findCodex(options, deadline);
  const remaining = deadline - Date.now();
  if (remaining <= 0) throw safeError("REQUEST_TIMEOUT");
  return new Promise((resolve, reject) => {
    let child, buffer = "", finished = false;
    const pending = new Map();
    const finish = (error, value) => {
      if (finished) return;
      finished = true; clearTimeout(timer);
      if (child) { child.stdin?.destroy(); child.stdout?.destroy(); child.kill(); }
      if (error) reject(error); else resolve(value);
    };
    const send = (message) => { if (!finished) child.stdin.write(JSON.stringify(message) + "\n"); };
    const call = (id, method, params) => new Promise((done, fail) => { pending.set(id, { done, fail }); send({ id, method, ...(params ? { params } : {}) }); });
    try { child = spawn(executable, ["app-server", "--listen", "stdio://"], { windowsHide: true, stdio: ["pipe", "pipe", "ignore"], env: options.env || process.env }); }
    catch { reject(safeError("CODEX_START_FAILED")); return; }
    const timer = setTimeout(() => finish(safeError("REQUEST_TIMEOUT")), remaining);
    child.once("error", () => finish(safeError("CODEX_START_FAILED")));
    child.once("exit", () => { if (!finished) finish(safeError("CODEX_PROTOCOL")); });
    child.stdin.on("error", () => finish(safeError("CODEX_PROTOCOL")));
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      buffer += chunk;
      if (buffer.length > 1024 * 1024) { finish(safeError("CODEX_PROTOCOL")); return; }
      let index;
      while ((index = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, index); buffer = buffer.slice(index + 1);
        let message; try { message = JSON.parse(line); } catch { continue; }
        const entry = pending.get(message.id);
        if (!entry) continue;
        pending.delete(message.id);
        if (message.error) entry.fail(safeError("CODEX_PROTOCOL")); else entry.done(message.result);
      }
    });
    (async () => {
      await call(0, "initialize", { clientInfo: { name: "balance_pet", title: "Balance Pet", version: "1.0.0" } });
      send({ method: "initialized", params: {} });
      const info = await call(1, "account/read", { refreshToken: false });
      if (info?.account?.type !== "chatgpt") throw safeError("ACCOUNT_MISMATCH");
      const limits = await call(2, "account/rateLimits/read");
      finish(null, limits);
    })().catch((error) => finish(error?.[SAFE_ERROR] ? error : safeError("CODEX_PROTOCOL")));
  });
}

function cleanWindow(value) {
  if (!value || typeof value !== "object") return null;
  const used = Number(value.usedPercent);
  if (value.usedPercent === null || value.usedPercent === undefined || !Number.isFinite(used)) return null;
  return {
    usedPercent: Math.max(0, Math.min(100, used)),
    windowDurationMins: value.windowDurationMins !== null && value.windowDurationMins !== undefined && Number.isFinite(Number(value.windowDurationMins)) ? Number(value.windowDurationMins) : null,
    resetsAt: value.resetsAt !== null && value.resetsAt !== undefined && Number.isFinite(Number(value.resetsAt)) ? Number(value.resetsAt) : null,
  };
}

function cleanBucket(value) {
  if (!value || typeof value !== "object") return null;
  const primary = cleanWindow(value.primary), secondary = cleanWindow(value.secondary);
  if (!primary && !secondary) return null;
  const credits = value.credits && typeof value.credits === "object" ? {
    hasCredits: value.credits.hasCredits === true,
    unlimited: value.credits.unlimited === true,
    balance: typeof value.credits.balance === "string" && /^[0-9]+(?:\.[0-9]+)?$/.test(value.credits.balance) ? value.credits.balance : null,
  } : null;
  return { limitId: typeof value.limitId === "string" ? value.limitId : null, limitName: typeof value.limitName === "string" ? value.limitName : null, primary, secondary, credits, planType: typeof value.planType === "string" ? value.planType : null };
}

function cleanQuota(value) {
  const rateLimitsByLimitId = {};
  if (value?.rateLimitsByLimitId && typeof value.rateLimitsByLimitId === "object") {
    for (const [key, entry] of Object.entries(value.rateLimitsByLimitId)) {
      const bucket = cleanBucket(entry);
      if (bucket) rateLimitsByLimitId[key] = bucket;
    }
  }
  const rateLimits = cleanBucket(value?.rateLimits);
  if (!rateLimits && Object.keys(rateLimitsByLimitId).length === 0) throw safeError("QUOTA_UNAVAILABLE");
  return { rateLimitsByLimitId, rateLimits };
}

async function nativeBalance(account, options, deadline) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(1, deadline - Date.now()));
  try {
    const response = await (options.fetchImpl || fetch)(account.balanceUrl, { headers: { Authorization: "Bearer " + account.key, Accept: "application/json", "User-Agent": "codex-balance-plugin/1.0.0" }, signal: controller.signal });
    if (!response.ok) throw safeError("BALANCE_HTTP", `（HTTP ${Number(response.status) || "未知"}）`);
    let data; try { data = await response.json(); } catch { throw safeError("BALANCE_DATA"); }
    const infos = Array.isArray(data?.balance_infos) ? data.balance_infos : [];
    const clean = infos.filter((entry) => entry && typeof entry.currency === "string" && /^[A-Z]{3}$/.test(entry.currency) && [entry.total_balance, entry.topped_up_balance, entry.granted_balance].every((v) => /^(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$/.test(String(v)))).map((entry) => ({ currency: entry.currency, total_balance: String(entry.total_balance), topped_up_balance: String(entry.topped_up_balance), granted_balance: String(entry.granted_balance) }));
    if (!clean.length || typeof data.is_available !== "boolean") throw safeError("BALANCE_DATA");
    return { is_available: data.is_available, balance_infos: clean };
  } catch (error) {
    if (error?.name === "AbortError") throw safeError("REQUEST_TIMEOUT");
    throw error?.[SAFE_ERROR] ? error : safeError("NETWORK_FAILED");
  } finally { clearTimeout(timer); }
}

export async function readAccountUsage(account = resolveAccount(), options = {}) {
  if (account.errorCode) throw safeError(account.errorCode);
  const deadline = Date.now() + (options.timeoutMs || TIMEOUT_MS);
  let data;
  if (account.kind === "quota") {
    try { data = cleanQuota(await (options.requestRateLimits ? options.requestRateLimits() : nativeQuota(options, deadline))); }
    catch (error) { throw error?.[SAFE_ERROR] ? error : safeError("CODEX_PROTOCOL"); }
  } else if (account.kind === "balance") data = await nativeBalance(account, options, deadline);
  else throw safeError("CONFIG_INVALID");
  const current = account[RECHECK_ACCOUNT]?.();
  if (current && (current.source_id !== account.source_id || current.model !== account.model)) throw safeError("ACCOUNT_CHANGED");
  return { ...publicSource(account), queried_at: new Date().toISOString(), data };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const account = resolveAccount();
  if (process.argv.includes("--source-json")) process.stdout.write(JSON.stringify(publicSource(account)) + "\n");
  else if (process.argv.includes("--json")) {
    try { process.stdout.write(JSON.stringify(await readAccountUsage(account)) + "\n"); }
    catch (error) {
      const current = resolveAccount();
      process.stdout.write(JSON.stringify({ ...publicSource(current), queried_at: new Date().toISOString(), error: error?.[SAFE_ERROR] ? error.message : ERROR_MESSAGES.CODEX_PROTOCOL }) + "\n");
      process.exitCode = 1;
    }
  } else { process.stderr.write("Usage: account.mjs --json | --source-json\n"); process.exitCode = 64; }
}
