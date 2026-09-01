'use strict'

const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')

const {
  assertNoOwnershipCollisions,
  downloadReleaseAsset,
  isDesktopRequest,
  isDesktopUpdateRequest,
  isTrustedDownloadUrl,
  ownedTopLevelEntries,
  removeUpdateTree,
  updateWorkDirectory,
  validateStagedPackage,
} = require('./update-install.js')

function responseFor(payload, url = 'https://release-assets.githubusercontent.com/cedardsh/update.zip') {
  const response = new Response(payload, { status: 200 })
  Object.defineProperty(response, 'url', { value: url })
  return response
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
    fetchImpl: async () => responseFor(payload),
    onProgress: state => progress.push(state),
  })

  assert.deepEqual(fs.readFileSync(destination), payload)
  assert.deepEqual(progress.at(-1), { transferred: payload.length, total: payload.length })
  assert.equal(isTrustedDownloadUrl('https://objects.githubusercontent.com/releases/file'), true)
  assert.equal(isTrustedDownloadUrl('http://github.com/releases/file'), false)
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
  }, destination, { fetchImpl: async () => responseFor(payload) }), /SHA-256 mismatch/u)
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
