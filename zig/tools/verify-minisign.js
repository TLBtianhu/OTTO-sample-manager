#!/usr/bin/env node
// 独立校验 minisign 签名（Tauri 的 ED 预哈希变体），不依赖 tauri CLI。
//
//   node verify-minisign.js <public.key> <artifact.sig> <artifact>
//
// 退出码 0 = 签名有效；1 = 无效或参数错。
//
// 为什么自己写：签名文件是 base64 包着的 "untrusted comment + 结构体"，
// 结构体 = 2 字节算法 + 8 字节 key id + 64 字节 Ed25519 签名；
// 算法 "ED" 表示先对内容做 BLAKE2b-512 再签，所以直接对原文件验会失败。
const fs = require('fs');
const crypto = require('crypto');

function fail(message) {
  console.error('verify: ' + message);
  process.exit(1);
}

if (process.argv.length !== 5) {
  fail('用法: node verify-minisign.js <public.key> <artifact.sig> <artifact>');
}

const [, , pubPath, sigPath, filePath] = process.argv;

// 公钥：base64 → "untrusted comment" 两行文本 → 结构体 42 字节（alg + keyid + key）
const pubOuter = Buffer.from(fs.readFileSync(pubPath, 'utf8').trim(), 'base64').toString('utf8');
const pubB64 = pubOuter.split('\n').map((s) => s.trim()).filter(Boolean).pop();
const pub = Buffer.from(pubB64, 'base64');
if (pub.length !== 42) fail('公钥结构体应为 42 字节，实际 ' + pub.length);

const keyId = pub.subarray(2, 10);
const rawKey = pub.subarray(10, 42);
const spki = Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), rawKey]);
const keyObject = crypto.createPublicKey({ key: spki, format: 'der', type: 'spki' });

// 签名：同样的两层 base64，第二行是结构体 74 字节
const sigOuter = Buffer.from(fs.readFileSync(sigPath, 'utf8').trim(), 'base64').toString('utf8');
const sigLines = sigOuter.split('\n').map((s) => s.trim()).filter(Boolean);
const sig = Buffer.from(sigLines[1], 'base64');
if (sig.length !== 74) fail('签名结构体应为 74 字节，实际 ' + sig.length);

const algorithm = sig.subarray(0, 2).toString();
if (!keyId.equals(sig.subarray(2, 10))) fail('key id 不匹配：签名不是这把公钥签的');

const signature = sig.subarray(10, 74);
const data = fs.readFileSync(filePath);

let ok = false;
if (algorithm === 'ED') {
  const digest = crypto.createHash('blake2b512').update(data).digest();
  ok = crypto.verify(null, digest, keyObject, signature);
} else if (algorithm === 'Ed') {
  ok = crypto.verify(null, data, keyObject, signature);
} else {
  fail('未知的签名算法: ' + algorithm);
}

if (!ok) fail('签名无效');

console.log('verify: OK  ' + filePath);
console.log('        algorithm=' + algorithm + '  keyId=' + keyId.toString('hex'));
