'use strict'

const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const {
  completeStartupMilestones,
  componentProgress,
  countPackageProfileLinks,
  countProfileLinks,
  languageFor,
  loadingPage,
  profileInitializationState,
  stageState,
} = require('./startup-progress.js')

function entry(name, type) {
  return {
    name,
    isDirectory: () => type === 'directory',
    isSymbolicLink: () => type === 'link',
  }
}

test('startup stages are localized and advance monotonically', () => {
  const keys = ['window', 'folders', 'runtime', 'scan', 'links', 'services', 'server', 'interface', 'ready']
  const values = keys.map((key) => stageState(key, { locale: 'zh-CN', firstRun: true }).progress)
  assert.deepEqual([...values].sort((left, right) => left - right), values)
  assert.equal(languageFor('zh-Hans'), 'zh')
  assert.equal(languageFor('en-US'), 'en')
  assert.match(stageState('runtime', { locale: 'zh-CN', firstRun: true }).detail, /首次启动/u)
  assert.equal(stageState('links', { locale: 'en', firstRun: true }).step, 3)
  assert.equal(stageState('ready', { locale: 'en' }).progress, 100)
})

test('component progress uses the measured completed and total counts', () => {
  assert.equal(componentProgress(0, 100), 38)
  assert.equal(componentProgress(50, 100), 53)
  assert.equal(componentProgress(100, 100), 68)
  assert.equal(componentProgress(150, 100), 68)
  assert.equal(componentProgress(4, 0), 48)
  const measured = stageState('links', { locale: 'en', linked: 37, total: 80 })
  assert.match(measured.detail, /37 of 80/u)
  assert.equal(measured.linked, 37)
  assert.equal(measured.total, 80)
})

test('profile link counting ignores real directories and counts scoped links', () => {
  const root = path.join('C:', 'portable', 'profiles', 'node_modules')
  const scope = path.join(root, '@deepseek-ai')
  const io = {
    existsSync: (value) => value === root,
    readdirSync: (value) => value === root
      ? [entry('@deepseek-ai', 'directory'), entry('yaml', 'link'), entry('cache', 'directory')]
      : value === scope ? [entry('dsh', 'link'), entry('dsh-base', 'link')] : [],
  }
  assert.equal(countProfileLinks(root, io), 3)
  assert.equal(countProfileLinks('missing', io), 0)
})

test('profile link counting can exclude links resolved outside the package', () => {
  const root = path.join('C:', 'portable', 'profiles', 'node_modules')
  const io = {
    existsSync: () => true,
    readdirSync: () => [entry('dsh', 'link'), entry('typescript', 'link')],
  }
  assert.equal(countProfileLinks(root, io, (linkPath) => !linkPath.endsWith('typescript')), 1)
})

test('package profile link counting follows real targets and excludes external junctions', (context) => {
  const root = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'dsh-startup-links-'))
  context.after(() => { fs.rmSync(root, { recursive: true, force: true }) })
  const packaged = path.join(root, 'package', 'app', 'node_modules')
  const profile = path.join(root, 'package', 'dsh-home', 'profiles', 'node_modules')
  const scope = path.join(profile, '@deepseek-ai')
  const external = path.join(root, 'external')
  for (const directory of [
    path.join(packaged, '@deepseek-ai', 'dsh'),
    path.join(packaged, 'yaml'),
    scope,
    external,
  ]) fs.mkdirSync(directory, { recursive: true })
  const linkType = process.platform === 'win32' ? 'junction' : 'dir'
  fs.symlinkSync(path.join(packaged, '@deepseek-ai', 'dsh'), path.join(scope, 'dsh'), linkType)
  fs.symlinkSync(path.join(packaged, 'yaml'), path.join(profile, 'yaml'), linkType)
  fs.symlinkSync(external, path.join(profile, 'external'), linkType)
  assert.equal(countPackageProfileLinks(profile, packaged), 2)
})

test('profile initialization remains active when the manifest appears before its links', () => {
  assert.deepEqual(profileInitializationState(false, 0, 100), {
    needsInitialization: true,
    linksComplete: false,
  })
  assert.deepEqual(profileInitializationState(true, 18, 100), {
    needsInitialization: true,
    linksComplete: false,
  })
  assert.deepEqual(profileInitializationState(true, 100, 100), {
    needsInitialization: false,
    linksComplete: true,
  })
  assert.deepEqual(profileInitializationState(true, 100, 0), {
    needsInitialization: false,
    linksComplete: false,
  })
})

test('server readiness samples links before stopping a watcher that has not ticked', async () => {
  const events = []
  const linked = await completeStartupMilestones({
    firstRun: true,
    total: 482,
    countLinks: () => { events.push('sample'); return 482 },
    stopWatcher: () => { events.push('stop') },
    setStage: async (key, options) => { events.push([key, options]) },
    reportError: (error) => { throw error },
  })
  assert.equal(linked, 482)
  assert.deepEqual(events, [
    'sample',
    'stop',
    ['links', { linked: 482, total: 482 }],
    ['services', undefined],
    ['server', undefined],
  ])
})

test('loading page exposes an accessible bilingual progress display', () => {
  const chinese = loadingPage({ locale: 'zh-CN', firstRun: true, startedAt: 1000 })
  assert.match(chinese, /首次启动/u)
  assert.match(chinese, /role="progressbar"/u)
  assert.match(chinese, /dshStartupProgress/u)
  assert.match(chinese, /progressApi\.current = state/u)
  assert.match(chinese, /history: \[\]/u)
  assert.match(chinese, /snapshot: \(state\) => render\(state, true\)/u)
  assert.match(chinese, /进度只在真实启动阶段完成后推进/u)
  assert.match(chinese, /img-src data:/u)
  assert.match(chinese, /<img class="mark" src="data:image\/svg\+xml;base64,/u)
  assert.match(chinese, /DEEPSEEK HARNESS · COMMUNITY PORTABLE/u)
  assert.doesNotMatch(chinese, /class="mark">DSH/u)
  const english = loadingPage({ locale: 'en-US', firstRun: false, startedAt: 1000 })
  assert.match(english, /Progress advances only when a real startup milestone completes/u)
  assert.doesNotMatch(english, /首次启动/u)
})

test('startup mark preserves the official DeepSeek favicon geometry', () => {
  const svg = fs.readFileSync(path.join(__dirname, 'deepseek-mark.svg'), 'utf8')
  const viewBox = svg.match(/viewBox="([^"]+)"/u)?.[1]
  const pathData = svg.match(/<path d="([^"]+)"/u)?.[1]
  assert.equal(viewBox, '0 0 50 50')
  assert.match(svg, /<path d="[^"]+" fill="#fff"\/>/u)
  assert.equal(
    crypto.createHash('sha256').update(`${viewBox}\0${pathData}`).digest('hex'),
    '48a0379e7aa797840a15677d8cf84164ed0ab6172d050c8a41fd18491c155cf3',
  )
})
