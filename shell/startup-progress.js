/**
 * Startup progress model and self-contained loading page for the portable
 * desktop shell. Progress values represent observed milestones, not a time
 * estimate.
 * @module startup-progress
 */
'use strict'

const fs = require('node:fs')
const path = require('node:path')

const DEEPSEEK_MARK = `data:image/svg+xml;base64,${fs.readFileSync(path.join(__dirname, 'deepseek-mark.svg')).toString('base64')}`

const TOTAL_STEPS = 5
const STAGES = Object.freeze({
  window: { progress: 6, step: 1 },
  folders: { progress: 14, step: 1 },
  runtime: { progress: 24, step: 2 },
  scan: { progress: 34, step: 2 },
  links: { progress: 48, step: 2 },
  services: { progress: 78, step: 4 },
  server: { progress: 92, step: 4 },
  interface: { progress: 97, step: 5 },
  ready: { progress: 100, step: 5 },
})

const COPY = Object.freeze({
  en: {
    window: ['Opening DeepSeek Harness', 'Preparing the startup display.'],
    folders: ['Preparing portable data', 'Settings, logs, and workspaces stay beside the app.'],
    runtime: ['Starting the bundled runtime', 'Loading the local profile.'],
    runtimeFirst: ['Starting the bundled runtime', 'First launch is preparing your local profile.'],
    scan: ['Checking bundled components', 'Windows security scanning can extend this step.'],
    links: ['Linking bundled components', 'Preparing the local component links used by the profile.'],
    services: ['Starting the local service', 'The local profile is ready. Loading the Web service.'],
    server: ['Local service is ready', 'Connecting the desktop window.'],
    interface: ['Loading the workspace interface', 'The startup display closes after the interface renders.'],
    ready: ['DeepSeek Harness is ready', 'Startup completed.'],
    steps: ['Prepare portable data', 'Check bundled components', 'Initialize local profile', 'Start local service', 'Load workspace interface'],
    brand: 'DEEPSEEK HARNESS · COMMUNITY PORTABLE',
    badgeFirst: 'First launch',
    badgeRegular: 'Starting',
    elapsed: 'Elapsed',
    step: 'Step',
    noteFirst: 'Progress advances only when a real startup milestone completes. First launch and Windows security scanning can take longer.',
    noteRegular: 'Progress advances only when a real startup milestone completes.',
  },
  zh: {
    window: ['正在打开 DeepSeek Harness', '正在准备启动界面。'],
    folders: ['正在准备便携数据', '设置、日志和工作区数据都保留在程序旁。'],
    runtime: ['正在启动内置运行时', '正在载入本地 profile。'],
    runtimeFirst: ['正在启动内置运行时', '首次启动正在准备本地 profile。'],
    scan: ['正在检查内置组件', 'Windows 安全扫描可能会延长此步骤。'],
    links: ['正在连接内置组件', '正在准备 profile 使用的本地组件链接。'],
    services: ['正在启动本地服务', '本地 profile 已准备，正在加载 Web 服务。'],
    server: ['本地服务已就绪', '正在连接桌面窗口。'],
    interface: ['正在加载工作区界面', '界面渲染完成后，启动页会自动关闭。'],
    ready: ['DeepSeek Harness 已就绪', '启动完成。'],
    steps: ['准备便携数据', '检查内置组件', '初始化本地 profile', '启动本地服务', '加载工作区界面'],
    brand: 'DEEPSEEK HARNESS · COMMUNITY PORTABLE',
    badgeFirst: '首次启动',
    badgeRegular: '正在启动',
    elapsed: '已等待',
    step: '步骤',
    noteFirst: '进度只在真实启动阶段完成后推进；首次启动和 Windows 安全扫描可能延长等待。',
    noteRegular: '进度只在真实启动阶段完成后推进。',
  },
})

/**
 * Select the startup-page language from an Electron locale.
 * @param {string} locale Electron locale text.
 * @returns {'zh' | 'en'} Supported startup-page language.
 */
function languageFor(locale) {
  const normalized = typeof locale === 'string' ? locale.toLowerCase() : ''
  return normalized === 'zh' || normalized.startsWith('zh-') ? 'zh' : 'en'
}

/**
 * Map a measured component-link count into the component stage range.
 * @param {number} linked Completed component links.
 * @param {number} total Expected component links recorded by the build.
 * @returns {number} Progress percentage from 38 through 68.
 */
function componentProgress(linked, total) {
  if (!Number.isSafeInteger(total) || total <= 0) return STAGES.links.progress
  const complete = Number.isSafeInteger(linked) ? Math.min(Math.max(linked, 0), total) : 0
  return 38 + Math.round((30 * complete) / total)
}

