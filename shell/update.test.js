'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')

const {
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
} = require('./update.js')

function release(version, options = {}) {
  const assetPrefix = options.assetPrefix || 'CedarDSH-Desktop'
  return {
    draft: options.draft === true,
    html_url: options.url || `https://github.com/maiziman/cedardsh-desktop/releases/tag/v${version}`,
    tag_name: options.tag || `v${version}`,
    name: options.name || `CedarDSH Desktop ${version}`,
    assets: [
      {
        name: `${assetPrefix}-win64-v${version}.zip`,
        state: 'uploaded',
        size: 1024,
        digest: `sha256:${'a'.repeat(64)}`,
        browser_download_url: `https://github.com/maiziman/cedardsh-desktop/releases/download/v${version}/${assetPrefix}-win64-v${version}.zip`,
      },
      {
        name: 'SHA256SUMS.txt',
        state: 'uploaded',
        size: 96,
        digest: `sha256:${'b'.repeat(64)}`,
        browser_download_url: `https://github.com/maiziman/cedardsh-desktop/releases/download/v${version}/SHA256SUMS.txt`,
      },
    ],
  }
}

test('version parsing and ordering follow Semantic Version precedence', () => {
  assert.deepEqual(parseVersion('0.1.1-rc.2+build.7'), { core: ['0', '1', '1'], prerelease: ['rc', '2'] })
  assert.equal(parseVersion('v0.1.1'), null)
  assert.equal(parseVersion('01.1.1'), null)
  assert.equal(parseVersion('1.0.0-alpha..1'), null)
  assert.equal(parseVersion('1.0.0-rc.01'), null)
  assert.equal(isNewerVersion('0.1.1-rc.3', '0.1.1-rc.2'), true)
  assert.equal(isNewerVersion('0.1.1', '0.1.1-rc.9'), true)
  assert.equal(isNewerVersion('0.2.0-rc.1', '0.1.9'), true)
  assert.equal(isNewerVersion('0.1.1-rc.1', '0.1.1-rc.2'), false)
  assert.equal(isNewerVersion('1.0.0-a', '1.0.0-A'), true)
  assert.equal(isNewerVersion('100000000000000000000.0.0', '99999999999999999999.0.0'), true)
  assert.equal(isNewerVersion('1.0.0+build.2', '1.0.0+build.1'), false)
})

test('packaged portable version requires the current manifest field', () => {
  assert.equal(packagedPortableVersion({ portableVersion: '1.2.1', dshVersion: '0.1.2-alpha.1' }), '1.2.1')
  assert.equal(packagedPortableVersion({ dshVersion: '0.1.1-rc.2' }), null)
  assert.equal(packagedPortableVersion({ portableVersion: 'invalid', dshVersion: '0.1.1-rc.2' }), null)
  assert.equal(packagedPortableVersion(null), null)
})

test('release selection ignores drafts, foreign URLs, and malformed assets', () => {
  const unrelatedRelease = {
    draft: false,
    html_url: 'https://github.com/maiziman/cedardsh-desktop/releases/tag/tools-v0.1.0',
    tag_name: 'tools-v0.1.0',
    name: 'Auxiliary tool v0.1.0',
    assets: [
      { name: 'auxiliary-tool-0.1.0.tgz' },
      { name: 'SHA256SUMS.txt' },
    ],
  }
  const releases = [
    unrelatedRelease,
    release('0.2.0-rc.1', { draft: true }),
    release('0.1.9', { url: 'https://example.com/releases/0.1.9' }),
    { ...release('0.1.8'), assets: [{ name: 'source.zip' }] },
    { ...release('0.1.7'), assets: [{ name: 'DeepSeek-Harness-win64-v0.1.7.zip' }] },
    release('0.1.1-rc.2'),
    release('0.1.1-rc.3'),
  ]
  assert.deepEqual(selectLatestRelease(releases), {
    version: '0.1.1-rc.3',
    releaseUrl: 'https://github.com/maiziman/cedardsh-desktop/releases/tag/v0.1.1-rc.3',
    releaseName: 'CedarDSH Desktop 0.1.1-rc.3',
    asset: {
      name: 'CedarDSH-Desktop-win64-v0.1.1-rc.3.zip',
      downloadUrl: 'https://github.com/maiziman/cedardsh-desktop/releases/download/v0.1.1-rc.3/CedarDSH-Desktop-win64-v0.1.1-rc.3.zip',
      size: 1024,
      sha256: 'a'.repeat(64),
    },
  })
  assert.equal(isTrustedReleaseUrl('https://github.com/maiziman/cedardsh-desktop/releases/tag/v1'), true)
  assert.equal(isTrustedReleaseUrl('https://github.com/another/repository/releases/tag/v1'), false)
  assert.equal(isTrustedAssetUrl(
    'https://github.com/maiziman/cedardsh-desktop/releases/download/v1.2.3/CedarDSH-Desktop-win64-v1.2.3.zip',
    '1.2.3',
    'CedarDSH-Desktop-win64-v1.2.3.zip',
  ), true)
  assert.equal(isTrustedAssetUrl(
    'https://example.com/maiziman/cedardsh-desktop/releases/download/v1.2.3/CedarDSH-Desktop-win64-v1.2.3.zip',
    '1.2.3',
    'CedarDSH-Desktop-win64-v1.2.3.zip',
  ), false)
  assert.equal(selectLatestRelease([unrelatedRelease]), null)
})

