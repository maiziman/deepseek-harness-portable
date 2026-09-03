'use strict'

const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const { EventEmitter } = require('node:events')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { PassThrough, Readable } = require('node:stream')
const test = require('node:test')

const {
  assertNoOwnershipCollisions,
  downloadReleaseAsset,
  extractArchive,
  isDesktopRequest,
  isDesktopUpdateRequest,
  isTrustedDownloadUrl,
  openReleaseAsset,
  ownedTopLevelEntries,
  removeUpdateTree,
  updateWorkDirectory,
  validateStagedPackage,
} = require('./update-install.js')

function tarSpawn(outputs, calls) {
  return (command, args, options) => {
    calls.push({ command, args, options })
    const output = outputs.shift()
    const child = new EventEmitter()
    child.stdout = new PassThrough()
    child.stderr = new PassThrough()
    setImmediate(() => {
      child.stdout.end(output.stdout)
      child.stderr.end(output.stderr || '')
      setImmediate(() => child.emit('close', output.code || 0))
    })
    return child
  }
}

function responseFor(payload) {
  const response = Readable.from([payload])
  response.statusCode = 200
  return response
}

function requestFor(payload, redirectUrl, tracker) {
  return (options) => {
    const request = new EventEmitter()
    request.options = options
    request.setHeader = () => {}
    request.abort = () => { request.aborted = true }
    request.followRedirect = () => queueMicrotask(() => request.emit('response', responseFor(payload)))
    request.end = () => queueMicrotask(() => {
      if (redirectUrl === undefined) request.emit('response', responseFor(payload))
      else request.emit('redirect', 302, 'GET', redirectUrl, {})
    })
    if (tracker !== undefined) tracker.request = request
    return request
  }
}

test('the sidebar request must target the running local DSH origin', () => {
  assert.equal(isDesktopUpdateRequest(
    'http://127.0.0.1:43123/__cedardsh/update',
    'http://127.0.0.1:43123/',
  ), true)
  assert.equal(isDesktopUpdateRequest(
    'http://127.0.0.1:43124/__cedardsh/update',
    'http://127.0.0.1:43123/',
  ), false)
  assert.equal(isDesktopUpdateRequest(
    'http://127.0.0.1:43123/__cedardsh/update?again=1',
    'http://127.0.0.1:43123/',
  ), false)
  assert.equal(isDesktopRequest(
    'http://127.0.0.1:43123/__cedardsh/diagnostics',
    'http://127.0.0.1:43123/',
    '/__cedardsh/diagnostics',
  ), true)
})

test('archive extraction uses Windows tar and reports exact entry progress', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cedardsh-extract-test-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const destination = path.join(directory, 'extract')
  const calls = []
  const progress = []

  await extractArchive('update.zip', destination, {
    tarPath: 'C:\\Windows\\System32\\tar.exe',
    spawnImpl: tarSpawn([
      { stdout: 'CedarDSH-Desktop/\nCedarDSH-Desktop/app/\nCedarDSH-Desktop/app/main.js\n' },
      { stderr: 'CedarDSH-Desktop/\r\nCedarDSH-Desktop/app/\r\nCedarDSH-Desktop/app/main.js\r\n' },
    ], calls),
    onProgress: state => progress.push(state),
  })

  assert.equal(fs.statSync(destination).isDirectory(), true)
  assert.deepEqual(calls.map(call => call.args), [
    ['-tf', 'update.zip'],
    ['-xvf', 'update.zip', '-C', destination],
  ])
  assert.deepEqual(progress, [
    { transferred: 1, total: 3 },
    { transferred: 2, total: 3 },
    { transferred: 3, total: 3 },
  ])
})

test('archive extraction rejects a different listed and extracted entry count', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cedardsh-extract-count-test-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))

  await assert.rejects(extractArchive('update.zip', path.join(directory, 'extract'), {
    tarPath: 'tar.exe',
    spawnImpl: tarSpawn([
      { stdout: 'one\ntwo\n' },
      { stderr: 'one\n' },
    ], []),
    onProgress: () => {},
  }), /entry count mismatch/u)
})

test('asset downloads stay on GitHub and match the published digest and size', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cedardsh-download-test-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const payload = Buffer.from('verified portable update')
  const destination = path.join(directory, 'update.zip')
  const progress = []
  const asset = {
    downloadUrl: 'https://github.com/maiziman/cedardsh-desktop/releases/download/v1.3.0/CedarDSH-Desktop-win64-v1.3.0.zip',
    size: payload.length,
    sha256: crypto.createHash('sha256').update(payload).digest('hex'),
  }

  await downloadReleaseAsset(asset, destination, {
    requestImpl: requestFor(payload, 'https://release-assets.githubusercontent.com/cedardsh/update.zip'),
    onProgress: state => progress.push(state),
  })

  assert.deepEqual(fs.readFileSync(destination), payload)
  assert.deepEqual(progress.at(-1), { transferred: payload.length, total: payload.length })
  assert.equal(isTrustedDownloadUrl('https://objects.githubusercontent.com/releases/file'), true)
  assert.equal(isTrustedDownloadUrl('http://github.com/releases/file'), false)
})

