import { describe, expect, it, vi } from 'vitest'

import type { Sample, SampleGroup } from '@/types'
import type { DesktopBridge, LibrarySampleRecord } from './desktopBridge'
import { buildLyricsLibraryMutation, loadTauriGroupSamples } from './lyricsLibrary'

function createRecord(index: number, overrides: Partial<LibrarySampleRecord> = {}): LibrarySampleRecord {
  return {
    id: `sample-${index}`,
    folderId: 'source-folder',
    filePath: `D:\\source\\sample-${index}.wav`,
    fileName: `sample-${index}`,
    extension: '.wav',
    originalId: `sample-${index}`,
    isCopy: false,
    copyIndex: 0,
    fileSize: 1024,
    durationMs: 250,
    sampleRate: 44100,
    channels: 2,
    isValid: true,
    importedAt: index,
    groupIds: ['source-group'],
    ...overrides,
  }
}

function createSample(index: number, filePath: string): Sample {
  return {
    id: `generated-${index}`,
    fileName: `${index}_草_cao`,
    fileExt: '.wav',
    filePath,
    folderId: null,
    originalId: `generated-${index}`,
    isCopy: false,
    copyIndex: 0,
    duration: 0.25,
    sampleRate: 44100,
    channels: 2,
    fileSize: 2048,
    groupIds: ['target-group'],
    importedAt: 1000 + index,
    isDecoded: false,
    isFileValid: true,
  }
}

describe('lyrics library integration', () => {
  it('loads every page in a Tauri source group instead of using the detail cache', async () => {
    const records = Array.from({ length: 532 }, (_, index) => createRecord(index))
    records[531] = createRecord(531, { isValid: false })
    const queryPage = vi.fn(async ({ offset = 0, limit = 500 }) => {
      const items = records.slice(offset, offset + limit)
      return {
        items,
        total: records.length,
        offset,
        hasMore: offset + items.length < records.length,
      }
    })
    const desktop = {
      runtime: 'tauri',
      library: { queryPage },
    } as unknown as DesktopBridge

    const samples = await loadTauriGroupSamples(desktop, 'source-group')

    expect(queryPage).toHaveBeenNthCalledWith(1, { groupId: 'source-group', offset: 0, limit: 500 })
    expect(queryPage).toHaveBeenNthCalledWith(2, { groupId: 'source-group', offset: 500, limit: 500 })
    expect(samples).toHaveLength(531)
    expect(samples[0]).toMatchObject({ id: 'sample-0', duration: 0.25, fileExt: '.wav' })
    expect(samples.at(-1)?.id).toBe('sample-530')
  })

  it('builds one atomic batch for the generated group, folder, samples, and ordering', () => {
    const targetDir = 'D:\\OTTO\\lyrics-assemblies\\1979_1234'
    const samples = [
      createSample(1, `${targetDir}\\001_草_cao.wav`),
      createSample(2, `${targetDir}\\002_草_cao.wav`),
    ]
    const group: SampleGroup = {
      id: 'target-group',
      name: '1979',
      color: '#123456',
      sampleIds: samples.map((sample) => sample.id),
    }

    const batch = buildLyricsLibraryMutation({
      group,
      samples,
      targetDir,
      groupOrder: ['source-group'],
      folderOrder: ['source-folder'],
    })

    expect(batch.upsertGroups).toEqual([{ id: 'target-group', name: '1979', color: '#123456', order: 1 }])
    expect(batch.upsertFolders).toEqual([
      expect.objectContaining({
        id: 'folder_D:/OTTO/lyrics-assemblies/1979_1234',
        name: '1979_1234',
        path: 'D:/OTTO/lyrics-assemblies/1979_1234',
      }),
    ])
    expect(batch.upsertSamples).toHaveLength(2)
    expect(batch.upsertSamples[0]).toMatchObject({
      id: 'generated-1',
      folderId: 'folder_D:/OTTO/lyrics-assemblies/1979_1234',
      groupIds: ['target-group'],
      durationMs: 250,
    })
    expect(batch.groupOrder).toEqual(['source-group', 'target-group'])
    expect(batch.folderOrder).toEqual(['folder_D:/OTTO/lyrics-assemblies/1979_1234', 'source-folder'])
    expect(batch.deleteSampleIds).toEqual([])
    expect(batch.deleteFolderIds).toEqual([])
    expect(batch.deleteGroupIds).toEqual([])
  })
})
