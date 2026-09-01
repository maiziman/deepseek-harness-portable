'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const vm = require('node:vm')

function createElement(type, props, ...children) {
  return { type, props: { ...props, children } }
}

function findElement(node, predicate) {
  if (node === null || typeof node !== 'object') return undefined
  if (predicate(node)) return node
  for (const child of node.props?.children ?? []) {
    const found = findElement(child, predicate)
    if (found !== undefined) return found
  }
}

test('the packaged client registers update and About actions on the local shell routes', () => {
  const source = fs.readFileSync(path.join(__dirname, 'lib', 'client.js'), 'utf8')
  const opened = []
  const styles = []
  let clientModule
  const window = {
    location: { href: 'http://127.0.0.1:45123/' },
    __CEDARDSH_DESKTOP_INFO__: {
      portableVersion: '1.3.0',
      dshVersion: '0.1.3',
      builtAt: '2026-08-31T10:00:00Z',
      lastCheckedAt: null,
    },
    open: (...args) => { opened.push(args) },
    __ModuleLoader__: {
      load(definition) {
        assert.equal(definition.id, '@cedardsh/desktop-update')
        clientModule = definition.factory((id) => {
          if (id === 'react') return { createElement }
          if (id === '@deepseek-ai/dsh-client-ui-primitives') {
            return { IconRefreshOutline16: props => createElement('svg', props) }
          }
          throw new Error(`unexpected client dependency ${id}`)
        })
      },
    },
  }
  const document = {
    getElementById: () => null,
    createElement: () => ({ remove() {} }),
    head: { append: style => { styles.push(style) } },
  }
  vm.runInNewContext(source, { URL, document, window })

  const registrations = new Map()
  const localeRegistrations = []
  const translations = {
    action: '更新',
    aboutNav: '关于',
    aboutTitle: 'CedarDSH Desktop',
    aboutIntro: '便携版',
    desktopVersion: '桌面版本',
    dshVersion: '官方 DSH 版本',
    builtAt: '构建时间',
    lastUpdateCheck: '上次检查更新',
    never: '尚未检查',
    releases: '查看更新内容',
    diagnostics: '复制诊断信息',
    diagnosticNote: '不包含密钥',
  }
  const ctx = {
    effect(factory) { return factory() },
    locale: {
      register: (...args) => { localeRegistrations.push(args); return () => {} },
      bind: () => key => translations[key],
    },
    slots: {
      inject(name, factory) {
        return factory()
      },
      register(options, component) {
        registrations.set(options.name, { options, component })
        return () => {}
      },
    },
  }
  assert.deepEqual([...clientModule.inject], ['slots', 'locale'])
  clientModule.apply(ctx)

  assert.equal(localeRegistrations[0][0], 'cedardsh-update')
  const update = registrations.get('sidebar.footer.action')
  const about = registrations.get('settings.section')
  assert.equal(update.options.id, 'cedardsh-update')
  assert.equal(about.options.id, 'cedardsh-about')
  assert.equal(about.options.label(), '关于')
  assert.match(styles[0].textContent, /:has\(> div > \.cedardshUpdateAnchor/u)
  assert.match(styles[0].textContent, /top: calc\(100% \+ 11px\)/u)
  const wide = update.component({ wide: true, t: () => '更新' })
  const button = findElement(wide, node => node.type === 'button')
  assert.equal(button.props['aria-label'], '更新')
  button.props.onClick()
  assert.deepEqual(opened, [[
    'http://127.0.0.1:45123/__cedardsh/update',
    'cedardsh-update',
  ]])

  const rail = update.component({ wide: false, t: () => '更新' })
  assert.match(rail.props.className, /cedardshUpdateRail/u)

  const section = about.component({ t: key => translations[key] })
  assert.equal(section.props['data-cedardsh-about'], '')
  const releases = findElement(section, node => node.props?.['data-cedardsh-releases'] === '')
  const diagnostics = findElement(section, node => node.props?.['data-cedardsh-diagnostics'] === '')
  releases.props.onClick()
  diagnostics.props.onClick()
  assert.deepEqual(opened.slice(1), [
    ['http://127.0.0.1:45123/__cedardsh/releases', 'cedardsh-releases'],
    ['http://127.0.0.1:45123/__cedardsh/diagnostics', 'cedardsh-diagnostics'],
  ])
})
