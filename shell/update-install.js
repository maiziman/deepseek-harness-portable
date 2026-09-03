'use strict'

const crypto = require('node:crypto')
const { spawn } = require('node:child_process')
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
  path.join('resources', 'app', 'update-launcher.ps1'),
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

/** Count non-empty newline-delimited archive entries from a child stream. */
function entryCounter(onEntry) {
  let pending = ''
  return {
    write(chunk) {
      const lines = (pending + chunk.toString()).split(/\r?\n/u)
      pending = lines.pop()
      for (const line of lines) {
        if (line.length > 0) onEntry()
      }
    },
    end() {
      if (pending.length > 0) onEntry()
    },
  }
}

/** Run Windows tar and return the number of archive entries it reports. */
function runTar(tarPath, args, spawnImpl = spawn, entrySource = 'stdout', onEntry = () => {}) {
  return new Promise((resolve, reject) => {
    const child = spawnImpl(tarPath, args, {
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    let entries = 0
    let stderr = ''
    const counter = entryCounter(() => {
      entries += 1
      onEntry(entries)
    })
    child.stdout.on('data', chunk => {
      if (entrySource === 'stdout') counter.write(chunk)
    })
    child.stderr.on('data', chunk => {
      stderr = (stderr + chunk.toString()).slice(-8192)
      if (entrySource === 'stderr') counter.write(chunk)
    })
    child.once('error', reject)
    child.once('close', (code) => {
      counter.end()
      if (code === 0) resolve(entries)
      else reject(new Error(stderr.trim() || `tar exited with code ${String(code)}`))
    })
  })
}

/** Extract a ZIP with Windows tar and report exact archive-entry progress. */
async function extractArchive(archivePath, destinationPath, options) {
  const total = await runTar(options.tarPath, ['-tf', archivePath], options.spawnImpl, 'stdout')
  if (total === 0) throw new Error('update archive is empty')
  if (fs.existsSync(destinationPath)) throw new Error(`update extraction destination already exists: ${destinationPath}`)
  fs.mkdirSync(destinationPath)
  const extracted = await runTar(
    options.tarPath,
    ['-xvf', archivePath, '-C', destinationPath],
    options.spawnImpl,
    'stderr',
    transferred => options.onProgress({ transferred, total }),
  )
  if (extracted !== total) {
    throw new Error(`update archive entry count mismatch: ${String(extracted)} != ${String(total)}`)
  }
}

/**
 * Open a GitHub Release asset through Electron's Chromium network stack.
 *
 * `options.rangeStart` resumes an earlier partial download by requesting the
 * asset from that byte offset; the Range header is reapplied across redirects.
 *
 * @param {(options: object) => object} requestImpl Electron network request factory.
 * @param {string} downloadUrl Resolved GitHub asset URL.
 * @param {number} [connectionTimeoutMs] Connection establishment timeout.
 * @param {{rangeStart?: number}} [options] Request options.
 * @returns {Promise<{request: object, response: object}>} Opened request and response.
 */
function openReleaseAsset(requestImpl, downloadUrl, connectionTimeoutMs = DOWNLOAD_CONNECTION_TIMEOUT_MS, options = {}) {
  const rangeStart = options.rangeStart
  if (rangeStart !== undefined && (!Number.isSafeInteger(rangeStart) || rangeStart <= 0)) {
    throw new TypeError('rangeStart must be a positive safe integer')
  }
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
    if (rangeStart !== undefined) request.setHeader('Range', `bytes=${String(rangeStart)}-`)
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
      if (rangeStart !== undefined) request.setHeader('Range', `bytes=${String(rangeStart)}-`)
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

/** Return one response header value regardless of key casing. */
function responseHeader(response, name) {
  const headers = response.headers
  if (headers === null || typeof headers !== 'object') return undefined
  const target = name.toLowerCase()
  for (const [key, value] of Object.entries(headers)) {
    if (key.toLowerCase() === target) return value
  }
  return undefined
}

/**
 * Validate the Content-Range of a resumed download response.
 *
 * @param {object} response Open download response.
 * @param {number} resumeOffset Byte offset the Range request asked for.
 * @param {number} assetSize Published asset size in bytes.
 * @returns {number} Confirmed resume start offset.
 */
function resumeRangeStart(response, resumeOffset, assetSize) {
  const value = responseHeader(response, 'content-range')
  if (typeof value !== 'string') {
    throw new Error('release download resumed without a Content-Range header')
  }
  const match = /^bytes\s+(\d+)-(\d+)\/(\d+|\*)$/iu.exec(value.trim())
  if (match === null) throw new Error(`release download resumed with an invalid Content-Range: ${value}`)
  const start = Number(match[1])
  const end = Number(match[2])
  if (start !== resumeOffset) {
    throw new Error(`release download resumed from byte ${String(start)} instead of ${String(resumeOffset)}`)
  }
  if (end < start) throw new Error(`release download resumed with an inverted Content-Range: ${value}`)
  if (match[3] !== '*' && Number(match[3]) !== assetSize) {
    throw new Error(`release download resumed against the wrong asset size: ${match[3]}`)
  }
  return start
}

/**
 * Return the byte offset a kept partial download can resume from, or 0.
 *
 * Only a regular file strictly smaller than the published size is usable;
 * anything else means a fresh download.
 *
 * @param {string} destination Final archive path.
 * @param {number} size Published asset size in bytes.
 * @returns {number} Valid resume offset, or 0 for a fresh download.
 */
function partialResumeOffset(destination, size) {
  let stat
  try {
    stat = fs.statSync(`${destination}.partial`)
  } catch (error) {
    if (error.code === 'ENOENT') return 0
    throw error
  }
  if (!stat.isFile() || stat.size <= 0 || stat.size >= size) return 0
  return stat.size
}

/** Feed an existing file into a running hash so a resumed download verifies the whole asset. */
async function hashFileInto(hash, filePath) {
  for await (const chunk of fs.createReadStream(filePath)) hash.update(chunk)
}

/**
 * Download one selected Release asset and verify its exact size and SHA-256.
 *
 * A partial file from an earlier attempt is resumed with an HTTP Range
 * request; the server is allowed to ignore the Range and restart the
 * transfer. Interrupted transfers keep the partial file for the next
 * attempt, while transfers that fail size or digest verification discard it.
 *
 * @param {{name: string, downloadUrl: string, size: number, sha256: string}} asset Release asset metadata.
 * @param {string} destination Final archive path.
 * @param {{requestImpl: (options: object) => object, onProgress?: (progress: {transferred: number, total: number}) => void, idleTimeoutMs?: number}} [options] Download options.
 * @returns {Promise<string>} Final archive path.
 */
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
  const resumeOffset = partialResumeOffset(destination, asset.size)
  if (resumeOffset === 0) fs.rmSync(partial, { force: true })

  let request = null
  let transferred = 0
  let downloadIdle = false
  try {
    const opened = await openReleaseAsset(requestImpl, asset.downloadUrl, undefined, {
      rangeStart: resumeOffset > 0 ? resumeOffset : undefined,
    })
    request = opened.request
    const response = opened.response
    let offset = resumeOffset
    if (offset > 0) {
      if (response.statusCode === 206) {
        resumeRangeStart(response, offset, asset.size)
      } else if (response.statusCode === 200) {
        offset = 0
        fs.rmSync(partial, { force: true })
      } else {
        request.abort()
        throw new Error(`release download returned HTTP ${String(response.statusCode)}`)
      }
    } else if (response.statusCode !== 200) {
      request.abort()
      throw new Error(`release download returned HTTP ${String(response.statusCode)}`)
    }

    const hash = crypto.createHash('sha256')
    if (offset > 0) await hashFileInto(hash, partial)
    transferred = offset
    onProgress({ transferred, total: asset.size })
    let idleTimeout
    const resetIdleTimeout = () => {
      clearTimeout(idleTimeout)
      idleTimeout = setTimeout(() => {
        downloadIdle = true
        request.abort()
      }, options.idleTimeoutMs ?? DOWNLOAD_IDLE_TIMEOUT_MS)
    }
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
        fs.createWriteStream(partial, { flags: offset > 0 ? 'a' : 'w' }),
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
      fs.rmSync(partial, { force: true })
      throw new Error(`release download SHA-256 mismatch: ${actualSha256}`)
    }
    fs.rmSync(destination, { force: true })
    fs.renameSync(partial, destination)
    return destination
  } catch (error) {
    if (transferred > asset.size) fs.rmSync(partial, { force: true })
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
  extractArchive,
  formatBytes,
  isDesktopRequest,
  isDesktopUpdateRequest,
  isTrustedDownloadUrl,
  openReleaseAsset,
  ownedTopLevelEntries,
  partialResumeOffset,
  removeUpdateTree,
  resumeRangeStart,
  updateWorkDirectory,
  validateStagedPackage,
}
