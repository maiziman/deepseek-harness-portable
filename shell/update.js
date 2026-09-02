'use strict'

const { Readable } = require('node:stream')

// Selects verified portable versions from public GitHub Releases and performs
// the bounded network request used by the desktop shell's opt-in update prompt.

const RELEASES_URL = 'https://api.github.com/repos/maiziman/cedardsh-desktop/releases'
const RELEASE_PATH_PREFIX = '/maiziman/cedardsh-desktop/releases/'
const CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000
const REQUEST_TIMEOUT_MS = 10000
const MAX_RESPONSE_BYTES = 1024 * 1024
const RELEASE_PAGE_SIZE = 100
const MAX_RELEASE_PAGES = 5
const VERSION_PATTERN = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/u
const ASSET_PATTERN = /^CedarDSH-Desktop-win64-v(.+)\.zip$/u

/**
 * Parse a supported Semantic Version for deterministic comparison.
 *
 * @param {string} value Version text.
 * @returns {{core: string[], prerelease: string[]} | null} Parsed version or null.
 */
function parseVersion(value) {
  if (typeof value !== 'string') return null
  const match = VERSION_PATTERN.exec(value)
  if (match === null) return null
  return {
    core: [match[1], match[2], match[3]],
    prerelease: match[4] === undefined ? [] : match[4].split('.'),
  }
}

/**
 * Compare two valid parsed Semantic Versions.
 *
 * @param {{core: string[], prerelease: string[]}} left Left-hand version.
 * @param {{core: string[], prerelease: string[]}} right Right-hand version.
 * @returns {number} Negative, zero, or positive comparison result.
 */
function compareParsedVersions(left, right) {
  for (let index = 0; index < left.core.length; index += 1) {
    const comparison = compareNumericIdentifiers(left.core[index], right.core[index])
    if (comparison !== 0) return comparison
  }
  if (left.prerelease.length === 0 || right.prerelease.length === 0) {
    if (left.prerelease.length === right.prerelease.length) return 0
    return left.prerelease.length === 0 ? 1 : -1
  }
  const length = Math.max(left.prerelease.length, right.prerelease.length)
  for (let index = 0; index < length; index += 1) {
    const leftPart = left.prerelease[index]
    const rightPart = right.prerelease[index]
    if (leftPart === undefined || rightPart === undefined) {
      if (leftPart === rightPart) return 0
      return leftPart === undefined ? -1 : 1
    }
    if (leftPart === rightPart) continue
    const leftNumeric = /^\d+$/u.test(leftPart)
    const rightNumeric = /^\d+$/u.test(rightPart)
    if (leftNumeric && rightNumeric) return compareNumericIdentifiers(leftPart, rightPart)
    if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1
    return leftPart < rightPart ? -1 : 1
  }
  return 0
}

/**
 * Compare normalized numeric identifiers without losing integer precision.
 *
 * @param {string} left Left numeric identifier.
 * @param {string} right Right numeric identifier.
 * @returns {number} Negative, zero, or positive comparison result.
 */
function compareNumericIdentifiers(left, right) {
  if (left.length !== right.length) return left.length - right.length
  if (left === right) return 0
  return left < right ? -1 : 1
}

/**
 * Determine whether a candidate version is newer than the packaged version.
 *
 * @param {string} candidate Candidate release version.
 * @param {string} current Packaged portable version.
 * @returns {boolean} Whether the candidate is newer.
 */
function isNewerVersion(candidate, current) {
  const candidateVersion = parseVersion(candidate)
  const currentVersion = parseVersion(current)
  if (candidateVersion === null || currentVersion === null) return false
  return compareParsedVersions(candidateVersion, currentVersion) > 0
}

/**
 * Resolve the portable release version recorded by a packaged manifest.
 *
 * @param {unknown} manifest Packaged manifest data.
 * @returns {string | null} Valid portable version or null.
 */
