import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

describe('electron-builder runtime dependency files', () => {
  it('does not globally exclude node_modules src directories', () => {
    const config = readFileSync('electron-builder.yml', 'utf8')

    expect(config).not.toContain("'!**/node_modules/**/src/**'")
  })

  it('packages the x86 Melodyne drag helper and builds it before packaging', () => {
    const config = readFileSync('electron-builder.yml', 'utf8')
    const packageJson = JSON.parse(readFileSync('package.json', 'utf8')) as {
      scripts: Record<string, string>
    }

    expect(config).toContain('from: native/otto-drag-helper.exe')
    expect(config).toContain('to: native/otto-drag-helper.exe')
    expect(packageJson.scripts.pack).toMatch(/^npm run build:native &&/)
  })

  it('keeps the release private until every update artifact has uploaded', () => {
    const config = readFileSync('electron-builder.yml', 'utf8')
    const workflow = readFileSync('.github/workflows/publish-windows.yml', 'utf8')
    const uploadStep = workflow.indexOf('npm run pack -- --publish always')
    const metadataStep = workflow.indexOf('tauri signer sign')
    const metadataUploadStep = workflow.indexOf('gh release upload')
    const publishStep = workflow.indexOf('gh release edit "${{ github.ref_name }}"')

    expect(config).toContain('releaseType: draft')
    expect(uploadStep).toBeGreaterThan(-1)
    expect(metadataStep).toBeGreaterThan(uploadStep)
    expect(metadataUploadStep).toBeGreaterThan(metadataStep)
    expect(publishStep).toBeGreaterThan(uploadStep)
    expect(publishStep).toBeGreaterThan(metadataUploadStep)
    expect(workflow).toContain('TAURI_SIGNING_PRIVATE_KEY')
    expect(workflow).toContain("Join-Path $releaseDir 'latest.json'")
  })
})
