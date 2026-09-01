'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')

const { formatDiagnostics } = require('./diagnostics.js')

test('diagnostics contain only the fixed support fields', () => {
  const report = formatDiagnostics({
    generatedAt: '2026-08-31T12:00:00.000Z',
    portableVersion: '1.3.0',
    dshVersion: '0.1.3',
    nodeVersion: 'v24.19.0',
    electronVersion: '44.0.0',
    windowsVersion: '10.0.26200',
    architecture: 'x64',
    builtAt: '2026-08-31T10:00:00Z',
    lastCheckedAt: null,
    profileInitialized: true,
    serverRunning: true,
    serverLog: { exists: true, size: 824, modifiedAt: '2026-08-31T11:59:00.000Z' },
    apiKey: 'sk-must-never-appear',
    rawLog: 'dsh web: http://127.0.0.1/?token=must-never-appear',
    username: 'Administrator',
    absolutePath: 'C:\\Users\\Administrator\\secret',
  })

  assert.equal(report, [
    'CedarDSH Desktop diagnostics',
    'Generated: 2026-08-31T12:00:00.000Z',
    'CedarDSH Desktop: 1.3.0',
    'Official DeepSeek Harness: 0.1.3',
    'Node runtime: v24.19.0',
    'Electron: 44.0.0',
    'Windows: 10.0.26200 (x64)',
    'Built: 2026-08-31T10:00:00Z',
    'Last update check: never',
    'Web profile: initialized',
    'DSH server: running',
    'Server log: 824 bytes, modified 2026-08-31T11:59:00.000Z',
    'Server log location: dsh-home\\logs\\server.log',
  ].join('\n'))
  assert.doesNotMatch(report, /sk-must-never-appear|token=must-never-appear|Administrator|secret/u)
})
