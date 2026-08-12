import { readFileSync } from 'node:fs'

import { describe, expect, it } from 'vitest'

describe('2.6.4 release version contract', () => {
  it('keeps npm, Cargo, Tauri, and release commands on one version', () => {
    const packageJson = JSON.parse(readFileSync('package.json', 'utf8'))
    const tauriConfig = JSON.parse(readFileSync('src-tauri/tauri.conf.json', 'utf8'))
    const cargoToml = readFileSync('src-tauri/Cargo.toml', 'utf8')

    expect(packageJson.version).toBe('2.6.4')
    expect(tauriConfig.version).toBe('2.6.4')
    expect(cargoToml).toMatch(/^version = "2\.6\.4"$/m)
    expect(packageJson.scripts['tauri:verify:release']).toContain('_2.6.4_')
    expect(packageJson.scripts['tauri:verify:release']).toContain('--expected-version 2.6.4')
    expect(packageJson.scripts['tauri:manifests:release']).toContain('_2.6.4_')
    expect(packageJson.scripts['tauri:manifests:release']).toContain('--version 2.6.4')
  })
})
