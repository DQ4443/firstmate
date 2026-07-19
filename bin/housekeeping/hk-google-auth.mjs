#!/usr/bin/env node
// hk-google-auth.mjs: Google credential helpers for the housekeeping daemon.
//
// Two credential planes, no npm dependencies (builtin fetch + crypto):
//   (a) User OAuth installed-app flow for data scopes (gmail.readonly,
//       drive.readonly). Refresh token persisted in secrets/google-token.json,
//       written back atomically after each refresh.
//   (b) Service-account JWT bearer flow (RS256) for the pubsub scope, keyed
//       from secrets/gcp-sa.json.
//
// Exports getGmailToken() and getPubsubToken(), each returning a bearer access
// token string, plus the lower-level OAuth helpers the watch bootstrap needs.

import { promises as fs } from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { hkPaths, atomicWrite, log } from "./hk-lib.mjs";

export const GMAIL_SCOPES = [
  "https://www.googleapis.com/auth/gmail.readonly",
  "https://www.googleapis.com/auth/drive.readonly",
];
export const PUBSUB_SCOPE = "https://www.googleapis.com/auth/pubsub";
const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";
const DEFAULT_AUTH_URI = "https://accounts.google.com/o/oauth2/v2/auth";

function secretsDir() {
  return hkPaths().secrets;
}

async function readJson(file) {
  return JSON.parse(await fs.readFile(file, "utf8"));
}

// Load the installed-app client config, tolerating both the "installed" and
// "web" wrapper shapes Google emits.
export async function loadOauthClient() {
  const file = path.join(secretsDir(), "google-oauth-client.json");
  const raw = await readJson(file);
  const c = raw.installed || raw.web || raw;
  if (!c.client_id || !c.client_secret) {
    throw new Error("google-oauth-client.json missing client_id/client_secret");
  }
  return {
    clientId: c.client_id,
    clientSecret: c.client_secret,
    authUri: c.auth_uri || DEFAULT_AUTH_URI,
    tokenUri: c.token_uri || DEFAULT_TOKEN_URI,
  };
}

// Build the consent URL for the given redirect URI and scopes.
// access_type=offline + prompt=consent forces a durable refresh token.
export async function buildConsentUrl(redirectUri, scopes = GMAIL_SCOPES) {
  const client = await loadOauthClient();
  const u = new URL(client.authUri);
  u.searchParams.set("client_id", client.clientId);
  u.searchParams.set("redirect_uri", redirectUri);
  u.searchParams.set("response_type", "code");
  u.searchParams.set("scope", scopes.join(" "));
  u.searchParams.set("access_type", "offline");
  u.searchParams.set("prompt", "consent");
  return u.toString();
}

// Exchange an authorization code for tokens and persist the refresh token.
export async function exchangeCode(code, redirectUri) {
  const client = await loadOauthClient();
  const body = new URLSearchParams({
    code,
    client_id: client.clientId,
    client_secret: client.clientSecret,
    redirect_uri: redirectUri,
    grant_type: "authorization_code",
  });
  const res = await fetch(client.tokenUri, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  const data = await res.json();
  if (!res.ok)
    throw new Error(
      `token exchange failed: ${res.status} ${JSON.stringify(data)}`,
    );
  if (!data.refresh_token) {
    throw new Error(
      "no refresh_token returned; revoke prior grant and retry with prompt=consent",
    );
  }
  await persistToken({
    refresh_token: data.refresh_token,
    access_token: data.access_token,
    scope: data.scope,
    token_type: data.token_type,
    expiry: Date.now() + (data.expires_in || 3600) * 1000,
  });
  return data;
}

async function persistToken(token) {
  const file = path.join(secretsDir(), "google-token.json");
  await atomicWrite(file, JSON.stringify(token, null, 2) + "\n", 0o600);
}

async function loadToken() {
  const file = path.join(secretsDir(), "google-token.json");
  return readJson(file);
}

// Return a valid Gmail/Drive access token, refreshing when it is near expiry.
export async function getGmailToken() {
  const client = await loadOauthClient();
  let token;
  try {
    token = await loadToken();
  } catch (err) {
    throw new Error(
      `google-token.json unreadable; run hk-gmail-watch bootstrap first (${err.message})`,
    );
  }
  // Reuse a cached access token while it has more than 60s of life.
  if (
    token.access_token &&
    token.expiry &&
    token.expiry - Date.now() > 60_000
  ) {
    return token.access_token;
  }
  if (!token.refresh_token)
    throw new Error("google-token.json has no refresh_token");

  const body = new URLSearchParams({
    client_id: client.clientId,
    client_secret: client.clientSecret,
    refresh_token: token.refresh_token,
    grant_type: "refresh_token",
  });
  const res = await fetch(client.tokenUri, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  const data = await res.json();
  if (!res.ok)
    throw new Error(
      `token refresh failed: ${res.status} ${JSON.stringify(data)}`,
    );

  const updated = {
    ...token,
    access_token: data.access_token,
    scope: data.scope || token.scope,
    token_type: data.token_type || token.token_type,
    // Google may rotate the refresh token; keep the new one when present.
    refresh_token: data.refresh_token || token.refresh_token,
    expiry: Date.now() + (data.expires_in || 3600) * 1000,
  };
  await persistToken(updated);
  return updated.access_token;
}

function base64url(buf) {
  return Buffer.from(buf).toString("base64url");
}

// Cache the service-account token in memory across calls within one process.
let pubsubCache = { token: null, expiry: 0 };

// Return a service-account bearer token for the pubsub scope, signing a fresh
// RS256 JWT assertion when the cached token is near expiry.
export async function getPubsubToken() {
  if (pubsubCache.token && pubsubCache.expiry - Date.now() > 60_000) {
    return pubsubCache.token;
  }
  const sa = await readJson(path.join(secretsDir(), "gcp-sa.json"));
  if (!sa.client_email || !sa.private_key) {
    throw new Error("gcp-sa.json missing client_email/private_key");
  }
  const tokenUri = sa.token_uri || DEFAULT_TOKEN_URI;
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: sa.client_email,
    scope: PUBSUB_SCOPE,
    aud: tokenUri,
    iat: now,
    exp: now + 3600,
  };
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claims))}`;
  const signature = crypto
    .createSign("RSA-SHA256")
    .update(signingInput)
    .sign(sa.private_key);
  const assertion = `${signingInput}.${base64url(signature)}`;

  const body = new URLSearchParams({
    grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
    assertion,
  });
  const res = await fetch(tokenUri, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  const data = await res.json();
  if (!res.ok)
    throw new Error(
      `pubsub jwt exchange failed: ${res.status} ${JSON.stringify(data)}`,
    );
  pubsubCache = {
    token: data.access_token,
    expiry: Date.now() + (data.expires_in || 3600) * 1000,
  };
  return pubsubCache.token;
}

// Small CLI for manual checks: `hk-google-auth.mjs gmail|pubsub` prints a token.
if (import.meta.url === `file://${process.argv[1]}`) {
  const which = process.argv[2];
  const run = which === "pubsub" ? getPubsubToken : getGmailToken;
  run()
    .then((t) => {
      process.stdout.write(t + "\n");
    })
    .catch((err) => {
      log("hk-google-auth", { status: "error", error: err.message });
      process.exit(1);
    });
}