test('asset downloads reject redirects outside GitHub', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cedardsh-download-redirect-test-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const destination = path.join(directory, 'update.zip')
  const tracker = {}
  await assert.rejects(downloadReleaseAsset({
    downloadUrl: 'https://github.com/maiziman/cedardsh-desktop/releases/download/v1.3.2/CedarDSH-Desktop-win64-v1.3.2.zip',
    size: 1,
    sha256: '0'.repeat(64),
  }, destination, {
    requestImpl: requestFor(Buffer.alloc(0), 'https://example.com/update.zip', tracker),
  }), /redirected outside GitHub/u)
  assert.equal(tracker.request.aborted, true)
})

test('asset downloads abort a non-successful HTTP response', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cedardsh-download-http-test-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const tracker = {}
  const requestImpl = () => {
    const request = new EventEmitter()
    const response = responseFor(Buffer.from('unavailable'))
    response.statusCode = 503
    request.setHeader = () => {}
    request.abort = () => { request.aborted = true; response.destroy() }
    request.end = () => queueMicrotask(() => request.emit('response', response))
    tracker.request = request
    return request
  }
  await assert.rejects(downloadReleaseAsset({
    downloadUrl: 'https://github.com/maiziman/cedardsh-desktop/releases/download/v1/update.zip',
    size: 1,
    sha256: '0'.repeat(64),
  }, path.join(directory, 'update.zip'), { requestImpl }), /HTTP 503/u)
  assert.equal(tracker.request.aborted, true)
})

test('asset downloads stop when the GitHub connection does not respond', async () => {
  const requestImpl = () => {
    const request = new EventEmitter()
    request.setHeader = () => {}
    request.abort = () => {}
    request.end = () => {}
    return request
  }
  await assert.rejects(
    openReleaseAsset(requestImpl, 'https://github.com/maiziman/cedardsh-desktop/releases/download/v1/update.zip', 1),
    /connection timed out/u,
  )
})

test('asset downloads stop when an open connection sends no data', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cedardsh-download-idle-test-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const destination = path.join(directory, 'update.zip')
  const requestImpl = () => {
    const request = new EventEmitter()
    const response = new Readable({ read() {} })
    response.statusCode = 200
    request.setHeader = () => {}
    request.followRedirect = () => {}
    request.abort = () => response.destroy(new Error('request aborted'))
    request.end = () => queueMicrotask(() => request.emit('response', response))
    return request
  }
  await assert.rejects(downloadReleaseAsset({
    downloadUrl: 'https://github.com/maiziman/cedardsh-desktop/releases/download/v1/update.zip',
    size: 1,
    sha256: '0'.repeat(64),
  }, destination, { requestImpl, idleTimeoutMs: 1 }), /stalled with no incoming data/u)
  assert.equal(fs.existsSync(destination), false)
  assert.equal(fs.existsSync(`${destination}.partial`), false)
})

test('a digest mismatch leaves no partial download', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cedardsh-download-failure-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const payload = Buffer.from('tampered')
  const destination = path.join(directory, 'update.zip')
  await assert.rejects(downloadReleaseAsset({
    downloadUrl: 'https://github.com/maiziman/cedardsh-desktop/releases/download/v1.3.0/CedarDSH-Desktop-win64-v1.3.0.zip',
    size: payload.length,
    sha256: '0'.repeat(64),
  }, destination, { requestImpl: requestFor(payload) }), /SHA-256 mismatch/u)
  assert.equal(fs.existsSync(destination), false)
  assert.equal(fs.existsSync(`${destination}.partial`), false)
})

test('asset downloads abort when the response exceeds the published size', async (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'cedardsh-download-size-test-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const destination = path.join(directory, 'update.zip')
  const tracker = {}
  await assert.rejects(downloadReleaseAsset({
    downloadUrl: 'https://github.com/maiziman/cedardsh-desktop/releases/download/v1/update.zip',
    size: 1,
    sha256: '0'.repeat(64),
  }, destination, { requestImpl: requestFor(Buffer.from('too large'), undefined, tracker) }), /exceeded the published size/u)
  assert.equal(tracker.request.aborted, true)
  assert.equal(fs.existsSync(destination), false)
  assert.equal(fs.existsSync(`${destination}.partial`), false)
})

