import { createClient } from "npm:@supabase/supabase-js@2.57.4";

const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";
const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";
const APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys";
const MAXIMUM_REQUEST_BYTES = 16_384;
const MAXIMUM_AUTHORIZATION_CODE_BYTES = 8_192;
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: true });

type AppleTokenResponse = {
  access_token: string;
  refresh_token?: string;
  id_token: string;
};

type AppleIdentityClaims = {
  iss?: unknown;
  aud?: unknown;
  sub?: unknown;
  exp?: unknown;
};

type AppleIdentityHeader = {
  alg?: unknown;
  kid?: unknown;
};

type AppleJSONWebKey = JsonWebKey & {
  alg?: string;
  kid?: string;
  use?: string;
};

let cachedAppleKeys:
  | { expiresAt: number; keys: AppleJSONWebKey[] }
  | undefined;

type RequiredConfiguration = {
  supabaseURL: string;
  serviceRoleKey: string;
  appleTeamID: string;
  appleKeyID: string;
  appleClientID: string;
  applePrivateKey: string;
};

class RequestFailure extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code);
  }
}

Deno.serve(async (request: Request): Promise<Response> => {
  try {
    if (request.method !== "POST") {
      throw new RequestFailure(405, "method_not_allowed");
    }
    if (!request.headers.get("content-type")?.startsWith("application/json")) {
      throw new RequestFailure(415, "unsupported_media_type");
    }

    const configuration = requiredConfiguration();
    const accessToken = bearerToken(request.headers.get("authorization"));
    const authorizationCode = await readAuthorizationCode(request);

    const adminClient = createClient(
      configuration.supabaseURL,
      configuration.serviceRoleKey,
      {
        auth: {
          autoRefreshToken: false,
          detectSessionInUrl: false,
          persistSession: false,
        },
      },
    );
    const { data: userData, error: userError } = await adminClient.auth.getUser(
      accessToken,
    );
    if (userError || !userData.user) {
      throw new RequestFailure(401, "unauthenticated");
    }

    const clientSecret = await makeAppleClientSecret(configuration);
    const appleTokens = await exchangeAppleAuthorizationCode(
      authorizationCode,
      configuration.appleClientID,
      clientSecret,
    );
    const claims = await verifyAppleIdentityToken(appleTokens.id_token);
    guardAppleIdentityMatches(
      claims,
      configuration.appleClientID,
      userData.user.identities ?? [],
    );

    await revokeAppleToken(
      appleTokens.refresh_token ?? appleTokens.access_token,
      appleTokens.refresh_token ? "refresh_token" : "access_token",
      configuration.appleClientID,
      clientSecret,
    );

    const { error: deletionError } = await adminClient.auth.admin.deleteUser(
      userData.user.id,
      false,
    );
    if (deletionError) {
      throw new RequestFailure(503, "deletion_unavailable");
    }

    return jsonResponse(200, { deleted: true });
  } catch (error) {
    if (error instanceof RequestFailure) {
      return jsonResponse(error.status, { error: error.code });
    }
    return jsonResponse(503, { error: "service_unavailable" });
  }
});

function requiredConfiguration(): RequiredConfiguration {
  const configuration: RequiredConfiguration = {
    supabaseURL: requiredEnvironmentValue("SUPABASE_URL"),
    serviceRoleKey: requiredEnvironmentValue("SUPABASE_SERVICE_ROLE_KEY"),
    appleTeamID: requiredEnvironmentValue("APPLE_TEAM_ID"),
    appleKeyID: requiredEnvironmentValue("APPLE_KEY_ID"),
    appleClientID: requiredEnvironmentValue("APPLE_CLIENT_ID"),
    applePrivateKey: requiredEnvironmentValue("APPLE_PRIVATE_KEY").replaceAll(
      "\\n",
      "\n",
    ),
  };

  if (
    !/^https:\/\/[a-z0-9]{8,40}\.supabase\.co\/?$/.test(
      configuration.supabaseURL,
    ) ||
    !/^[A-Z0-9]{10}$/.test(configuration.appleTeamID) ||
    !/^[A-Z0-9]{10}$/.test(configuration.appleKeyID) ||
    configuration.appleClientID.length > 255 ||
    /\s/.test(configuration.appleClientID)
  ) {
    throw new RequestFailure(503, "service_misconfigured");
  }
  return configuration;
}

function requiredEnvironmentValue(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) {
    throw new RequestFailure(503, "service_misconfigured");
  }
  return value;
}

function bearerToken(header: string | null): string {
  const match = header?.match(/^Bearer ([^\s]{1,16384})$/);
  if (!match) {
    throw new RequestFailure(401, "unauthenticated");
  }
  return match[1];
}

