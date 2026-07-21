import React, { useState } from 'react'
import { Check, Edit3, Plus, Trash2, X } from 'lucide-react'
import { useSampleStore } from '@/store/sampleStore'
import { v4 as uuidv4 } from 'uuid'

export const GroupBar: React.FC = () => {
  const groupBarRef = React.useRef<HTMLDivElement>(null)
  const groups = useSampleStore((state) => state.groups)
  const groupOrder = useSampleStore((state) => state.groupOrder)
  const activeGroupId = useSampleStore((state) => state.activeGroupId)
  const setActiveGroupId = useSampleStore((state) => state.setActiveGroupId)
  const addGroup = useSampleStore((state) => state.addGroup)
  const renameGroup = useSampleStore((state) => state.renameGroup)
  const removeGroup = useSampleStore((state) => state.removeGroup)
  const moveGroup = useSampleStore((state) => state.moveGroup)

  const [isCreatingGroup, setIsCreatingGroup] = useState(false)
  const [newGroupName, setNewGroupName] = useState('')
  const [editingGroupId, setEditingGroupId] = useState<string | null>(null)
  const [editingGroupName, setEditingGroupName] = useState('')
  const [contextMenu, setContextMenu] = useState<{groupId: string; x: number; y: number} | null>(null)
  const [dragOverGroupId, setDragOverGroupId] = useState<string | null>(null)
  const pointerDragRef = React.useRef<{
    pointerId: number
    groupId: string
    startX: number
    startY: number
    active: boolean
  } | null>(null)
  const suppressClickRef = React.useRef(false)
  const suppressClickTimerRef = React.useRef<number | null>(null)

  const orderedGroups = React.useMemo(() => {
    const seen = new Set<string>()
    const result = groupOrder.flatMap((groupId) => {
      const group = groups.get(groupId)
      if (!group || seen.has(group.id)) return []
      seen.add(group.id)
      return [group]
    })

    groups.forEach((group) => {
      if (!seen.has(group.id)) {
        result.push(group)
      }
    })

    return result
  }, [groupOrder, groups])

  const handleSelectGroup = (groupId: string | null) => {
    if (suppressClickRef.current) {
      suppressClickRef.current = false
      return
    }
    setActiveGroupId(groupId)
  }

  const handleCreateGroup = () => {
    if (!newGroupName.trim()) return

    const newGroup = {
      id: uuidv4(),
      name: newGroupName.trim(),
      color: `#${Math.floor(Math.random() * 16777215).toString(16).padStart(6, '0')}`,
      sampleIds: []
    }

    addGroup(newGroup)
    setNewGroupName('')
    setIsCreatingGroup(false)
    setActiveGroupId(newGroup.id)
  }

  const handleStartEdit = (groupId: string, currentName: string) => {
    setEditingGroupId(groupId)
    setEditingGroupName(currentName)
  }

  const handleSaveEdit = () => {
    if (editingGroupId && editingGroupName.trim()) {
      renameGroup(editingGroupId, editingGroupName.trim())
    }
    setEditingGroupId(null)
    setEditingGroupName('')
  }

  const handleDeleteGroup = (groupId: string) => {
    const group = groups.get(groupId)
    if (!group) return

    if (group.sampleIds.length > 0) {
      const confirmed = window.confirm(
        `分组 "${group.name}" 中包含 ${group.sampleIds.length} 个样本。确定要删除这个分组吗？\n分组删除后，样本不会被删除，只会从分组中移除。`
      )
      if (!confirmed) return
    } else {
      const confirmed = window.confirm(`确定要删除分组 "${group.name}" 吗？`)
      if (!confirmed) return
    }

    removeGroup(groupId)
    if (activeGroupId === groupId) {
      setActiveGroupId(null)
    }
  }

  const handleGroupContextMenu = (e: React.MouseEvent, groupId: string) => {
    e.preventDefault()
    e.stopPropagation()
    setContextMenu({
      groupId,
      x: e.clientX,
      y: e.clientY
    })
  }

  const handleGroupPointerDown = (e: React.PointerEvent, groupId: string) => {
    if (e.button !== 0 || editingGroupId === groupId) return
    pointerDragRef.current = {
      pointerId: e.pointerId,
      groupId,
      startX: e.clientX,
      startY: e.clientY,
      active: false,
    }
  }

  const updateGroupPointerDrag = (e: React.PointerEvent, targetGroupId: string) => {
    const drag = pointerDragRef.current
    if (!drag || drag.pointerId !== e.pointerId) return false

    if (!drag.active && (
      targetGroupId !== drag.groupId
      || Math.hypot(e.clientX - drag.startX, e.clientY - drag.startY) >= 6
    )) {
      drag.active = true
    }
    if (drag.active) {
      e.preventDefault()
      setDragOverGroupId(targetGroupId)
    }
    return drag.active
  }

  const handleGroupPointerUp = (e: React.PointerEvent, targetGroupId: string) => {
    const drag = pointerDragRef.current
    if (!drag || drag.pointerId !== e.pointerId) return

    const wasDragging = updateGroupPointerDrag(e, targetGroupId)
    pointerDragRef.current = null
    setDragOverGroupId(null)
    if (!wasDragging) return

    suppressClickRef.current = true
    if (suppressClickTimerRef.current !== null) window.clearTimeout(suppressClickTimerRef.current)
    suppressClickTimerRef.current = window.setTimeout(() => {
      suppressClickRef.current = false
      suppressClickTimerRef.current = null
    }, 0)
    if (drag.groupId !== targetGroupId) {
      moveGroup(drag.groupId, targetGroupId)
    }
  }

  React.useEffect(() => {
    const cancelPointerDrag = () => {
      pointerDragRef.current = null
      setDragOverGroupId(null)
    }
    const handleWindowPointerMove = (event: PointerEvent) => {
      const drag = pointerDragRef.current
      if (!drag || drag.pointerId !== event.pointerId) return
      if (!drag.active && Math.hypot(event.clientX - drag.startX, event.clientY - drag.startY) >= 6) {
        drag.active = true
      }
      if (!drag.active) return

      const container = groupBarRef.current
      const bounds = container?.getBoundingClientRect()
      if (container && bounds && bounds.width > 0 && typeof container.scrollBy === 'function') {
        if (event.clientX < bounds.left + 32) container.scrollBy({ left: -24 })
        if (event.clientX > bounds.right - 32) container.scrollBy({ left: 24 })
      }

      const target = document.elementFromPoint?.(event.clientX, event.clientY)
        ?.closest<HTMLElement>('[data-group-id]')
      if (target?.dataset.groupId) setDragOverGroupId(target.dataset.groupId)
    }
    const handleWindowPointerUp = (event: PointerEvent) => {
      const drag = pointerDragRef.current
      if (drag && drag.pointerId === event.pointerId) cancelPointerDrag()
    }
    window.addEventListener('pointermove', handleWindowPointerMove)
    window.addEventListener('pointerup', handleWindowPointerUp)
    window.addEventListener('pointercancel', cancelPointerDrag)
    window.addEventListener('blur', cancelPointerDrag)
    return () => {
      window.removeEventListener('pointermove', handleWindowPointerMove)
      window.removeEventListener('pointerup', handleWindowPointerUp)
      window.removeEventListener('pointercancel', cancelPointerDrag)
      window.removeEventListener('blur', cancelPointerDrag)
      if (suppressClickTimerRef.current !== null) window.clearTimeout(suppressClickTimerRef.current)
    }
  }, [])

  const handleEditFromContextMenu = (groupId: string) => {
    const group = groups.get(groupId)
    if (group) {
      handleStartEdit(groupId, group.name)
    }
    setContextMenu(null)
  }

  const handleDeleteFromContextMenu = (groupId: string) => {
    handleDeleteGroup(groupId)
    setContextMenu(null)
  }

  // 点击外部关闭上下文菜单
  React.useEffect(() => {
    const handleClickOutside = () => {
      setContextMenu(null)
    }
    document.addEventListener('click', handleClickOutside)
    return () => {
      document.removeEventListener('click', handleClickOutside)
    }
  }, [])

  return (
    <div ref={groupBarRef} className="border-b border-white/5 bg-zinc-950 px-3 py-2 overflow-x-auto overflow-y-hidden">
      <div className="flex min-w-max items-center gap-2 whitespace-nowrap">
        <button
          onClick={() => handleSelectGroup(null)}
          className={`shrink-0 rounded-md border px-3 py-1.5 text-xs font-medium transition-colors whitespace-nowrap ${
            activeGroupId === null
              ? 'border-blue-500/35 bg-blue-500/10 text-blue-300'
              : 'border-white/5 bg-transparent text-zinc-300 hover:bg-white/[0.035] hover:text-zinc-100'
          }`}
        >
          全部
        </button>

        {orderedGroups.map((group) => (
          <div
            key={group.id}
            data-group-id={group.id}
            className={`relative shrink-0 select-none transition-opacity ${dragOverGroupId === group.id ? 'opacity-70' : 'opacity-100'}`}
            onPointerDown={(e) => handleGroupPointerDown(e, group.id)}
            onPointerMove={(e) => updateGroupPointerDrag(e, group.id)}
            onPointerEnter={(e) => updateGroupPointerDrag(e, group.id)}
            onPointerUp={(e) => handleGroupPointerUp(e, group.id)}
          >
            {editingGroupId === group.id ? (
              <div className="flex shrink-0 items-center gap-1">
                <input
                  type="text"
                  value={editingGroupName}
                  onChange={(e) => setEditingGroupName(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') handleSaveEdit()
                    if (e.key === 'Escape') {
                      setEditingGroupId(null)
                      setEditingGroupName('')
                    }
                  }}
                  className="h-8 rounded-md border border-white/10 bg-zinc-900/60 px-3 text-xs text-zinc-100 outline-none focus:border-blue-500/45"
                  autoFocus
                />
                <button
                  onClick={handleSaveEdit}
                  className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-blue-600 text-white transition-colors hover:bg-blue-500"
                  title="保存"
                >
                  <Check size={14} />
                </button>
                <button
                  onClick={() => {
                    setEditingGroupId(null)
                    setEditingGroupName('')
                  }}
                  className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-white/5 bg-transparent text-zinc-300 transition-colors hover:bg-white/5 hover:text-zinc-100"
                  title="取消"
                >
                  <X size={14} />
                </button>
              </div>
            ) : (
              <button
                onClick={() => handleSelectGroup(group.id)}
                onContextMenu={(e) => handleGroupContextMenu(e, group.id)}
                className={`inline-flex shrink-0 items-center gap-2 rounded-md border px-3 py-1.5 text-xs font-medium transition-colors whitespace-nowrap ${
                  activeGroupId === group.id
                    ? 'border-blue-500/35 bg-blue-500/10 text-blue-300'
                    : 'border-white/5 bg-transparent text-zinc-300 hover:bg-white/[0.035] hover:text-zinc-100'
                }`}
              >
                <span className="h-2 w-2 rounded-full border border-white/20" style={{ backgroundColor: group.color }} />
                <span>{group.name}</span>
                <span className="font-mono text-[11px] text-zinc-400">{group.sampleIds.length}</span>
              </button>
            )}
          </div>
        ))}

        {isCreatingGroup ? (
          <div className="flex shrink-0 items-center gap-1">
            <input
              type="text"
              value={newGroupName}
              onChange={(e) => setNewGroupName(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') handleCreateGroup()
                if (e.key === 'Escape') {
                  setIsCreatingGroup(false)
                  setNewGroupName('')
                }
              }}
              placeholder="分组名称"
              className="h-8 rounded-md border border-white/10 bg-zinc-900/60 px-3 text-xs text-zinc-100 outline-none placeholder:text-zinc-400 focus:border-blue-500/45"
              autoFocus
            />
            <button
              onClick={handleCreateGroup}
              className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-blue-600 text-white transition-colors hover:bg-blue-500"
              title="创建"
            >
              <Check size={14} />
            </button>
            <button
              onClick={() => {
                setIsCreatingGroup(false)
                setNewGroupName('')
              }}
              className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-white/5 bg-transparent text-zinc-300 transition-colors hover:bg-white/5 hover:text-zinc-100"
              title="取消"
            >
              <X size={14} />
            </button>
          </div>
        ) : (
          <button
            onClick={() => setIsCreatingGroup(true)}
            className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-white/5 bg-transparent text-zinc-300 transition-colors hover:bg-white/5 hover:text-zinc-100"
            title="新建分组"
          >
            <Plus size={15} />
          </button>
        )}
      </div>

      {/* 右键菜单 */}
      {contextMenu && (
        <div
          className="fixed z-[100] min-w-[160px] rounded-lg border border-white/5 bg-zinc-950/95 py-1.5 shadow-lg shadow-black/30 backdrop-blur-xl"
          style={{
            left: `${contextMenu.x}px`,
            top: `${contextMenu.y}px`,
          }}
          onClick={(e) => e.stopPropagation()}
        >
          <button
            className="flex w-full items-center gap-2 px-3 py-2 text-left text-xs text-text-primary transition-colors hover:bg-bg-hover"
            onClick={() => handleEditFromContextMenu(contextMenu.groupId)}
          >
            <Edit3 size={14} />
            <span>重命名</span>
          </button>
          <button
            className="flex w-full items-center gap-2 px-3 py-2 text-left text-xs text-red-300 transition-colors hover:bg-red-500/10"
            onClick={() => handleDeleteFromContextMenu(contextMenu.groupId)}
          >
            <Trash2 size={14} />
            <span>删除</span>
          </button>
        </div>
      )}
    </div>
  )
}
