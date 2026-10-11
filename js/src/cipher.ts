/**
 * AES-GCM via WebCrypto with a key the host supplies (a Worker secret, a value from a
 * device secure store). The counterpart of TokenLib's KeychainCipher / KeystoreCipher
 * for hosts without a platform keystore of their own.
 */
import type { SecretCipher } from './store';

const te = new TextEncoder();
const td = new TextDecoder();

export const bytes = {
  fromUtf8: (s: string): Uint8Array => te.encode(s),
  toUtf8: (b: Uint8Array): string => td.decode(b),
  toBase64(b: Uint8Array): string {
    let s = '';
    for (const x of b) s += String.fromCharCode(x);
    return btoa(s);
  },
  fromBase64(s: string): Uint8Array {
    const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/'));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  },
};

export class AesGcmCipher implements SecretCipher {
  private key: Promise<CryptoKey>;

  /** `secret` is 16 or 32 bytes (raw or base64 text of them). */
  constructor(secret: Uint8Array | string) {
    const raw = typeof secret === 'string' ? bytes.fromBase64(secret) : secret;
    if (raw.length !== 16 && raw.length !== 32) throw new Error('AesGcmCipher: the key must be 16 or 32 bytes');
    this.key = crypto.subtle.importKey('raw', raw as BufferSource, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
  }

  /** A fresh random key, base64 — what a host puts in its secret store once. */
  static generateSecret(): string {
    return bytes.toBase64(crypto.getRandomValues(new Uint8Array(32)));
  }

  async encrypt(plaintext: Uint8Array): Promise<Uint8Array> {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await this.key, plaintext as BufferSource));
    const out = new Uint8Array(iv.length + ct.length);
    out.set(iv, 0);
    out.set(ct, iv.length);
    return out;
  }

  async decrypt(ciphertext: Uint8Array): Promise<Uint8Array> {
    if (ciphertext.length < 13) throw new Error('AesGcmCipher: ciphertext too short');
    const iv = ciphertext.slice(0, 12);
    const ct = ciphertext.slice(12);
    return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, await this.key, ct as BufferSource));
  }
}
