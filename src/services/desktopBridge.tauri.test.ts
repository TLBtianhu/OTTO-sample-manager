import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  invoke: vi.fn(),
  check: vi.fn(),
}))

vi.mock('@tauri-apps/api/core', () => ({
  invoke: mocks.invoke,
  isTauri: vi.fn(() => true),
}))
vi.mock('@tauri-apps/plugin-dialog', () => ({ open: vi.fn() }))
vi.mock('@tauri-apps/plugin-opener', () => ({ openUrl: vi.fn(), revealItemInDir: vi.fn() }))
vi.mock('@tauri-apps/plugin-updater', () => ({ check: mocks.check }))
vi.mock('@tauri-apps/api/event', () => ({ listen: vi.fn() }))
vi.mock('@tauri-apps/api/window', () => ({
  getCurrentWindow: vi.fn(() => ({ onDragDropEvent: vi.fn() })),
}))

import { createTauriDesktopBridge } from './desktopBridge'

describe('createTauriDesktopBridge updater', () => {
  beforeEach(() => {
    mocks.invoke.mockReset().mockResolvedValue('2.6.1')
    mocks.check.mockReset()
  })

  it('reports installation failures through state without rejecting the UI action', async () => {
    const failure = new Error('signature download failed')
    const update = {
      version: '2.6.2',
      close: vi.fn().mockResolvedValue(undefined),
      downloadAndInstall: vi.fn().mockRejectedValue(failure),
    }
    mocks.check.mockResolvedValue(update)
    const bridge = createTauriDesktopBridge()
    const states = [] as Awaited<ReturnType<typeof bridge.updater.getState>>[]
    bridge.updater.onState((state) => states.push({ ...state }))

    await bridge.updater.check()
    await expect(bridge.updater.start()).resolves.toBeUndefined()

    expect(states.at(-1)).toMatchObject({
      phase: 'error',
      progressPercent: null,
      message: 'signature download failed',
      action: 'download-and-restart',
    })
  })
})
