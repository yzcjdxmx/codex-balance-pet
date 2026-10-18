import test from "node:test";
import assert from "node:assert/strict";
import { resolveAccount, readAccountUsage } from "../plugin/plugins/balance/account.mjs";

const auth = { auth_mode: "chatgpt", tokens: { account_id: "fixture-account", access_token: "fixture-token" } };
function configured({ provider = "openai_http", endpoint = "https://chatgpt.com/backend-api/codex", requiresAuth = "true", login = auth } = {}) {
  return resolveAccount({ env: {}, auth: login, configText: `model="fixture-model"\nmodel_provider="${provider}"\n[model_providers.${provider}]\nbase_url="${endpoint}"\nrequires_openai_auth=${requiresAuth}\nwire_api="responses"` });
}

test("official HTTP aliases use ChatGPT quota without changing the selected provider", async () => {
  for (const provider of ["openai_http", "my_official_provider"]) {
    const account = configured({ provider });
    assert.equal(account.kind, "quota");
    assert.equal(account.provider, provider);
    assert.equal(account.errorCode, null);
    assert.equal(account.endpoint, "https://chatgpt.com");
    assert.equal(account.key, "");
    let quotaReads = 0;
    const usage = await readAccountUsage(account, {
      requestRateLimits: async () => { quotaReads++; return { rateLimits: { primary: { usedPercent: 12, windowDurationMins: 300 } } }; },
      fetchImpl: async () => { throw new Error("Official aliases must not call a currency balance endpoint"); },
    });
    assert.equal(quotaReads, 1);
    assert.equal(usage.kind, "quota");
    assert.equal(usage.data.rateLimits.primary.usedPercent, 12);
    assert.equal(JSON.stringify(usage).includes("fixture-token"), false);
  }
  assert.equal(configured({ endpoint: "https://chatgpt.com/backend-api/codex/" }).kind, "quota");
});

test("a familiar name or auth flag does not make a third-party endpoint official", () => {
  for (const endpoint of ["https://billing.example/v1", "https://chatgpt.com.example/backend-api/codex", "http://chatgpt.com/backend-api/codex", "https://chatgpt.com:8443/backend-api/codex", "https://chatgpt.com/other", "https://user:password@chatgpt.com/backend-api/codex"]) {
    const account = configured({ endpoint });
    assert.equal(account.kind, "balance", endpoint);
    assert.equal(account.errorCode, "BALANCE_UNSUPPORTED");
  }
  for (const requiresAuth of ["false", '"true"']) {
    assert.equal(configured({ requiresAuth }).kind, "balance");
  }
});

test("official aliases still require a ChatGPT login; API providers keep their balance behavior", () => {
  assert.equal(configured({ login: { auth_mode: "api_key", OPENAI_API_KEY: "fixture-api-key" } }).kind, "balance");
  const deepseek = configured({ endpoint: "https://api.deepseek.com/v1", login: { auth_mode: "api_key", OPENAI_API_KEY: "fixture-api-key" } });
  assert.equal(deepseek.kind, "balance");
  assert.equal(deepseek.balanceUrl, "https://api.deepseek.com/user/balance");
  assert.equal(deepseek.errorCode, null);
  assert.equal(resolveAccount({ env: {}, auth, configText: 'model="fixture-model"' }).kind, "quota");
});
