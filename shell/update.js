'use strict'

// Selects verified portable versions from public GitHub Releases and performs
// the bounded network request used by the desktop shell's opt-in update prompt.

const https = require('node:https')

const RELEASES_URL = 'https://api.github.com/repos/maiziman/deepseek-harness-portable/releases?per_page=30'
const RELEASE_PATH_PREFIX = '/maiziman/deepseek-harness-portable/releases/'
const CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000
const REQUEST_TIMEOUT_MS = 10000
const MAX_RESPONSE_BYTES = 1024 * 1024
const VERSION_PATTERN = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/u
const ASSET_PATTERN = /^DeepSeek-Harness-win64-v(.+)\.zip$/u

/**
 * Parse a supported Semantic Version for deterministic comparison.
 *
 * @param {string} value Version text.
 * @returns {{core: number[], prerelease: string[]} | null} Parsed version or null.
 */
function parseVersion(value) {
  if (typeof value !== 'string') return null
  const match = VERSION_PATTERN.exec(value)
  if (match === null) return null
  return {
    core: [Number(match[1]), Number(match[2]), Number(match[3])],
    prerelease: match[4] === undefined ? [] : match[4].split('.'),
  }
}

/**
 * Compare two valid parsed Semantic Versions.
 *
 * @param {{core: number[], prerelease: string[]}} left Left-hand version.
 * @param {{core: number[], prerelease: string[]}} right Right-hand version.
 * @returns {number} Negative, zero, or positive comparison result.
 */
function compareParsedVersions(left, right) {
  for (let index = 0; index < left.core.length; index += 1) {
    if (left.core[index] !== right.core[index]) return left.core[index] - right.core[index]
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
    if (leftNumeric && rightNumeric) return Number(leftPart) - Number(rightPart)
    if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1
    return leftPart.localeCompare(rightPart, 'en')
  }
  return 0
}

/**
 * Determine whether a candidate version is newer than the packaged version.
 *
 * @param {string} candidate Candidate release version.
 * @param {string} current Packaged dsh version.
 * @returns {boolean} Whether the candidate is newer.
 */
function isNewerVersion(candidate, current) {
  const candidateVersion = parseVersion(candidate)
  const currentVersion = parseVersion(current)
  if (candidateVersion === null || currentVersion === null) return false
  return compareParsedVersions(candidateVersion, currentVersion) > 0
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
 * Read the packaged dsh version represented by a public GitHub Release.
 *
 * @param {unknown} release GitHub Release response entry.
 * @returns {{version: string, releaseUrl: string, releaseName: string} | null} Valid update metadata.
 */
function releaseMetadata(release) {
  if (release === null || typeof release !== 'object' || release.draft === true) return null
  if (!isTrustedReleaseUrl(release.html_url) || !Array.isArray(release.assets)) return null
  for (const asset of release.assets) {
    if (asset === null || typeof asset !== 'object' || typeof asset.name !== 'string') continue
    const match = ASSET_PATTERN.exec(asset.name)
    if (match === null || parseVersion(match[1]) === null) continue
    return {
      version: match[1],
      releaseUrl: release.html_url,
      releaseName: typeof release.name === 'string' && release.name.trim() !== '' ? release.name.trim() : match[1],
    }
  }
  return null
}

/**
 * Select the highest published portable version from GitHub Releases.
 *
 * @param {unknown} releases GitHub Releases response.
 * @returns {{version: string, releaseUrl: string, releaseName: string} | null} Highest valid release.
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
 * @param {string} currentVersion Packaged dsh version.
 * @param {unknown} releases GitHub Releases response.
 * @returns {{version: string, releaseUrl: string, releaseName: string} | null} Available update.
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
 * Fetch the public GitHub Releases collection with bounded memory and time.
 *
 * @returns {Promise<unknown>} Parsed GitHub response.
 */
function fetchPublicReleases() {
  return new Promise((resolve, reject) => {
    const request = https.get(RELEASES_URL, {
      headers: {
        Accept: 'application/vnd.github+json',
        'User-Agent': 'deepseek-harness-portable-update-check',
        'X-GitHub-Api-Version': '2022-11-28',
      },
    }, (response) => {
      if (response.statusCode !== 200) {
        response.resume()
        reject(new Error(`GitHub Releases returned HTTP ${String(response.statusCode)}`))
        return
      }
      const chunks = []
      let size = 0
      response.on('data', (chunk) => {
        size += chunk.length
        if (size > MAX_RESPONSE_BYTES) {
          request.destroy(new Error('GitHub Releases response exceeded 1 MiB'))
          return
        }
        chunks.push(chunk)
      })
      response.on('end', () => {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')))
        } catch (error) {
          reject(new Error(`GitHub Releases returned invalid JSON: ${error.message}`))
        }
      })
      response.on('error', reject)
    })
    request.setTimeout(REQUEST_TIMEOUT_MS, () => request.destroy(new Error('GitHub Releases request timed out')))
    request.on('error', reject)
  })
}

module.exports = {
  CHECK_INTERVAL_MS,
  availableUpdate,
  fetchPublicReleases,
  isNewerVersion,
  isTrustedReleaseUrl,
  parseVersion,
  selectLatestRelease,
  shouldCheck,
}