test('an update is offered only for a newer public portable package', () => {
  assert.equal(availableUpdate('0.1.1-rc.2', [release('0.1.1-rc.2')]), null)
  assert.equal(availableUpdate('0.1.1-rc.2', [release('0.1.1-rc.3')]).version, '0.1.1-rc.3')
  assert.equal(availableUpdate('0.1.1-rc.2', [release('0.1.1-rc.3', { assetPrefix: 'DeepSeek-Harness' })]), null)
})

test('release selection rejects portable releases with extra assets', () => {
  assert.equal(selectLatestRelease([{ ...release('1.2.1'), assets: [...release('1.2.1').assets, { name: 'extra.txt' }] }]), null)
})

test('release selection requires matching tag and complete asset records', () => {
  assert.equal(selectLatestRelease([release('1.2.1', { tag: 'v1.2.0' })]), null)
  assert.equal(selectLatestRelease([release('1.2.1', {
    url: 'https://github.com/maiziman/cedardsh-desktop/releases/tag/v1.2.0',
  })]), null)
  const incomplete = release('1.2.1')
  incomplete.assets[0] = { ...incomplete.assets[0], digest: null }
  assert.equal(selectLatestRelease([incomplete]), null)
  const foreignDownload = release('1.2.1')
  foreignDownload.assets[0] = { ...foreignDownload.assets[0], browser_download_url: 'https://example.com/update.zip' }
  assert.equal(selectLatestRelease([foreignDownload]), null)
})

test('release pagination reaches a portable package after a full unrelated page', async () => {
  const unrelatedPage = Array.from({ length: 100 }, (_, index) => ({
    draft: false,
    html_url: `https://github.com/maiziman/cedardsh-desktop/releases/tag/tool-${index}`,
    name: `Tool ${index}`,
    assets: [{ name: `tool-${index}.tgz` }, { name: 'SHA256SUMS.txt' }],
  }))
  const requested = []
  const releases = await collectReleasePages(async (page) => {
    requested.push(page)
    return page === 1 ? unrelatedPage : [release('0.2.0-alpha.1')]
  })
  assert.deepEqual(requested, [1, 2])
  assert.equal(selectLatestRelease(releases).version, '0.2.0-alpha.1')
})

test('release pages use the injected desktop network fetch implementation', async () => {
  const requests = []
  const releases = await fetchPublicReleases(async (url, options) => {
    requests.push({ url, options })
    return new Response(JSON.stringify([release('1.3.2')]), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    })
  })
  assert.equal(releases.length, 1)
  assert.match(requests[0].url, /per_page=100&page=1$/u)
  assert.equal(requests[0].options.headers['User-Agent'], 'cedardsh-desktop-update-check')
  assert.ok(requests[0].options.signal instanceof AbortSignal)
})

test('release queries cancel unsuccessful response bodies', async () => {
  let cancelled = false
  const body = new ReadableStream({
    cancel() { cancelled = true },
  })
  await assert.rejects(fetchPublicReleases(async () => new Response(body, { status: 503 })), /HTTP 503/u)
  assert.equal(cancelled, true)
})

test('release pagination fails closed at its bounded page limit', async () => {
  await assert.rejects(
    collectReleasePages(async () => Array.from({ length: 100 }, () => ({}))),
    /exceeded the 5-page update-check limit/u,
  )
})

test('the update interval tolerates missing, invalid, and future state', () => {
  const now = Date.parse('2026-08-27T05:00:00Z')
  assert.equal(shouldCheck(undefined, now), true)
  assert.equal(shouldCheck('invalid', now), true)
  assert.equal(shouldCheck('2026-08-28T05:00:00Z', now), true)
  assert.equal(shouldCheck(new Date(now - CHECK_INTERVAL_MS + 1).toISOString(), now), false)
  assert.equal(shouldCheck(new Date(now - CHECK_INTERVAL_MS).toISOString(), now), true)
})
