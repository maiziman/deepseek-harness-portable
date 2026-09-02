'use strict'

const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')
const { Transform } = require('node:stream')
const { pipeline } = require('node:stream/promises')

const UPDATE_REQUEST_PATH = '/__cedardsh/update'
const UPDATE_DIRECTORY = '.cedardsh-update'
const DOWNLOAD_CONNECTION_TIMEOUT_MS = 30 * 1000
const DOWNLOAD_IDLE_TIMEOUT_MS = 120 * 1000
const MAX_DOWNLOAD_REDIRECTS = 5
const PRESERVED_ENTRIES = new Set(['dsh-home', 'workspace'])
const REQUIRED_OWNED_ENTRIES = [
  'app',
  'runtime',
  'resources',
  'CedarDSH-Desktop.exe',
  'manifest.json',
]
const REQUIRED_PACKAGE_FILES = [
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

/** Return whether a resolved GitHub asset URL is an HTTPS download endpoint. */
function isTrustedDownloadUrl(value) {
  if (typeof value !== 'string') return false
  try {
    const url = new URL(value)
    return url.protocol === 'https:'
      && (url.hostname === 'github.com' || url.hostname.endsWith('.githubusercontent.com'))
  } catch {
    return false
  }
}

/** Match one exact local browser request emitted by a CedarDSH desktop action. */
function isDesktopRequest(requestUrl, serverUrl, requestPath) {
  try {
    const request = new URL(requestUrl)
    const server = new URL(serverUrl)
    return request.origin === server.origin
      && request.pathname === requestPath
      && request.search === ''
      && request.hash === ''
  } catch {
    return false
  }
}

/** Match the local browser request emitted by the CedarDSH update action. */
function isDesktopUpdateRequest(requestUrl, serverUrl) {
  return isDesktopRequest(requestUrl, serverUrl, UPDATE_REQUEST_PATH)
}

/** Resolve one version-scoped staging directory inside the portable root. */
function updateWorkDirectory(root, version) {
  if (typeof root !== 'string' || root.length === 0) throw new TypeError('root must be a non-empty string')
  if (typeof version !== 'string' || !/^[0-9A-Za-z.+-]+$/u.test(version)) {
    throw new TypeError('version must be safe for a directory name')
  }
  const base = path.resolve(root, UPDATE_DIRECTORY)
  const work = path.resolve(base, version)
  if (path.dirname(work) !== base) throw new Error('update work directory escaped the portable root')
  return work
}

/** Convert a byte count to compact progress copy. */
function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return '0 MB'
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

/** Open a GitHub Release asset through Electron's Chromium network stack. */
function openReleaseAsset(requestImpl, downloadUrl, connectionTimeoutMs = DOWNLOAD_CONNECTION_TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    let redirects = 0
    let finished = false
    const request = requestImpl({ method: 'GET', url: downloadUrl, redirect: 'manual' })
    const connectionTimeout = setTimeout(() => {
      finished = true
      request.abort()
      reject(new Error('release download connection timed out'))
    }, connectionTimeoutMs)
    request.setHeader('User-Agent', 'cedardsh-desktop-updater')
    request.on('redirect', (_statusCode, _method, redirectUrl) => {
      if (finished) return
      redirects += 1
      if (redirects > MAX_DOWNLOAD_REDIRECTS) {
        finished = true
        clearTimeout(connectionTimeout)
        request.abort()
        reject(new Error('release download exceeded 5 redirects'))
        return
      }
      if (!isTrustedDownloadUrl(redirectUrl)) {
        finished = true
        clearTimeout(connectionTimeout)
        request.abort()
        reject(new Error('release download redirected outside GitHub'))
        return
      }
      request.followRedirect()
    })
    request.on('response', (response) => {
      if (finished) {
        response.destroy()
        return
      }
      finished = true
      clearTimeout(connectionTimeout)
      resolve({ request, response })
    })
    request.on('error', (error) => {
      if (!finished) {
        finished = true
        clearTimeout(connectionTimeout)
        reject(new Error(`release download connection failed: ${error.message}`, { cause: error }))
      }
    })
    request.end()
  })
}

/** Download one selected Release asset and verify its exact size and SHA-256. */
async function downloadReleaseAsset(asset, destination, options = {}) {
  if (asset === null || typeof asset !== 'object') throw new TypeError('asset metadata is required')
  if (!isTrustedDownloadUrl(asset.downloadUrl)) throw new Error('release asset URL is not trusted')
  if (!Number.isSafeInteger(asset.size) || asset.size <= 0) throw new Error('release asset size is invalid')
  if (typeof asset.sha256 !== 'string' || !/^[0-9a-f]{64}$/u.test(asset.sha256)) {
    throw new Error('release asset SHA-256 is invalid')
  }
  const requestImpl = options.requestImpl
  if (typeof requestImpl !== 'function') throw new TypeError('requestImpl must be a function')
  const onProgress = typeof options.onProgress === 'function' ? options.onProgress : () => {}
  const partial = `${destination}.partial`
  fs.mkdirSync(path.dirname(destination), { recursive: true })
  fs.rmSync(partial, { force: true })

  try {
    const { request, response } = await openReleaseAsset(requestImpl, asset.downloadUrl)
    if (response.statusCode !== 200) {
      request.abort()
      throw new Error(`release download returned HTTP ${String(response.statusCode)}`)
    }

    let transferred = 0
    let idleTimeout
    let downloadIdle = false
    const resetIdleTimeout = () => {
      clearTimeout(idleTimeout)
      idleTimeout = setTimeout(() => {
        downloadIdle = true
        request.abort()
      }, options.idleTimeoutMs ?? DOWNLOAD_IDLE_TIMEOUT_MS)
    }
    const hash = crypto.createHash('sha256')
    const meter = new Transform({
      transform(chunk, _encoding, callback) {
        resetIdleTimeout()
        transferred += chunk.length
        if (transferred > asset.size) {
          callback(new Error('release download exceeded the published size'))
          return
        }
        hash.update(chunk)
        onProgress({ transferred, total: asset.size })
        callback(null, chunk)
      },
    })
    resetIdleTimeout()
    try {
      await pipeline(
        response,
        meter,
        fs.createWriteStream(partial, { flags: 'w' }),
      )
    } catch (error) {
      request.abort()
      if (downloadIdle) throw new Error('release download stalled with no incoming data', { cause: error })
      throw error
    } finally {
      clearTimeout(idleTimeout)
    }
    if (transferred !== asset.size) {
      throw new Error(`release download size mismatch: ${String(transferred)} != ${String(asset.size)}`)
    }
    const actualSha256 = hash.digest('hex')
    if (actualSha256 !== asset.sha256) {
      throw new Error(`release download SHA-256 mismatch: ${actualSha256}`)
    }
    fs.rmSync(destination, { force: true })
    fs.renameSync(partial, destination)
    return destination
  } catch (error) {
    fs.rmSync(partial, { force: true })
    throw error
  }
}