test('staged packages own program files but never portable user data', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'cedardsh-stage-test-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  for (const directory of ['dsh-home', 'workspace']) {
    fs.mkdirSync(path.join(root, directory), { recursive: true })
  }
  const requiredFiles = [
    'CedarDSH-Desktop.exe',
    path.join('runtime', 'node.exe'),
    path.join('resources', 'app', 'package.json'),
    path.join('resources', 'app', 'main.js'),
    path.join('resources', 'app', 'startup-progress.js'),
    path.join('resources', 'app', 'launch-args.js'),
    path.join('resources', 'app', 'process-lifecycle.js'),
    path.join('resources', 'app', 'diagnostics.js'),
    path.join('resources', 'app', 'deepseek-mark.svg'),
    path.join('resources', 'app', 'update.js'),
    path.join('resources', 'app', 'update-launcher.ps1'),
    path.join('resources', 'app', 'update-helper.ps1'),
    path.join('resources', 'app', 'update-install.js'),
    path.join('resources', 'app', 'cedardsh.patch.yml'),
    path.join('app', 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js'),
    path.join('app', 'node_modules', '@cedardsh', 'desktop-update', 'package.json'),
    path.join('app', 'node_modules', '@cedardsh', 'desktop-update', 'lib', 'index.js'),
    path.join('app', 'node_modules', '@cedardsh', 'desktop-update', 'lib', 'client.js'),
  ]
  for (const relativePath of requiredFiles) {
    const file = path.join(root, relativePath)
    fs.mkdirSync(path.dirname(file), { recursive: true })
    fs.writeFileSync(file, relativePath)
  }
  const manifest = {
    portableVersion: '1.3.0',
    dshVersion: '0.1.3',
    ownedTopLevelEntries: ['app', 'runtime', 'resources', 'CedarDSH-Desktop.exe', 'manifest.json'],
  }
  fs.writeFileSync(path.join(root, 'manifest.json'), JSON.stringify(manifest))

  assert.deepEqual(validateStagedPackage(root, '1.3.0'), manifest)
  assert.throws(() => ownedTopLevelEntries({
    ...manifest,
    ownedTopLevelEntries: [...manifest.ownedTopLevelEntries, 'dsh-home'],
  }), /must not own updater-preserved entry/u)
  assert.throws(() => ownedTopLevelEntries({
    ...manifest,
    ownedTopLevelEntries: [...manifest.ownedTopLevelEntries, '.cedardsh-update'],
  }), /must not own updater-preserved entry/u)

  fs.rmSync(path.join(root, 'runtime', 'node.exe'))
  assert.throws(
    () => validateStagedPackage(root, '1.3.0'),
    /staged required file is missing: runtime[\\/]node\.exe/u,
  )
})

test('a new package entry cannot replace an existing unowned root item', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'cedardsh-ownership-test-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  fs.writeFileSync(path.join(root, 'new-runtime.dll'), 'user file')
  const current = {
    ownedTopLevelEntries: ['app', 'runtime', 'resources', 'CedarDSH-Desktop.exe', 'manifest.json'],
  }
  const next = {
    ownedTopLevelEntries: [...current.ownedTopLevelEntries, 'new-runtime.dll'],
  }
  assert.throws(
    () => assertNoOwnershipCollisions(root, current, next),
    /replace an unowned top-level entry/u,
  )
  fs.rmSync(path.join(root, 'new-runtime.dll'))
  assert.doesNotThrow(() => assertNoOwnershipCollisions(root, current, next))
})

test('rejected staged links are cleaned without entering their targets', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'cedardsh-link-cleanup-test-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const work = path.join(root, 'work')
  const staged = path.join(work, 'extract', 'CedarDSH-Desktop')
  const external = path.join(root, 'external')
  fs.mkdirSync(staged, { recursive: true })
  fs.mkdirSync(external)
  fs.writeFileSync(path.join(external, 'sentinel.txt'), 'keep')
  fs.symlinkSync(external, path.join(staged, 'external-link'), process.platform === 'win32' ? 'junction' : 'dir')

  assert.throws(() => validateStagedPackage(staged, '1.3.0'), /staged update contains a link/u)
  removeUpdateTree(work)

  assert.equal(fs.existsSync(work), false)
  assert.equal(fs.readFileSync(path.join(external, 'sentinel.txt'), 'utf8'), 'keep')
})

test('update work stays in the versioned application update directory', () => {
  assert.equal(
    updateWorkDirectory('D:\\CedarDSH Desktop', '1.3.0'),
    path.resolve('D:\\CedarDSH Desktop', '.cedardsh-update', '1.3.0'),
  )
  assert.throws(() => updateWorkDirectory('D:\\CedarDSH Desktop', '..\\outside'), /safe for a directory/u)
})
