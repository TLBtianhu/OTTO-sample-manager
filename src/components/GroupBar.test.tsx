import React from 'react'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'

import { useSampleStore } from '@/store/sampleStore'
import type { SampleGroup } from '@/types'
import { GroupBar } from './GroupBar'

function group(id: string): SampleGroup {
  return {
    id,
    name: `Group ${id.toUpperCase()}`,
    color: '#2563eb',
    sampleIds: [],
  }
}

describe('GroupBar', () => {
  beforeAll(() => {
    class TestPointerEvent extends MouseEvent {
      readonly pointerId: number

      constructor(type: string, init: PointerEventInit = {}) {
        super(type, init)
        this.pointerId = init.pointerId ?? 0
      }
    }
    vi.stubGlobal('PointerEvent', TestPointerEvent)
  })

  afterAll(() => {
    vi.unstubAllGlobals()
  })

  beforeEach(() => {
    useSampleStore.setState({
      groups: new Map([
        ['a', group('a')],
        ['b', group('b')],
        ['c', group('c')],
      ]),
      groupOrder: ['a', 'b', 'c'],
      activeGroupId: null,
      libraryRevision: 0,
      lastGroupChangeTimestamp: Date.now(),
    })
  })

  afterEach(() => cleanup())

  it('reorders group tags with pointer events', () => {
    render(<GroupBar />)
    const source = screen.getByRole('button', { name: /Group A/ }).parentElement as HTMLElement
    const target = screen.getByRole('button', { name: /Group C/ }).parentElement as HTMLElement

    fireEvent.pointerDown(source, { pointerId: 1, button: 0, clientX: 10, clientY: 10 })
    fireEvent.pointerMove(source, { pointerId: 1, clientX: 30, clientY: 10 })
    fireEvent.pointerEnter(target, { pointerId: 1, clientX: 100, clientY: 10 })
    fireEvent.pointerUp(target, { pointerId: 1, clientX: 100, clientY: 10 })

    expect(useSampleStore.getState().groupOrder).toEqual(['b', 'a', 'c'])
  })

  it('keeps an ordinary click selecting a group', () => {
    render(<GroupBar />)

    fireEvent.click(screen.getByRole('button', { name: /Group B/ }))

    expect(useSampleStore.getState().activeGroupId).toBe('b')
  })

  it('clears pointer sorting when released outside a group tag', () => {
    render(<GroupBar />)
    const source = screen.getByRole('button', { name: /Group A/ }).parentElement as HTMLElement

    fireEvent.pointerDown(source, { pointerId: 2, button: 0, clientX: 10, clientY: 10 })
    fireEvent.pointerMove(source, { pointerId: 2, clientX: 30, clientY: 10 })
    expect(source.className).toContain('opacity-70')

    fireEvent.pointerUp(window, { pointerId: 2, clientX: 200, clientY: 100 })

    expect(source.className).toContain('opacity-100')
    expect(useSampleStore.getState().groupOrder).toEqual(['a', 'b', 'c'])
  })
})
