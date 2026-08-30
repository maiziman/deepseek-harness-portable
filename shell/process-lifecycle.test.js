'use strict'

const assert = require('node:assert/strict')
const { EventEmitter } = require('node:events')
const test = require('node:test')
const { terminateProcessTree, waitForProcessExit } = require('./process-lifecycle.js')

function childProcess(kill) {
  const child = new EventEmitter()
  child.pid = 31415
  child.exitCode = null
  child.signalCode = null
  child.kill = kill
  return child
}

test('process exit waiting is bounded when a child never exits', async () => {
  const child = childProcess(() => true)
  assert.equal(await waitForProcessExit(child, 5), false)
  assert.equal(child.listenerCount('exit'), 0)
})

test('tree termination reports an exit completed by taskkill', async () => {
  const child = childProcess(() => assert.fail('fallback kill should not run'))
  const execFile = (_file, _args, _options, callback) => {
    child.exitCode = 0
    child.emit('exit', 0)
    callback()
  }
  assert.equal(await terminateProcessTree(child, { execFile, taskkillTimeoutMs: 5, fallbackTimeoutMs: 5 }), true)
})

test('tree termination remains bounded when taskkill and fallback kill do not exit', async () => {
  let fallbackCalls = 0
  const child = childProcess(() => { fallbackCalls += 1; return false })
  const neverReturns = () => undefined
  assert.equal(await terminateProcessTree(child, {
    execFile: neverReturns,
    taskkillTimeoutMs: 5,
    fallbackTimeoutMs: 5,
  }), false)
  assert.equal(fallbackCalls, 1)
  assert.equal(child.listenerCount('exit'), 0)
})

test('fallback kill can complete termination after taskkill returns', async () => {
  const child = childProcess(() => {
    child.signalCode = 'SIGTERM'
    child.emit('exit', null, 'SIGTERM')
    return true
  })
  const execFile = (_file, _args, _options, callback) => callback()
  assert.equal(await terminateProcessTree(child, { execFile, taskkillTimeoutMs: 5, fallbackTimeoutMs: 5 }), true)
})