/**
 * Resolve one localized startup milestone for display.
 * @param {string} key Milestone identifier.
 * @param {{locale?: string, firstRun?: boolean, linked?: number, total?: number}} options Display context.
 * @returns {{key: string, title: string, detail: string, progress: number, step: number, totalSteps: number}} Display state.
 */
function stageState(key, options = {}) {
  const stage = STAGES[key]
  if (stage === undefined) throw new Error(`unknown startup stage: ${key}`)
  const language = languageFor(options.locale)
  const copy = COPY[language]
  const copyKey = key === 'runtime' && options.firstRun ? 'runtimeFirst' : key
  const [title, defaultDetail] = copy[copyKey]
  const linked = Number.isSafeInteger(options.linked) ? options.linked : 0
  const total = Number.isSafeInteger(options.total) ? options.total : 0
  const detail = key === 'links' && total > 0
    ? language === 'zh' ? `已准备 ${Math.min(linked, total)} / ${total} 个组件。` : `${Math.min(linked, total)} of ${total} components ready.`
    : key === 'links' && linked > 0
      ? language === 'zh' ? `已准备 ${linked} 个组件。` : `${linked} components ready.`
      : defaultDetail
  return {
    key,
    title,
    detail,
    progress: key === 'links' ? componentProgress(linked, total) : stage.progress,
    step: stage.step,
    totalSteps: TOTAL_STEPS,
  }
}

/**
 * Count the flat unscoped and one-level scoped links in the profile fallback.
 * @param {string} modulesDir Profile fallback node_modules directory.
 * @param {object} io Filesystem implementation; replaceable for tests.
 * @returns {number} Completed component-link count.
 */
function countProfileLinks(modulesDir, io = fs) {
  if (!io.existsSync(modulesDir)) return 0
  let count = 0
  for (const entry of io.readdirSync(modulesDir, { withFileTypes: true })) {
    if (entry.isSymbolicLink()) {
      count += 1
      continue
    }
    if (!entry.isDirectory() || !entry.name.startsWith('@')) continue
    const scopeDir = path.join(modulesDir, entry.name)
    for (const child of io.readdirSync(scopeDir, { withFileTypes: true })) {
      if (child.isSymbolicLink()) count += 1
    }
  }
  return count
}

function safeJson(value) {
  return JSON.stringify(value).replace(/</gu, '\\u003c')
}

/**
 * Render the isolated startup page loaded before the local service starts.
 * @param {{locale?: string, firstRun?: boolean, startedAt?: number}} options Page context.
 * @returns {string} Complete HTML document.
 */