async function readAuthorizationCode(request: Request): Promise<string> {
  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (
    Number.isFinite(declaredLength) && declaredLength > MAXIMUM_REQUEST_BYTES
  ) {
    throw new RequestFailure(413, "request_too_large");
  }

  const body = await readBoundedText(
    request,
    MAXIMUM_REQUEST_BYTES,
    new RequestFailure(413, "request_too_large"),
    new RequestFailure(400, "invalid_request"),
  );

  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    throw new RequestFailure(400, "invalid_request");
  }
  if (!isRecord(parsed)) {
    throw new RequestFailure(400, "invalid_request");
  }

  const code = parsed.authorization_code;
  if (
    typeof code !== "string" ||
    code.trim() !== code ||
    code.length === 0 ||
    textEncoder.encode(code).byteLength > MAXIMUM_AUTHORIZATION_CODE_BYTES
  ) {
    throw new RequestFailure(422, "invalid_apple_authorization");
  }
  return code;
}

async function makeAppleClientSecret(
  configuration: RequiredConfiguration,
): Promise<string> {
  const issuedAt = Math.floor(Date.now() / 1000);
  const header = base64URLEncodeJSON({
    alg: "ES256",
    kid: configuration.appleKeyID,
    typ: "JWT",
  });
  const claims = base64URLEncodeJSON({
    iss: configuration.appleTeamID,
    iat: issuedAt,
    exp: issuedAt + 300,
    aud: "https://appleid.apple.com",
    sub: configuration.appleClientID,
  });
  const signingInput = `${header}.${claims}`;
  const privateKey = await importApplePrivateKey(
    configuration.applePrivateKey,
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    privateKey,
    textEncoder.encode(signingInput),
  );
  return `${signingInput}.${base64URLEncode(new Uint8Array(signature))}`;
}

async function importApplePrivateKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  if (!body || !/^[A-Za-z0-9+/=]+$/.test(body)) {
    throw new RequestFailure(503, "service_misconfigured");
  }

  let bytes: Uint8Array;
  try {
    bytes = Uint8Array.from(atob(body), (value) => value.charCodeAt(0));
  } catch {
    throw new RequestFailure(503, "service_misconfigured");
  }
  try {
    return await crypto.subtle.importKey(
      "pkcs8",
      ownedArrayBuffer(bytes),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"],
    );
  } catch {
    throw new RequestFailure(503, "service_misconfigured");
  }
}

async function exchangeAppleAuthorizationCode(
  code: string,
  clientID: string,
  clientSecret: string,
): Promise<AppleTokenResponse> {
  const body = new URLSearchParams({
    client_id: clientID,
    client_secret: clientSecret,
    code,
    grant_type: "authorization_code",
  });

  let response: Response;
  try {
    response = await fetch(APPLE_TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body,
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    throw new RequestFailure(503, "apple_unavailable");
  }
  if (!response.ok) {
    throw new RequestFailure(422, "apple_reauthentication_failed");
  }

  const rawResponse = await readBoundedText(
    response,
    32_768,
    new RequestFailure(503, "apple_invalid_response"),
  );
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawResponse);
  } catch {
    throw new RequestFailure(503, "apple_invalid_response");
  }
  if (
    !isRecord(parsed) ||
    typeof parsed.access_token !== "string" ||
    typeof parsed.id_token !== "string" ||
    (parsed.refresh_token !== undefined &&
      typeof parsed.refresh_token !== "string")
  ) {
    throw new RequestFailure(503, "apple_invalid_response");
  }
  return parsed as AppleTokenResponse;
}

async function verifyAppleIdentityToken(
  identityToken: string,
): Promise<AppleIdentityClaims> {
  const parts = identityToken.split(".");
  if (parts.length !== 3) {
    throw new RequestFailure(503, "apple_invalid_response");
  }

  let header: AppleIdentityHeader;
  let claims: AppleIdentityClaims;
  try {
    const parsedHeader = JSON.parse(
      textDecoder.decode(base64URLDecode(parts[0])),
    );
    const parsedClaims = JSON.parse(
      textDecoder.decode(base64URLDecode(parts[1])),
    );
    if (!isRecord(parsedHeader) || !isRecord(parsedClaims)) {
      throw new Error("invalid claims");
    }
    header = parsedHeader as AppleIdentityHeader;
    claims = parsedClaims as AppleIdentityClaims;
  } catch {
    throw new RequestFailure(503, "apple_invalid_response");
  }

  if (
    header.alg !== "RS256" ||
    typeof header.kid !== "string" ||
    header.kid.length === 0
  ) {
    throw new RequestFailure(503, "apple_invalid_response");
  }

  let keys = await applePublicKeys();
  let key = keys.find(
    (candidate) =>
      candidate.kid === header.kid &&
      candidate.kty === "RSA" &&
      candidate.alg === "RS256" &&
      candidate.use === "sig",
  );
  if (!key) {
    keys = await applePublicKeys(true);
    key = keys.find(
      (candidate) =>
        candidate.kid === header.kid &&
        candidate.kty === "RSA" &&
        candidate.alg === "RS256" &&
        candidate.use === "sig",
    );
  }
  if (!key) {
    throw new RequestFailure(503, "apple_invalid_response");
  }

  let cryptoKey: CryptoKey;
  try {
    cryptoKey = await crypto.subtle.importKey(
      "jwk",
      key,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
  } catch {
    throw new RequestFailure(503, "apple_invalid_response");
  }
  const isValid = await crypto.subtle.verify(
    { name: "RSASSA-PKCS1-v1_5" },
    cryptoKey,
    ownedArrayBuffer(base64URLDecode(parts[2])),
    textEncoder.encode(`${parts[0]}.${parts[1]}`),
  );
  if (!isValid) {
    throw new RequestFailure(422, "apple_reauthentication_failed");
  }
  return claims;
}

async function applePublicKeys(
  forceRefresh = false,
): Promise<AppleJSONWebKey[]> {
  const now = Date.now();
  if (!forceRefresh && cachedAppleKeys && cachedAppleKeys.expiresAt > now) {
    return cachedAppleKeys.keys;
  }

  let response: Response;
  try {
    response = await fetch(APPLE_KEYS_URL, {
      headers: { accept: "application/json" },
      signal: AbortSignal.timeout(10_000),
    });
  } catch {
    throw new RequestFailure(503, "apple_unavailable");
  }
  if (!response.ok) {
    throw new RequestFailure(503, "apple_unavailable");
  }

  const rawResponse = await readBoundedText(
    response,
    65_536,
    new RequestFailure(503, "apple_invalid_response"),
  );
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawResponse);
  } catch {
    throw new RequestFailure(503, "apple_invalid_response");
  }
  if (
    !isRecord(parsed) ||
    !Array.isArray(parsed.keys) ||
    parsed.keys.length === 0 ||
    parsed.keys.length > 20 ||
    !parsed.keys.every(isRecord)
  ) {
    throw new RequestFailure(503, "apple_invalid_response");
  }

  const keys = parsed.keys as AppleJSONWebKey[];
  cachedAppleKeys = { expiresAt: now + 60 * 60 * 1000, keys };
  return keys;
}

