import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'

import { afterEach, describe, expect, it } from 'vitest'

const verifier = resolve('scripts/verify-tauri-update-artifacts.mjs')
const temporaryDirectories: string[] = []
const publicKeyText = [
  'untrusted comment: minisign public key',
  'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3',
  '',
].join('\n')
const signatureText = [
  'untrusted comment: signature from minisign secret key',
  'RUQf6LRCGA9i559r3g7V1qNyJDApGip8MfqcadIgT9CuhV3EMhHoN1mGTkUidF/z7SrlQgXdy8ofjb7bNJJylDOocrCo8KLzZwo=',
  'trusted comment: timestamp:1633700835\tfile:test\tprehashed',
  'wLMDjy9FLAuxZ3q4NlEvkgtyhrr0gtTu6KC4KBJdITbbOeAi1zBIYo0v4iTgt8jJpIidRJnp94ABQkJAgAooBQ==',
  '',
].join('\n')

afterEach(() => {
  temporaryDirectories.splice(0).forEach((directory) => {
    rmSync(directory, { recursive: true, force: true })
  })
})

function createFixture() {
  const directory = mkdtempSync(join(tmpdir(), 'otto-update-artifacts-'))
  temporaryDirectories.push(directory)
  const installer = join(directory, '_2.6.3_x64-setup.exe')
  const signature = `${installer}.sig`
  const latestJson = join(directory, 'latest.json')
  const latestYml = join(directory, 'latest.yml')
  const tauriConfig = join(directory, 'tauri.conf.json')
  const installerBytes = Buffer.from('test')
  const encodedSignature = Buffer.from(signatureText).toString('base64')
  const url = 'https://github.com/ywb2164/OTTO-sample-manager/releases/download/v2.6.3/_2.6.3_x64-setup.exe'
  const sha512 = createHash('sha512').update(installerBytes).digest('base64')

  writeFileSync(installer, installerBytes)
  writeFileSync(signature, encodedSignature)
  writeFileSync(tauriConfig, JSON.stringify({
    plugins: { updater: { pubkey: Buffer.from(publicKeyText).toString('base64') } },
  }))
  writeFileSync(latestJson, JSON.stringify({
    version: '2.6.3',
    platforms: {
      'windows-x86_64-nsis': { signature: encodedSignature, url },
      'windows-x86_64': { signature: encodedSignature, url },
    },
  }))
  writeFileSync(latestYml, [
    'version: 2.6.3',
    'files:',
    '  - url: _2.6.3_x64-setup.exe',
    `    sha512: ${sha512}`,
    `    size: ${installerBytes.length}`,
    'path: _2.6.3_x64-setup.exe',
    `sha512: ${sha512}`,
    '',
  ].join('\n'))

  return { installer, signature, latestJson, latestYml, tauriConfig }
}

function runVerifier(fixture: ReturnType<typeof createFixture>) {
  return spawnSync(process.execPath, [
    verifier,
    '--installer', fixture.installer,
    '--signature', fixture.signature,
    '--latest-json', fixture.latestJson,
    '--latest-yml', fixture.latestYml,
    '--tauri-config', fixture.tauriConfig,
    '--expected-version', '2.6.3',
  ], { encoding: 'utf8' })
}

describe('Tauri update artifact verifier', () => {
  it('accepts one installer shared by valid Electron and Tauri metadata', () => {
    const result = runVerifier(createFixture())

    expect(result.status).toBe(0)
    expect(JSON.parse(result.stdout)).toMatchObject({
      version: '2.6.3',
      signatureValid: true,
      size: 4,
    })
  })

  it('rejects installer bytes that no longer match the release metadata', () => {
    const fixture = createFixture()
    writeFileSync(fixture.installer, Buffer.concat([
      readFileSync(fixture.installer),
      Buffer.from('tampered'),
    ]))

    const result = runVerifier(fixture)

    expect(result.status).not.toBe(0)
    expect(`${result.stdout}\n${result.stderr}`).toMatch(/SHA-512 mismatch|signature verification failed/i)
  })
})
