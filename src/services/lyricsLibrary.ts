import type { Sample, SampleGroup } from '@/types'
import type {
  DesktopBridge,
  LibraryMutationBatch,
  LibrarySampleRecord,
} from './desktopBridge'

const LYRICS_SOURCE_PAGE_SIZE = 500

function toSample(record: LibrarySampleRecord): Sample {
  return {
    id: record.id,
    fileName: record.fileName,
    fileExt: record.extension,
    filePath: record.filePath,
    folderId: record.folderId,
    originalId: record.originalId,
    isCopy: record.isCopy,
    copyIndex: record.copyIndex,
    duration: (record.durationMs ?? 0) / 1000,
    sampleRate: record.sampleRate ?? 0,
    channels: record.channels ?? 0,
    fileSize: record.fileSize,
    groupIds: [...record.groupIds],
    importedAt: record.importedAt,
    isDecoded: false,
    isFileValid: record.isValid,
  }
}

function toSampleRecord(sample: Sample, folderId: string): LibrarySampleRecord {
  return {
    id: sample.id,
    folderId,
    filePath: sample.filePath,
    fileName: sample.fileName,
    extension: sample.fileExt,
    originalId: sample.originalId,
    isCopy: sample.isCopy,
    copyIndex: sample.copyIndex,
    fileSize: sample.fileSize,
    durationMs: sample.duration > 0 ? Math.round(sample.duration * 1000) : null,
    sampleRate: sample.sampleRate > 0 ? sample.sampleRate : null,
    channels: sample.channels > 0 ? sample.channels : null,
    isValid: sample.isFileValid,
    importedAt: sample.importedAt,
    groupIds: [...sample.groupIds],
  }
}

function normalizePath(path: string): string {
  return path.replace(/\\/g, '/').replace(/\/$/, '')
}

function parentPath(path: string): string {
  const normalized = normalizePath(path)
  const separator = normalized.lastIndexOf('/')
  return separator < 0 ? '' : normalized.slice(0, separator)
}

function appendUnique(values: string[], value: string): string[] {
  return [...values.filter((item) => item !== value), value]
}

export async function loadTauriGroupSamples(
  desktop: DesktopBridge,
  groupId: string,
): Promise<Sample[]> {
  const records: LibrarySampleRecord[] = []
  let offset = 0

  while (true) {
    const page = await desktop.library.queryPage({
      groupId,
      offset,
      limit: LYRICS_SOURCE_PAGE_SIZE,
    })
    records.push(...page.items)

    if (!page.hasMore) break
    const nextOffset = page.offset + page.items.length
    if (page.items.length === 0 || nextOffset <= offset) {
      throw new Error('源声库分页读取未能继续，请重新打开软件后再试。')
    }
    offset = nextOffset
  }

  return records.filter((record) => record.isValid).map(toSample)
}

export interface LyricsLibraryMutationInput {
  group: SampleGroup
  samples: Sample[]
  targetDir: string
  groupOrder: string[]
  folderOrder: string[]
}

export function buildLyricsLibraryMutation({
  group,
  samples,
  targetDir,
  groupOrder,
  folderOrder,
}: LyricsLibraryMutationInput): LibraryMutationBatch {
  const folderPath = normalizePath(targetDir || parentPath(samples[0]?.filePath ?? ''))
  if (!folderPath) {
    throw new Error('无法确定活字印刷输出目录。')
  }
  const folderId = `folder_${folderPath}`
  const nextGroupOrder = appendUnique(groupOrder, group.id)
  const nextFolderOrder = [folderId, ...folderOrder.filter((id) => id !== folderId)]
  const importedAt = Math.min(...samples.map((sample) => sample.importedAt))

  return {
    upsertSamples: samples.map((sample) => toSampleRecord(sample, folderId)),
    deleteSampleIds: [],
    upsertFolders: [{
      id: folderId,
      parentId: null,
      name: folderPath.split('/').pop() || '活字印刷',
      path: folderPath,
      rootId: folderId,
      depth: 0,
      order: 0,
      isExpanded: false,
      importedAt,
    }],
    deleteFolderIds: [],
    upsertGroups: [{
      id: group.id,
      name: group.name,
      color: group.color,
      order: nextGroupOrder.indexOf(group.id),
    }],
    deleteGroupIds: [],
    folderOrder: nextFolderOrder,
    groupOrder: nextGroupOrder,
  }
}