function loadingPage(options) {
  const language = languageFor(options.locale)
  const copy = COPY[language]
  const firstRun = options.firstRun === true
  const startedAt = Number.isFinite(options.startedAt) ? options.startedAt : Date.now()
  const initial = stageState('window', { locale: language, firstRun })
  const pageState = {
    initial,
    startedAt,
    elapsedLabel: copy.elapsed,
    stepLabel: copy.step,
    steps: copy.steps,
  }
  const badge = firstRun ? copy.badgeFirst : copy.badgeRegular
  const note = firstRun ? copy.noteFirst : copy.noteRegular
  const lang = language === 'zh' ? 'zh-CN' : 'en'
  return `<!doctype html>
<html lang="${lang}">
<head>
  <meta charset="utf-8">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${copy.brand}</title>
  <style>
    :root{color-scheme:dark;font-family:"Segoe UI Variable","Segoe UI",system-ui,sans-serif;background:#080c18;color:#f7f9ff}
    *{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;overflow:hidden;background:radial-gradient(circle at 76% 9%,rgba(53,99,255,.24),transparent 34%),radial-gradient(circle at 10% 100%,rgba(56,73,171,.19),transparent 38%),#080c18}
    body:before{content:"";position:fixed;inset:0;pointer-events:none;background-image:linear-gradient(rgba(255,255,255,.018) 1px,transparent 1px),linear-gradient(90deg,rgba(255,255,255,.018) 1px,transparent 1px);background-size:48px 48px;mask-image:linear-gradient(to bottom,black,transparent 88%)}
    .shell{width:min(760px,calc(100vw - 72px));padding:46px 50px 40px;border:1px solid rgba(139,162,255,.18);border-radius:24px;background:linear-gradient(145deg,rgba(19,27,53,.96),rgba(10,15,31,.96));box-shadow:0 28px 90px rgba(0,0,0,.42),inset 0 1px rgba(255,255,255,.035)}
    .brand{display:flex;align-items:center;gap:14px;margin-bottom:40px}.mark{display:block;flex:0 0 auto;width:46px;height:46px;object-fit:contain;filter:drop-shadow(0 9px 18px rgba(72,107,254,.34))}.brand-text{font-size:13px;letter-spacing:.14em;color:#bdc9ee;font-weight:650}.badge{margin-left:auto;border:1px solid rgba(126,151,255,.25);border-radius:999px;padding:7px 11px;background:rgba(74,101,218,.12);font-size:12px;color:#cbd6ff}
    h1{font-size:28px;line-height:1.25;letter-spacing:-.02em;margin:0 0 10px}#detail{min-height:27px;margin:0;color:#aebbdc;font-size:15px;line-height:1.7}
    .meter-meta{display:flex;justify-content:space-between;margin:30px 0 10px;color:#8fa1ce;font-size:12px;font-variant-numeric:tabular-nums}.track{height:10px;border-radius:999px;background:#1b2543;overflow:hidden;box-shadow:inset 0 1px 3px rgba(0,0,0,.5)}#bar{height:100%;width:0;border-radius:inherit;background:linear-gradient(90deg,#4267e8,#75a0ff);box-shadow:0 0 24px rgba(91,130,255,.58);transition:width .48s cubic-bezier(.2,.75,.25,1)}
    .steps{display:grid;grid-template-columns:repeat(5,1fr);gap:10px;list-style:none;padding:0;margin:28px 0 30px}.steps li{position:relative;padding-top:17px;color:#68779c;font-size:11px;line-height:1.35}.steps li:before{content:"";position:absolute;left:0;top:0;width:7px;height:7px;border-radius:50%;background:#34405f;box-shadow:0 0 0 4px rgba(52,64,95,.16)}.steps li.active{color:#e0e7ff}.steps li.active:before{background:#79a0ff;box-shadow:0 0 0 4px rgba(92,132,255,.18),0 0 17px rgba(92,132,255,.8)}.steps li.done{color:#93a5d0}.steps li.done:before{background:#5275e5}
    .footer{display:flex;align-items:flex-start;justify-content:space-between;gap:30px;padding-top:22px;border-top:1px solid rgba(133,150,204,.13)}.note{max-width:520px;margin:0;color:#7f8caf;font-size:12px;line-height:1.6}#elapsed{white-space:nowrap;color:#a9b8dd;font-size:12px;font-variant-numeric:tabular-nums}
  </style>
</head>
<body>
  <main class="shell">
    <div class="brand"><img class="mark" src="${DEEPSEEK_MARK}" alt="" aria-hidden="true"><div class="brand-text">${copy.brand}</div><div class="badge">${badge}</div></div>
    <h1 id="status"></h1><p id="detail"></p>
    <div class="meter-meta"><span id="step"></span><span id="percent"></span></div>
    <div id="track" class="track" role="progressbar" aria-valuemin="0" aria-valuemax="100"><div id="bar"></div></div>
    <ol id="steps" class="steps"></ol>
    <div class="footer"><p class="note">${note}</p><span id="elapsed"></span></div>
  </main>
  <script>
    (() => {
      const page = ${safeJson(pageState)}
      const status = document.getElementById('status')
      const detail = document.getElementById('detail')
      const step = document.getElementById('step')
      const percent = document.getElementById('percent')
      const track = document.getElementById('track')
      const bar = document.getElementById('bar')
      const steps = document.getElementById('steps')
      const elapsed = document.getElementById('elapsed')
      for (const label of page.steps) {
        const item = document.createElement('li')
        item.textContent = label
        steps.appendChild(item)
      }
      let currentProgress = -1
      const render = (state) => {
        if (state.progress < currentProgress) return
        currentProgress = state.progress
        status.textContent = state.title
        detail.textContent = state.detail
        step.textContent = page.stepLabel + ' ' + state.step + ' / ' + state.totalSteps
        percent.textContent = state.progress + '%'
        track.setAttribute('aria-valuenow', String(state.progress))
        bar.style.width = state.progress + '%'
        for (let index = 0; index < steps.children.length; index += 1) {
          const number = index + 1
          steps.children[index].className = number < state.step ? 'done' : number === state.step ? 'active' : ''
        }
      }
      const renderElapsed = () => {
        const total = Math.max(0, Math.floor((Date.now() - page.startedAt) / 1000))
        const value = total < 60 ? total + (document.documentElement.lang.startsWith('zh') ? ' 秒' : 's') : Math.floor(total / 60) + (document.documentElement.lang.startsWith('zh') ? ' 分 ' : 'm ') + total % 60 + (document.documentElement.lang.startsWith('zh') ? ' 秒' : 's')
        elapsed.textContent = page.elapsedLabel + ' ' + value
      }
      globalThis.dshStartupProgress = { update: render }
      render(page.initial)
      renderElapsed()
      setInterval(renderElapsed, 1000)
    })()
  </script>
</body>
</html>`
}

module.exports = {
  componentProgress,
  countProfileLinks,
  languageFor,
  loadingPage,
  stageState,
}
