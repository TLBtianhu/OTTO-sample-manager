import { readFileSync } from 'node:fs'

import { describe, expect, it } from 'vitest'

describe('Windows release workflows', () => {
  it('keeps Electron manual-only and gives Tauri sole tag ownership', () => {
    const legacy = readFileSync('.github/workflows/publish-windows.yml', 'utf8')
    const tauri = readFileSync('.github/workflows/tauri-windows.yml', 'utf8')

    expect(legacy).not.toMatch(/^\s*push:\s*$/m)
    expect(legacy).toMatch(/^\s*workflow_dispatch:\s*$/m)
    expect(tauri).toContain("tags:\n      - 'v*'")
    expect(tauri).toContain('npm run tauri:manifests:release')
    expect(tauri).toContain('npm run tauri:verify:update-artifacts')
    expect(tauri).toContain('gh release upload')
    expect(tauri).toContain('gh release edit')
  })
})
