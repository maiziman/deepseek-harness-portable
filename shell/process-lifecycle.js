/**
 * Bounded Windows child-process tree termination for the desktop shell.
 * @module process-lifecycle
 */
'use strict'

const { execFile: defaultExecFile } = require('node:child_process')

const terminationByChild = new WeakMap()

/**
 * Test whether a child process has reported its exit.
 *
 * @param {import('node:child_process').ChildProcess} child Child process.
 * @returns {boolean} Whether the child has exited.
 */
function processExited(child) {
  return child.exitCode !== null || child.signalCode !== null
}

/**
 * Wait for a child exit without allowing teardown to hang indefinitely.
 *
 * @param {import('node:child_process').ChildProcess} child Child process.
 * @param {number} timeoutMs Maximum wait in milliseconds.
 * @returns {Promise<boolean>} Whether the child exited before the limit.
 */
function waitForProcessExit(child, timeoutMs) {
  if (processExited(child)) return Promise.resolve(true)
  return new Promise((resolve) => {
    let timer
    const finish = (exited) => {
      child.removeListener('exit', onExit)
      if (timer !== undefined) clearTimeout(timer)
      resolve(exited)
    }
    const onExit = () => finish(true)
    child.once('exit', onExit)
    timer = setTimeout(() => finish(processExited(child)), timeoutMs)
  })
}

/**
 * Terminate a Windows process tree, then use the child's fallback kill.
 *
 * @param {import('node:child_process').ChildProcess} child Child process.
 * @param {{execFile?: typeof defaultExecFile, taskkillTimeoutMs?: number, fallbackTimeoutMs?: number}} [options] Testable process controls.
 * @returns {Promise<boolean>} Whether the child reported an exit.
 */
function terminateProcessTree(child, options = {}) {
  const existing = terminationByChild.get(child)
  if (existing !== undefined) return existing
  const execFile = options.execFile || defaultExecFile
  const taskkillTimeoutMs = options.taskkillTimeoutMs ?? 10_000
  const fallbackTimeoutMs = options.fallbackTimeoutMs ?? 10_000
  const termination = (async () => {
    if (child.pid === undefined || processExited(child)) return true
    await new Promise((resolve) => {
      let settled = false
      let watchdog
      const finish = () => {
        if (settled) return
        settled = true
        if (watchdog !== undefined) clearTimeout(watchdog)
        resolve()
      }
      watchdog = setTimeout(finish, taskkillTimeoutMs)
      try {
        execFile(
          'taskkill',
          ['/PID', String(child.pid), '/T', '/F'],
          { timeout: taskkillTimeoutMs, windowsHide: true },
          finish,
        )
      } catch {
        finish()
      }
    })
    if (processExited(child)) return true
    try { child.kill() } catch { /* taskkill and child exit remain authoritative */ }
    return waitForProcessExit(child, fallbackTimeoutMs)
  })()
  terminationByChild.set(child, termination)
  return termination
}

module.exports = {
  processExited,
  terminateProcessTree,
  waitForProcessExit,
}
