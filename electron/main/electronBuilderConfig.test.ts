import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

describe('electron-builder runtime dependency files', () => {
  it('does not globally exclude node_modules src directories', () => {
    const config = readFileSync('electron-builder.yml', 'utf8')

    expect(config).not.toContain("'!**/node_modules/**/src/**'")
  })

  it('keeps the Tauri release private until every update artifact has uploaded', () => {
    const workflow = readFileSync('.github/workflows/tauri-windows.yml', 'utf8')
    const uploadStep = workflow.indexOf('gh release upload')
    const publishStep = workflow.indexOf('gh release edit')

    expect(workflow).toContain('releaseDraft: true')
    expect(uploadStep).toBeGreaterThan(-1)
    expect(publishStep).toBeGreaterThan(uploadStep)
  })
})
