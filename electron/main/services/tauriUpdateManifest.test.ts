import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { spawnSync } from 'node:child_process'

import { afterEach, describe, expect, it } from 'vitest'

const generator = resolve('scripts/generate-tauri-update-manifests.mjs')
const temporaryDirectories: string[] = []

afterEach(() => {
  temporaryDirectories.splice(0).forEach((directory) => {
    rmSync(directory, { recursive: true, force: true })
  })
})

describe('Tauri update manifest generator', () => {
  it('writes matching Electron and Tauri updater metadata for one signed installer', () => {
    const directory = mkdtempSync(join(tmpdir(), 'otto-update-manifest-'))
    temporaryDirectories.push(directory)
    const installer = join(directory, '采样管理器_2.6.2_x64-setup.exe')
    const signature = `${installer}.sig`
    const installerBytes = Buffer.from('signed tauri installer fixture')
    writeFileSync(installer, installerBytes)
    writeFileSync(signature, 'encoded-minisign-signature')

    const result = spawnSync(process.execPath, [
      generator,
      '--installer', installer,
      '--signature', signature,
      '--version', '2.6.2',
      '--asset-name', '_2.6.2_x64-setup.exe',
      '--repository', 'ywb2164/OTTO-sample-manager',
      '--release-date', '2026-07-21T12:00:00.000Z',
      '--notes', 'Fix lyrics generation.',
      '--output-dir', directory,
    ], { encoding: 'utf8' })

    expect(result.status).toBe(0)
    const expectedSha512 = createHash('sha512').update(installerBytes).digest('base64')
    const latestJson = JSON.parse(readFileSync(join(directory, 'latest.json'), 'utf8'))
    expect(latestJson).toEqual({
      version: '2.6.2',
      notes: 'Fix lyrics generation.',
      pub_date: '2026-07-21T12:00:00.000Z',
      platforms: {
        'windows-x86_64-nsis': {
          signature: 'encoded-minisign-signature',
          url: 'https://github.com/ywb2164/OTTO-sample-manager/releases/download/v2.6.2/_2.6.2_x64-setup.exe',
        },
        'windows-x86_64': {
          signature: 'encoded-minisign-signature',
          url: 'https://github.com/ywb2164/OTTO-sample-manager/releases/download/v2.6.2/_2.6.2_x64-setup.exe',
        },
      },
    })
    expect(readFileSync(join(directory, '_2.6.2_x64-setup.exe'))).toEqual(installerBytes)
    expect(readFileSync(join(directory, '_2.6.2_x64-setup.exe.sig'), 'utf8')).toBe('encoded-minisign-signature')

    const latestYml = readFileSync(join(directory, 'latest.yml'), 'utf8')
    expect(latestYml).toContain('version: 2.6.2')
    expect(latestYml).toContain('url: _2.6.2_x64-setup.exe')
    expect(latestYml).toContain(`sha512: ${expectedSha512}`)
    expect(latestYml).toContain(`size: ${installerBytes.length}`)
    expect(latestYml).toContain("releaseDate: '2026-07-21T12:00:00.000Z'")
  })
})
