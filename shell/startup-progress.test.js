'use strict'

const assert = require('node:assert/strict')
const path = require('node:path')
const test = require('node:test')
const {
  componentProgress,
  countProfileLinks,
  languageFor,
  loadingPage,
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
  assert.equal(stageState('ready', { locale: 'en' }).progress, 100)
})

test('component progress uses the measured completed and total counts', () => {
  assert.equal(componentProgress(0, 100), 38)
  assert.equal(componentProgress(50, 100), 53)
  assert.equal(componentProgress(100, 100), 68)
  assert.equal(componentProgress(150, 100), 68)
  assert.equal(componentProgress(4, 0), 48)
  assert.match(stageState('links', { locale: 'en', linked: 37, total: 80 }).detail, /37 of 80/u)
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

test('loading page exposes an accessible bilingual progress display', () => {
  const chinese = loadingPage({ locale: 'zh-CN', firstRun: true, startedAt: 1000 })
  assert.match(chinese, /首次启动/u)
  assert.match(chinese, /role="progressbar"/u)
  assert.match(chinese, /dshStartupProgress/u)
  assert.match(chinese, /进度只在真实启动阶段完成后推进/u)
  const english = loadingPage({ locale: 'en-US', firstRun: false, startedAt: 1000 })
  assert.match(english, /Progress advances only when a real startup milestone completes/u)
  assert.doesNotMatch(english, /首次启动/u)
})
