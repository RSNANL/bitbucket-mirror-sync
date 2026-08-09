// @ts-check

const encoder = new TextEncoder();

/**
 * @param {string} secret
 * @param {ArrayBuffer} payload
 * @returns {Promise<Uint8Array>}
 */
export async function createHmacSha256(secret, payload) {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const digest = await crypto.subtle.sign("HMAC", key, payload);
  return new Uint8Array(digest);
}

/** @param {string} value */
export function parseBitbucketSignature(value) {
  const match = /^sha256=([a-f0-9]{64})$/i.exec(value.trim());
  if (!match) return null;
  const bytes = new Uint8Array(32);
  for (let index = 0; index < 32; index += 1) {
    bytes[index] = Number.parseInt(match[1].slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

/**
 * @param {Uint8Array} left
 * @param {Uint8Array} right
 */
export function constantTimeEqual(left, right) {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}

/**
 * @param {string} signatureHeader
 * @param {string} secret
 * @param {ArrayBuffer} payload
 */
export async function verifyBitbucketSignature(signatureHeader, secret, payload) {
  const supplied = parseBitbucketSignature(signatureHeader);
  if (!supplied) return false;
  const expected = await createHmacSha256(secret, payload);
  return constantTimeEqual(supplied, expected);
}

/** @param {Uint8Array} bytes */
export function toHex(bytes) {
  return Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join("");
}