/** Read and validate the application-owned top-level entry list. */
function ownedTopLevelEntries(manifest) {
  if (manifest === null || typeof manifest !== 'object' || Array.isArray(manifest)) {
    throw new Error('manifest must contain an object')
  }
  if (!Array.isArray(manifest.ownedTopLevelEntries) || manifest.ownedTopLevelEntries.length === 0) {
    throw new Error('manifest has no ownedTopLevelEntries')
  }
  const entries = []
  const seen = new Set()
  for (const entry of manifest.ownedTopLevelEntries) {
    if (typeof entry !== 'string' || entry === '' || path.basename(entry) !== entry || entry === '.' || entry === '..') {
      throw new Error(`manifest owns an invalid top-level entry: ${String(entry)}`)
    }
    if (PRESERVED_ENTRIES.has(entry) || entry === UPDATE_DIRECTORY) {
      throw new Error(`manifest must not own updater-preserved entry ${entry}`)
    }
    if (seen.has(entry)) throw new Error(`manifest owns duplicate entry ${entry}`)
    seen.add(entry)
    entries.push(entry)
  }
  for (const required of REQUIRED_OWNED_ENTRIES) {
    if (!seen.has(required)) throw new Error(`manifest does not own required entry ${required}`)
  }
  return entries
}

/** Refuse a new package entry that would claim an existing user-owned root item. */
function assertNoOwnershipCollisions(root, currentManifest, nextManifest) {
  const current = new Set(ownedTopLevelEntries(currentManifest))
  for (const entry of ownedTopLevelEntries(nextManifest)) {
    if (!current.has(entry) && fs.existsSync(path.join(root, entry))) {
      throw new Error(`update would replace an unowned top-level entry: ${entry}`)
    }
  }
}

/** Reject links and junctions in an extracted update tree. */
function assertNoReparsePoints(root) {
  const pending = [root]
  while (pending.length > 0) {
    const current = pending.pop()
    const stat = fs.lstatSync(current)
    if (stat.isSymbolicLink()) throw new Error(`staged update contains a link: ${current}`)
    if (!stat.isDirectory()) continue
    for (const child of fs.readdirSync(current)) pending.push(path.join(current, child))
  }
}

/** Remove an updater-owned tree without entering links or junctions. */
function removeUpdateTree(root) {
  let stat
  try {
    stat = fs.lstatSync(root)
  } catch (error) {
    if (error.code === 'ENOENT') return
    throw error
  }
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    fs.unlinkSync(root)
    return
  }
  for (const child of fs.readdirSync(root)) removeUpdateTree(path.join(root, child))
  fs.rmdirSync(root)
}

/** Validate the extracted portable tree before the running app exits. */
function validateStagedPackage(packageRoot, expectedVersion) {
  const root = path.resolve(packageRoot)
  assertNoReparsePoints(root)
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'))
  if (manifest.portableVersion !== expectedVersion) {
    throw new Error(`staged portable version ${String(manifest.portableVersion)} != ${expectedVersion}`)
  }
  if (typeof manifest.dshVersion !== 'string' || manifest.dshVersion.length === 0) {
    throw new Error('staged manifest has no official DSH version')
  }
  const owned = ownedTopLevelEntries(manifest)
  const actualOwned = fs.readdirSync(root).filter((entry) => !PRESERVED_ENTRIES.has(entry)).sort()
  if (JSON.stringify([...owned].sort()) !== JSON.stringify(actualOwned)) {
    throw new Error('staged package entries do not match ownedTopLevelEntries')
  }
  for (const preserved of PRESERVED_ENTRIES) {
    const directory = path.join(root, preserved)
    if (!fs.statSync(directory).isDirectory() || fs.readdirSync(directory).length !== 0) {
      throw new Error(`staged ${preserved} must be an empty directory`)
    }
  }
  for (const relativePath of REQUIRED_PACKAGE_FILES) {
    const file = path.join(root, relativePath)
    if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
      throw new Error(`staged required file is missing: ${relativePath}`)
    }
  }
  return manifest
}

module.exports = {
  PRESERVED_ENTRIES,
  UPDATE_REQUEST_PATH,
  assertNoOwnershipCollisions,
  downloadReleaseAsset,
  formatBytes,
  isDesktopRequest,
  isDesktopUpdateRequest,
  isTrustedDownloadUrl,
  openReleaseAsset,
  ownedTopLevelEntries,
  removeUpdateTree,
  updateWorkDirectory,
  validateStagedPackage,
}