function guardAppleIdentityMatches(
  claims: AppleIdentityClaims,
  clientID: string,
  identities: Array<{
    provider?: string;
    provider_id?: string;
    identity_data?: Record<string, unknown>;
  }>,
): void {
  const now = Math.floor(Date.now() / 1000);
  if (
    claims.iss !== "https://appleid.apple.com" ||
    claims.aud !== clientID ||
    typeof claims.sub !== "string" ||
    claims.sub.length === 0 ||
    typeof claims.exp !== "number" ||
    !Number.isFinite(claims.exp) ||
    claims.exp <= now
  ) {
    throw new RequestFailure(422, "apple_reauthentication_failed");
  }

  const appleSubjects = new Set<string>();
  for (const identity of identities) {
    if (identity.provider !== "apple") {
      continue;
    }
    if (typeof identity.provider_id === "string") {
      appleSubjects.add(identity.provider_id);
    }
    const subject = identity.identity_data?.sub;
    if (typeof subject === "string") {
      appleSubjects.add(subject);
    }
  }
  if (!appleSubjects.has(claims.sub)) {
    throw new RequestFailure(403, "apple_account_mismatch");
  }
}

async function revokeAppleToken(
  token: string,
  tokenTypeHint: "refresh_token" | "access_token",
  clientID: string,
  clientSecret: string,
): Promise<void> {
  if (!token || token.length > 16_384) {
    throw new RequestFailure(503, "apple_invalid_response");
  }
  const body = new URLSearchParams({
    client_id: clientID,
    client_secret: clientSecret,
    token,
    token_type_hint: tokenTypeHint,
  });

  let response: Response;
  try {
    response = await fetch(APPLE_REVOKE_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body,
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    throw new RequestFailure(503, "apple_unavailable");
  }
  if (!response.ok) {
    throw new RequestFailure(503, "apple_revocation_failed");
  }
}

function base64URLEncodeJSON(value: Record<string, unknown>): string {
  return base64URLEncode(textEncoder.encode(JSON.stringify(value)));
}

function base64URLEncode(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/g, "");
}

function base64URLDecode(value: string): Uint8Array {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const padded = normalized.padEnd(
    normalized.length + ((4 - (normalized.length % 4)) % 4),
    "=",
  );
  return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
}

function ownedArrayBuffer(value: Uint8Array<ArrayBufferLike>): ArrayBuffer {
  const copy = new Uint8Array(new ArrayBuffer(value.byteLength));
  copy.set(value);
  return copy.buffer;
}

async function readBoundedText(
  source: Request | Response,
  maximumBytes: number,
  oversizedFailure: RequestFailure,
  invalidEncodingFailure = oversizedFailure,
): Promise<string> {
  const declaredLength = Number(source.headers.get("content-length") ?? "0");
  if (Number.isFinite(declaredLength) && declaredLength > maximumBytes) {
    throw oversizedFailure;
  }
  if (!source.body) {
    return "";
  }

  const reader = source.body.getReader();
  const chunks: Uint8Array[] = [];
  let byteCount = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      byteCount += value.byteLength;
      if (byteCount > maximumBytes) {
        try {
          await reader.cancel();
        } catch {
          // The size failure remains authoritative if cancellation also fails.
        }
        throw oversizedFailure;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(byteCount);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return textDecoder.decode(bytes);
  } catch {
    throw invalidEncodingFailure;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function jsonResponse(
  status: number,
  body: Record<string, unknown>,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
    },
  });
}