function packagedPortableVersion(manifest) {
  if (manifest === null || typeof manifest !== 'object' || Array.isArray(manifest)) return null
  return parseVersion(manifest.portableVersion) === null ? null : manifest.portableVersion
}

/**
 * Validate that a release page belongs to this repository on GitHub.
 *
 * @param {unknown} value Candidate URL.
 * @returns {boolean} Whether the URL is trusted for external navigation.
 */
function isTrustedReleaseUrl(value) {
  if (typeof value !== 'string') return false
  try {
    const url = new URL(value)
    return url.protocol === 'https:' && url.hostname === 'github.com' && url.pathname.startsWith(RELEASE_PATH_PREFIX)
  } catch {
    return false
  }
}

/**
 * Validate the browser-download URL for one versioned portable ZIP.
 *
 * @param {unknown} value Candidate URL.
 * @param {string} version Portable release version.
 * @param {string} assetName ZIP asset name.
 * @returns {boolean} Whether the URL is the expected GitHub asset endpoint.
 */
function isTrustedAssetUrl(value, version, assetName) {
  if (typeof value !== 'string') return false
  try {
    const url = new URL(value)
    return url.protocol === 'https:'
      && url.hostname === 'github.com'
      && url.pathname === `${RELEASE_PATH_PREFIX}download/v${version}/${assetName}`
  } catch {
    return false
  }
}

/**
 * Read the portable version represented by a public GitHub Release.
 *
 * @param {unknown} release GitHub Release response entry.
 * @returns {{version: string, releaseUrl: string, releaseName: string, asset: {name: string, downloadUrl: string, size: number, sha256: string}} | null} Valid update metadata.
 */
function releaseMetadata(release) {
  if (release === null || typeof release !== 'object' || release.draft === true) return null
  if (!isTrustedReleaseUrl(release.html_url) || !Array.isArray(release.assets)) return null
  const checksums = release.assets.filter((asset) => asset !== null && typeof asset === 'object' && asset.name === 'SHA256SUMS.txt')
  const portableAssets = release.assets.filter((asset) => (
    asset !== null
    && typeof asset === 'object'
    && typeof asset.name === 'string'
    && ASSET_PATTERN.test(asset.name)
  ))
  if (release.assets.length !== 2 || checksums.length !== 1 || portableAssets.length !== 1) return null
  const match = ASSET_PATTERN.exec(portableAssets[0].name)
  if (match === null || parseVersion(match[1]) === null) return null
  if (release.tag_name !== `v${match[1]}`) return null
  if (new URL(release.html_url).pathname !== `${RELEASE_PATH_PREFIX}tag/v${match[1]}`) return null
  for (const asset of [portableAssets[0], checksums[0]]) {
    if (asset.state !== 'uploaded' || !Number.isSafeInteger(asset.size) || asset.size <= 0) return null
    if (typeof asset.digest !== 'string' || !/^sha256:[0-9a-f]{64}$/u.test(asset.digest)) return null
  }
  if (!isTrustedAssetUrl(portableAssets[0].browser_download_url, match[1], portableAssets[0].name)) return null
  return {
    version: match[1],
    releaseUrl: release.html_url,
    releaseName: typeof release.name === 'string' && release.name.trim() !== '' ? release.name.trim() : match[1],
    asset: {
      name: portableAssets[0].name,
      downloadUrl: portableAssets[0].browser_download_url,
      size: portableAssets[0].size,
      sha256: portableAssets[0].digest.slice('sha256:'.length),
    },
  }
}

/**
 * Select the highest published portable version from GitHub Releases.
 *
 * @param {unknown} releases GitHub Releases response.
 * @returns {{version: string, releaseUrl: string, releaseName: string, asset: {name: string, downloadUrl: string, size: number, sha256: string}} | null} Highest valid release.
 */
function selectLatestRelease(releases) {
  if (!Array.isArray(releases)) return null
  let selected = null
  for (const release of releases) {
    const metadata = releaseMetadata(release)
    if (metadata === null) continue
    if (selected === null || isNewerVersion(metadata.version, selected.version)) selected = metadata
  }
  return selected
}

