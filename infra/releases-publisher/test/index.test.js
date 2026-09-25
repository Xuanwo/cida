import assert from "node:assert/strict";
import { test } from "node:test";

import { handle } from "../src/index.js";

const NOW = 1_790_000_000;

function encode(value) {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : new Uint8Array(value);
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/// A stand-in for GitHub's OIDC issuer: its own RSA key under its own kid.
async function makeIssuer(kid) {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const publicKey = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid, alg: "RS256", use: "sig" };
  return {
    loadKeys: async () => [publicKey],
    async sign(overrides = {}) {
      const claims = {
        iss: "https://token.actions.githubusercontent.com",
        aud: "cida-releases",
        exp: NOW + 300,
        nbf: NOW - 10,
        repository: "Xuanwo/cida",
        job_workflow_ref: "Xuanwo/cida/.github/workflows/release.yml@refs/tags/v1.1.0",
        ref: "refs/tags/v1.1.0",
        ...overrides,
      };
      const body = `${encode(JSON.stringify({ alg: "RS256", kid }))}.${encode(JSON.stringify(claims))}`;
      const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, new TextEncoder().encode(body));
      return `${body}.${encode(signature)}`;
    },
  };
}

function makeBucket() {
  const objects = new Map();
  return {
    objects,
    async get(key) {
      const object = objects.get(key);
      return object && { body: object.body, httpMetadata: object.httpMetadata };
    },
    async put(key, body, { httpMetadata }) {
      objects.set(key, { body: new Uint8Array(body), httpMetadata });
    },
  };
}

async function send(issuer, env, { method = "PUT", key = "appcast.xml", token, body = "<rss/>", headers = {} }) {
  const request = new Request(`https://publisher.example/objects/${key}`, {
    method,
    body: method === "PUT" ? body : undefined,
    headers: { ...(token === null ? {} : { authorization: `Bearer ${token ?? (await issuer.sign())}` }), ...headers },
  });
  return handle(request, env, { now: NOW, loadKeys: issuer.loadKeys });
}

test("the release workflow writes a file with its headers and reads the feed back", async () => {
  const issuer = await makeIssuer("key-1");
  const env = { RELEASES: makeBucket() };

  const put = await send(issuer, env, {
    key: "releases/1.1.0-140/Cida-1.1.0-140.zip",
    body: "zip",
    headers: { "content-type": "application/zip", "cache-control": "public, max-age=31536000, immutable" },
  });
  assert.equal(put.status, 201);
  const stored = env.RELEASES.objects.get("releases/1.1.0-140/Cida-1.1.0-140.zip");
  assert.equal(new TextDecoder().decode(stored.body), "zip");
  assert.deepEqual(stored.httpMetadata, {
    contentType: "application/zip",
    cacheControl: "public, max-age=31536000, immutable",
  });

  await send(issuer, env, { body: "<rss>feed</rss>", headers: { "content-type": "application/xml" } });
  const get = await send(issuer, env, { method: "GET" });
  assert.equal(get.status, 200);
  assert.equal(await get.text(), "<rss>feed</rss>");
});

test("a missing feed reads as 404 so the workflow starts a new one", async () => {
  const issuer = await makeIssuer("key-2");
  const response = await send(issuer, { RELEASES: makeBucket() }, { method: "GET" });
  assert.equal(response.status, 404);
});

test("tokens not issued to Cida's release workflow for a version tag are refused", async () => {
  const issuer = await makeIssuer("key-3");
  const env = { RELEASES: makeBucket() };
  const cases = [
    [{ repository: "someone/cida" }, 403],
    [{ job_workflow_ref: "Xuanwo/cida/.github/workflows/ci.yml@refs/heads/main" }, 403],
    [{ ref: "refs/heads/main" }, 403],
    [{ ref: "refs/tags/v1.1" }, 403],
    [{ aud: "sts.amazonaws.com" }, 401],
    [{ iss: "https://example.com" }, 401],
    [{ exp: NOW - 120 }, 401],
    [{ nbf: NOW + 120 }, 401],
  ];
  for (const [overrides, status] of cases) {
    const response = await send(issuer, env, { token: await issuer.sign(overrides) });
    assert.equal(response.status, status, JSON.stringify(overrides));
  }
  assert.equal(env.RELEASES.objects.size, 0);
});

test("a release candidate tag may publish", async () => {
  const issuer = await makeIssuer("key-4");
  const token = await issuer.sign({ ref: "refs/tags/v1.2.0-rc.1" });
  const response = await send(issuer, { RELEASES: makeBucket() }, { token });
  assert.equal(response.status, 201);
});

test("forged signatures, missing tokens and other keys are refused", async () => {
  const issuer = await makeIssuer("key-5");
  const forger = await makeIssuer("key-5");
  const env = { RELEASES: makeBucket() };

  const forged = await forger.sign();
  assert.equal((await send(issuer, env, { token: forged })).status, 401);
  assert.equal((await send(issuer, env, { token: null })).status, 401);
  assert.equal((await send(issuer, env, { token: "a.b.c" })).status, 401);
  assert.equal((await send(issuer, env, { token: "not-a-jwt" })).status, 401);
  assert.equal((await send(issuer, env, { key: "index.html" })).status, 403);
  // URL parsing already folds a plain "..", so try the encoded form that decodes to one.
  assert.equal((await send(issuer, env, { key: "releases%2F..%2Fappcast.xml" })).status, 403);
  assert.equal((await send(issuer, env, { method: "DELETE" })).status, 405);
  assert.equal(env.RELEASES.objects.size, 0);
});
