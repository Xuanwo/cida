// Writes Cida's release files into the R2 bucket cida-releases for the release workflow
// (docs/development.md, "Releasing"). No stored credential exists anywhere on that path: every
// request carries the OpenID Connect token GitHub Actions issues to the job, and only a token
// issued to Xuanwo/cida's release.yml for a version tag may read the feed or write a file.
//
//   GET /objects/appcast.xml     the current feed, straight from the bucket
//   PUT /objects/<key>           Content-Type, Cache-Control and Content-Disposition are kept

const ISSUER = "https://token.actions.githubusercontent.com";
const AUDIENCE = "cida-releases";
const REPOSITORY = "Xuanwo/cida";
const WORKFLOW_PREFIX = "Xuanwo/cida/.github/workflows/release.yml@";
const TAG_REF = /^refs\/tags\/v\d+\.\d+\.\d+(-rc\.\d+)?$/;
const KEYS = [
  /^appcast\.xml$/,
  /^latest\/Cida\.zip$/,
  /^releases\/\d+\.\d+\.\d+-\d+\/Cida-\d+\.\d+\.\d+-\d+\.zip$/,
];
const KEPT_HEADERS = {
  "content-type": "contentType",
  "cache-control": "cacheControl",
  "content-disposition": "contentDisposition",
};
// Tolerates small clock differences between GitHub and Cloudflare.
const CLOCK_SKEW_SECONDS = 60;

class Rejection extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function decodeBase64URL(text) {
  const base64 = text.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
}

function decodeJSON(text) {
  try {
    return JSON.parse(new TextDecoder().decode(decodeBase64URL(text)));
  } catch {
    throw new Rejection(401, "Malformed token");
  }
}

async function fetchGitHubKeys() {
  const response = await fetch(`${ISSUER}/.well-known/jwks`);
  if (!response.ok) throw new Rejection(503, "GitHub's signing keys are unavailable");
  return (await response.json()).keys;
}

let cachedKeys = null;

/// GitHub's signing keys, fetched again when a token names a key not seen yet (rotation).
async function signingKey(kid, loadKeys) {
  if (!cachedKeys?.some((key) => key.kid === kid)) cachedKeys = await loadKeys();
  const key = cachedKeys.find((candidate) => candidate.kid === kid);
  if (!key) throw new Rejection(401, "Unknown signing key");
  return crypto.subtle.importKey(
    "jwk",
    key,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
}

/// The token's claims when it is a valid GitHub Actions token for Cida's release workflow.
export async function verifyToken(token, { now, loadKeys }) {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Rejection(401, "Malformed token");
  const [encodedHeader, encodedClaims, encodedSignature] = parts;
  const header = decodeJSON(encodedHeader);
  if (header.alg !== "RS256") throw new Rejection(401, "Unexpected signing algorithm");

  const key = await signingKey(header.kid, loadKeys);
  const signed = new TextEncoder().encode(`${encodedHeader}.${encodedClaims}`);
  let signature;
  try {
    signature = decodeBase64URL(encodedSignature);
  } catch {
    throw new Rejection(401, "Malformed token");
  }
  const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, signed);
  if (!valid) throw new Rejection(401, "Invalid signature");

  const claims = decodeJSON(encodedClaims);
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (claims.iss !== ISSUER) throw new Rejection(401, "Wrong issuer");
  if (!audiences.includes(AUDIENCE)) throw new Rejection(401, "Wrong audience");
  if (typeof claims.exp !== "number" || claims.exp + CLOCK_SKEW_SECONDS < now) {
    throw new Rejection(401, "Expired token");
  }
  if (typeof claims.nbf === "number" && claims.nbf - CLOCK_SKEW_SECONDS > now) {
    throw new Rejection(401, "Token not valid yet");
  }
  if (claims.repository !== REPOSITORY) throw new Rejection(403, "Wrong repository");
  if (!String(claims.job_workflow_ref ?? "").startsWith(WORKFLOW_PREFIX)) {
    throw new Rejection(403, "Only the release workflow may publish");
  }
  if (!TAG_REF.test(String(claims.ref ?? ""))) throw new Rejection(403, "Only version tags publish");
  return claims;
}

export async function handle(request, env, options = {}) {
  const now = options.now ?? Math.floor(Date.now() / 1000);
  const loadKeys = options.loadKeys ?? fetchGitHubKeys;
  try {
    const url = new URL(request.url);
    if (!url.pathname.startsWith("/objects/")) throw new Rejection(404, "Not found");
    const key = decodeURIComponent(url.pathname.slice("/objects/".length));
    if (!KEYS.some((pattern) => pattern.test(key))) throw new Rejection(403, "Key not allowed");

    const authorization = request.headers.get("authorization") ?? "";
    if (!authorization.startsWith("Bearer ")) throw new Rejection(401, "Missing token");
    await verifyToken(authorization.slice("Bearer ".length), { now, loadKeys });

    if (request.method === "GET") {
      const object = await env.RELEASES.get(key);
      if (!object) return new Response("Not found", { status: 404 });
      return new Response(object.body, {
        headers: { "content-type": object.httpMetadata?.contentType ?? "application/octet-stream" },
      });
    }
    if (request.method === "PUT") {
      const httpMetadata = {};
      for (const [header, field] of Object.entries(KEPT_HEADERS)) {
        const value = request.headers.get(header);
        if (value) httpMetadata[field] = value;
      }
      await env.RELEASES.put(key, await request.arrayBuffer(), { httpMetadata });
      return new Response(null, { status: 201 });
    }
    throw new Rejection(405, "Method not allowed");
  } catch (error) {
    if (error instanceof Rejection) return new Response(error.message, { status: error.status });
    throw error;
  }
}

export default {
  fetch(request, env) {
    return handle(request, env);
  },
};