/**
 * Select a public portable release only when it is newer than the package.
 *
 * @param {string} currentVersion Packaged portable version.
 * @param {unknown} releases GitHub Releases response.
 * @returns {{version: string, releaseUrl: string, releaseName: string, asset: {name: string, downloadUrl: string, size: number, sha256: string}} | null} Available update.
 */
function availableUpdate(currentVersion, releases) {
  const latest = selectLatestRelease(releases)
  return latest !== null && isNewerVersion(latest.version, currentVersion) ? latest : null
}

/**
 * Decide whether the daily update check is due.
 *
 * @param {unknown} lastCheckedAt Stored ISO timestamp.
 * @param {number} [now] Current epoch milliseconds.
 * @returns {boolean} Whether a network check should run.
 */
function shouldCheck(lastCheckedAt, now = Date.now()) {
  if (typeof lastCheckedAt !== 'string') return true
  const checkedAt = Date.parse(lastCheckedAt)
  if (!Number.isFinite(checkedAt) || checkedAt > now) return true
  return now - checkedAt >= CHECK_INTERVAL_MS
}

/**
 * Fetch one public GitHub Releases page with bounded memory and time.
 *
 * @param {number} page One-based page number.
 * @param {typeof fetch} fetchImpl Electron network fetch implementation.
 * @returns {Promise<unknown>} Parsed GitHub response page.
 */
async function requestReleasePage(page, fetchImpl) {
  const response = await fetchImpl(`${RELEASES_URL}?per_page=${RELEASE_PAGE_SIZE}&page=${page}`, {
    headers: {
      Accept: 'application/vnd.github+json',
      'User-Agent': 'cedardsh-desktop-update-check',
      'X-GitHub-Api-Version': '2022-11-28',
    },
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  })
  if (response.status !== 200) {
    await response.body?.cancel()
    throw new Error(`GitHub Releases returned HTTP ${String(response.status)}`)
  }
  if (response.body === null) throw new Error('GitHub Releases returned no body')
  const chunks = []
  let size = 0
  for await (const chunk of Readable.fromWeb(response.body)) {
    size += chunk.length
    if (size > MAX_RESPONSE_BYTES) throw new Error('GitHub Releases response exceeded 1 MiB')
    chunks.push(chunk)
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'))
  } catch (error) {
    throw new Error(`GitHub Releases returned invalid JSON: ${error.message}`)
  }
}

/**
 * Collect the bounded public Release pages needed by the update selector.
 *
 * @param {(page: number) => Promise<unknown>} fetchPage Release page reader.
 * @returns {Promise<object[]>} Combined GitHub Release entries.
 */
async function collectReleasePages(fetchPage) {
  const releases = []
  for (let page = 1; page <= MAX_RELEASE_PAGES; page += 1) {
    const entries = await fetchPage(page)
    if (!Array.isArray(entries)) throw new Error(`GitHub Releases page ${page} was not an array`)
    releases.push(...entries)
    if (entries.length < RELEASE_PAGE_SIZE) return releases
  }
  throw new Error(`GitHub Releases exceeded the ${MAX_RELEASE_PAGES}-page update-check limit`)
}

/**
 * Fetch the bounded public GitHub Releases collection.
 *
 * @param {typeof fetch} fetchImpl Electron network fetch implementation.
 * @returns {Promise<object[]>} Parsed GitHub Release entries.
 */
function fetchPublicReleases(fetchImpl) {
  if (typeof fetchImpl !== 'function') throw new TypeError('fetchImpl must be a function')
  return collectReleasePages(page => requestReleasePage(page, fetchImpl))
}

module.exports = {
  CHECK_INTERVAL_MS,
  availableUpdate,
  collectReleasePages,
  fetchPublicReleases,
  isNewerVersion,
  isTrustedAssetUrl,
  isTrustedReleaseUrl,
  packagedPortableVersion,
  parseVersion,
  selectLatestRelease,
  shouldCheck,
}
