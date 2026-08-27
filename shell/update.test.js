'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')

const {
  CHECK_INTERVAL_MS,
  availableUpdate,
  isNewerVersion,
  isTrustedReleaseUrl,
  parseVersion,
  selectLatestRelease,
  shouldCheck,
} = require('./update.js')

function release(version, options = {}) {
  return {
    draft: options.draft === true,
    html_url: options.url || `https://github.com/maiziman/deepseek-harness-portable/releases/tag/dsh-v${version}`,
    name: options.name || `DeepSeek Harness Portable ${version}`,
    assets: [
      { name: `DeepSeek-Harness-win64-v${version}.zip` },
      { name: 'SHA256SUMS.txt' },
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

test('release selection ignores drafts, foreign URLs, and malformed assets', () => {
  const releases = [
    release('0.2.0-rc.1', { draft: true }),
    release('0.1.9', { url: 'https://example.com/releases/0.1.9' }),
    { ...release('0.1.8'), assets: [{ name: 'source.zip' }] },
    { ...release('0.1.7'), assets: [{ name: 'DeepSeek-Harness-win64-v0.1.7.zip' }] },
    release('0.1.1-rc.2'),
    release('0.1.1-rc.3'),
  ]
  assert.deepEqual(selectLatestRelease(releases), {
    version: '0.1.1-rc.3',
    releaseUrl: 'https://github.com/maiziman/deepseek-harness-portable/releases/tag/dsh-v0.1.1-rc.3',
    releaseName: 'DeepSeek Harness Portable 0.1.1-rc.3',
  })
  assert.equal(isTrustedReleaseUrl('https://github.com/maiziman/deepseek-harness-portable/releases/tag/v1'), true)
  assert.equal(isTrustedReleaseUrl('https://github.com/another/repository/releases/tag/v1'), false)
})

test('an update is offered only for a newer public portable package', () => {
  assert.equal(availableUpdate('0.1.1-rc.2', [release('0.1.1-rc.2')]), null)
  assert.equal(availableUpdate('0.1.1-rc.2', [release('0.1.1-rc.3')]).version, '0.1.1-rc.3')
})

test('the update interval tolerates missing, invalid, and future state', () => {
  const now = Date.parse('2026-08-27T05:00:00Z')
  assert.equal(shouldCheck(undefined, now), true)
  assert.equal(shouldCheck('invalid', now), true)
  assert.equal(shouldCheck('2026-08-28T05:00:00Z', now), true)
  assert.equal(shouldCheck(new Date(now - CHECK_INTERVAL_MS + 1).toISOString(), now), false)
  assert.equal(shouldCheck(new Date(now - CHECK_INTERVAL_MS).toISOString(), now), true)
})
