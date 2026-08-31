// CedarDSH Desktop shell for packaged DeepSeek Harness.
//
// Spawns the bundled dsh server (runtime\node.exe running the installed
// @deepseek-ai/dsh lib/bin.js with `web --no-open --port 0`) and shows the Web
// UI in a native window. The server picks a free port by itself; the shell
// resolves the printed `dsh web: http://127.0.0.1:<port>` line to learn it.
//
// The window opens immediately with a loading page so a double-click gives
// instant feedback; the server URL replaces it once the server is ready.
//
// Environment controls:
//   DSH_SMOKE=1            headless verification mode: load the UI, capture a
//                          screenshot to DSH_SMOKE_OUT, then exit 0.
//   DSH_SMOKE_OUT=<path>   screenshot destination (default: shell dir).
//   DSH_SMOKE_PROGRESS_OUT capture the rendered startup progress page too.
//   DSH_SMOKE_PROGRESS_STATE_OUT write JSON evidence for the rendered component count.
//   DSH_SMOKE_DELAY_MS     settle time after page load, default 3500.
//   DSH_DEVTOOLS=1         open detached DevTools.
'use strict'

const { app, BrowserWindow, dialog, shell: electronShell } = require('electron')
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {
  completeStartupMilestones,
  countPackageProfileLinks,
  loadingPage,
  profileInitializationState,
  stageState,
} = require('./startup-progress.js')
const { dshServerArgs, portableDshEnv } = require('./launch-args.js')
const {
  availableUpdate,
  fetchPublicReleases,
  packagedPortableVersion,
  shouldCheck,
} = require('./update.js')
const { terminateProcessTree } = require('./process-lifecycle.js')

const SMOKE = process.env.DSH_SMOKE === '1'
const SMOKE_OUT = process.env.DSH_SMOKE_OUT || path.join(__dirname, 'smoke.png')
const SMOKE_PROGRESS_OUT = process.env.DSH_SMOKE_PROGRESS_OUT || ''
const SMOKE_PROGRESS_STATE_OUT = process.env.DSH_SMOKE_PROGRESS_STATE_OUT || ''
const SMOKE_DELAY_MS = Number(process.env.DSH_SMOKE_DELAY_MS || 3500)
if (SMOKE) {
  app.disableHardwareAcceleration()
  // Isolate the single-instance lock from any real app the user runs:
  // the lock is keyed on userData, which normally resolves to one shared
  // %APPDATA% path for every copy of this shell.
  app.setPath('userData', path.join(os.tmpdir(), 'dsh-smoke-userdata'))
}

// Root of the portable distribution: directory of the executable when packed,
// otherwise the folder one level above the shell sources (dev runs).
const ROOT = app.isPackaged ? path.dirname(process.execPath) : path.resolve(__dirname, '..')
const RUNTIME_ROOT = path.join(ROOT, 'runtime')
const NODE_EXE = path.join(RUNTIME_ROOT, 'node.exe')
const DSH_BIN = path.join(ROOT, 'app', 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js')
const DSH_HOME = path.join(ROOT, 'dsh-home')
const WORKSPACE = path.join(ROOT, 'workspace')
const LOG_PATH = path.join(DSH_HOME, 'logs', 'server.log')
const MANIFEST_PATH = path.join(ROOT, 'manifest.json')
const UPDATE_STATE_PATH = path.join(DSH_HOME, 'update-state.json')
const APP_ICON = path.join(__dirname, 'icon.ico')
const PROFILE_MODULES = path.join(DSH_HOME, 'profiles', 'node_modules')
const PROFILE_MANIFEST = path.join(DSH_HOME, 'profiles', 'web', 'package.json')
const PACKAGED_MODULES = path.join(ROOT, 'app', 'node_modules')

const URL_PATTERN = /dsh web: (http:\/\/\S+)/
const STARTUP_STARTED_AT = Date.now()
const STARTUP_LINK_TOTAL = readStartupLinkTotal()
let startupInitialLinks = 0
try {
  startupInitialLinks = countPackagedProfileLinks()
} catch (error) {
  appendLog(`initial startup component count unavailable: ${error.message}`)
}
const FIRST_RUN = profileInitializationState(
  fs.existsSync(PROFILE_MANIFEST),
  startupInitialLinks,
  STARTUP_LINK_TOTAL,
).needsInitialization

let serverProcess = null
let mainWindow = null
let shuttingDown = false
let appExitAllowed = false
let startupTask = null
let startupStage = null
let startupPoller = null
let loadingPageActive = false

function ensureDirs() {
  for (const dir of [DSH_HOME, WORKSPACE, path.dirname(LOG_PATH)]) fs.mkdirSync(dir, { recursive: true })
}

function appendLog(text) {
  try { fs.appendFileSync(LOG_PATH, `${text}${os.EOL}`) } catch { /* read-only fallback: log to stderr only */ }
}

function requireActiveStartup() {
  if (shuttingDown) throw new Error('application shutdown cancelled startup')
}

function readStartupLinkTotal() {
  try {
    const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'))
    return Number.isSafeInteger(manifest.startupProfileLinkCount) && manifest.startupProfileLinkCount > 0
      ? manifest.startupProfileLinkCount
      : 0
  } catch (error) {
    appendLog(`startup component total unavailable: ${error.message}`)
    return 0
  }
}

function countPackagedProfileLinks() {
  return countPackageProfileLinks(PROFILE_MODULES, PACKAGED_MODULES, fs)
}

function setStartupStage(key, options = {}) {
  const next = stageState(key, { ...options, locale: app.getLocale(), firstRun: FIRST_RUN })
  if (startupStage !== null && next.progress < startupStage.progress) return Promise.resolve()
  startupStage = next
  if (mainWindow === null || mainWindow.isDestroyed()) return Promise.resolve()
  mainWindow.setProgressBar(next.progress / 100)
  if (!loadingPageActive) return Promise.resolve()
  const payload = JSON.stringify(next).replace(/</gu, '\\u003c')
  return mainWindow.webContents.executeJavaScript(`globalThis.dshStartupProgress?.update(${payload})`, true)
    .catch((error) => { appendLog(`startup display update failed: ${error.message}`) })
}

function stopStartupWatcher() {
  if (startupPoller !== null) clearInterval(startupPoller)
  startupPoller = null
}

function watchStartupMilestones() {
  stopStartupWatcher()
  if (!FIRST_RUN) {
    void setStartupStage('services')
    return
  }
  const expectedLinks = STARTUP_LINK_TOTAL
  let lastLinked = -1
  let countErrorReported = false
  const inspect = () => {
    try {
      const linked = countPackagedProfileLinks()
      const state = profileInitializationState(fs.existsSync(PROFILE_MANIFEST), linked, expectedLinks)
      if (state.linksComplete) {
        stopStartupWatcher()
        void setStartupStage('links', { linked, total: expectedLinks })
          .then(() => setStartupStage('services'))
        return
      }
      if (linked > 0 && linked !== lastLinked) {
        lastLinked = linked
        void setStartupStage('links', { linked, total: expectedLinks })
      }
    } catch (error) {
      if (!countErrorReported) {
        countErrorReported = true
        appendLog(`startup component progress unavailable: ${error.message}`)
      }
    }
  }
  void setStartupStage('scan')
  inspect()
  startupPoller = setInterval(inspect, 500)
  startupPoller.unref()
}

async function captureStartupProgress() {
  if (!SMOKE || !SMOKE_PROGRESS_OUT || mainWindow === null || mainWindow.isDestroyed()) return
  const targetWindow = mainWindow
  let rendered = null
  if (SMOKE_PROGRESS_STATE_OUT) {
    const deadline = Date.now() + 120000
    while (Date.now() < deadline && !targetWindow.isDestroyed()) {
      rendered = await targetWindow.webContents.executeJavaScript(`(() => {
        const history = globalThis.dshStartupProgress?.history ?? []
        for (let index = history.length - 1; index >= 0; index -= 1) {
          const state = history[index]
          if (state.key === 'links' && state.linked > 0 && state.total === ${STARTUP_LINK_TOTAL}) return state
        }
        return null
      })()`, true)
      if (rendered?.key === 'links' && rendered.linked > 0 && rendered.total === STARTUP_LINK_TOTAL) break
      await new Promise((resolve) => setTimeout(resolve, 100))
    }
    if (rendered?.key !== 'links' || rendered.linked <= 0 || rendered.total !== STARTUP_LINK_TOTAL) {
      throw new Error(`startup smoke did not render a measured component count: ${JSON.stringify(rendered)}`)
    }
    const snapshotPayload = JSON.stringify(rendered).replace(/</gu, '\\u003c')
    await targetWindow.webContents.executeJavaScript(`globalThis.dshStartupProgress.snapshot(${snapshotPayload})`, true)
  } else {
    await new Promise((resolve) => setTimeout(resolve, 500))
  }
  if (targetWindow.isDestroyed()) return
  const image = await targetWindow.webContents.capturePage()
  fs.mkdirSync(path.dirname(SMOKE_PROGRESS_OUT), { recursive: true })
  fs.writeFileSync(SMOKE_PROGRESS_OUT, image.toPNG())
  if (SMOKE_PROGRESS_STATE_OUT) {
    fs.mkdirSync(path.dirname(SMOKE_PROGRESS_STATE_OUT), { recursive: true })
    fs.writeFileSync(SMOKE_PROGRESS_STATE_OUT, `${JSON.stringify({
      expectedLinks: STARTUP_LINK_TOTAL,
      firstRun: FIRST_RUN,
      measuredLinks: countPackagedProfileLinks(),
      rendered,
    }, null, 2)}${os.EOL}`, 'utf8')
  }
  console.log(`dsh-shell smoke: wrote ${SMOKE_PROGRESS_OUT}`)
}

function readUpdateState() {
  try {
    const state = JSON.parse(fs.readFileSync(UPDATE_STATE_PATH, 'utf8'))
    return state !== null && typeof state === 'object' && !Array.isArray(state) ? state : {}
  } catch (error) {
    if (error.code !== 'ENOENT') appendLog(`update state ignored: ${error.message}`)
    return {}
  }
}

function writeUpdateState(state) {
  try {
    fs.writeFileSync(UPDATE_STATE_PATH, `${JSON.stringify(state, null, 2)}${os.EOL}`, 'utf8')
  } catch (error) {
    appendLog(`update state write failed: ${error.message}`)
  }
}

async function maybePromptForUpdate() {
  if (SMOKE || process.env.DSH_UPDATE_CHECK === '0' || !fs.existsSync(MANIFEST_PATH)) return
  let manifest
  try {
    manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'))
  } catch (error) {
    appendLog(`update check skipped: manifest unreadable: ${error.message}`)
    return
  }
  const currentPortableVersion = packagedPortableVersion(manifest)
  if (currentPortableVersion === null) {
    appendLog('update check skipped: manifest portable version is invalid')
    return
  }
  const state = readUpdateState()
  if (!shouldCheck(state.lastCheckedAt)) return

  let update = null
  try {
    update = availableUpdate(currentPortableVersion, await fetchPublicReleases())
  } catch (error) {
    appendLog(`update check failed: ${error.message}`)
  } finally {
    state.lastCheckedAt = new Date().toISOString()
    writeUpdateState(state)
  }
  if (update === null || mainWindow === null || mainWindow.isDestroyed()) return

  const locale = app.getLocale().toLowerCase()
  const isChinese = locale === 'zh' || locale.startsWith('zh-')
  const options = isChinese
    ? {
        type: 'info',
        title: 'CedarDSH Desktop 更新',
        message: `发现新版本 ${update.version}`,
        detail: `当前便携版本：${currentPortableVersion}\n新便携版本：${update.version}\n\n下载前请在 GitHub Release 中核对 SHA256。更新便携版时请保留 dsh-home 和 workspace。`,
        buttons: ['打开下载页面', '稍后提醒'],
        defaultId: 0,
        cancelId: 1,
      }
    : {
        type: 'info',
        title: 'CedarDSH Desktop update',
        message: `Version ${update.version} is available`,
        detail: `Current portable version: ${currentPortableVersion}\nNew portable version: ${update.version}\n\nVerify the SHA256 in the GitHub Release before updating. Preserve dsh-home and workspace when replacing the portable package.`,
        buttons: ['Open download page', 'Remind me later'],
        defaultId: 0,
        cancelId: 1,
      }
  const result = await dialog.showMessageBox(mainWindow, options)
  if (result.response === 0) await electronShell.openExternal(update.releaseUrl)
}

async function killServerTree() {
  const child = serverProcess
  if (child === null) return
  const terminated = await terminateProcessTree(child)
  if (!terminated) appendLog(`server process ${String(child.pid)} did not report exit after forced termination`)
  if (serverProcess === child) serverProcess = null
}

async function drainStartupAndProcesses() {
  while (startupTask !== null || serverProcess !== null) {
    const activeStartup = startupTask
    await killServerTree()
    if (activeStartup !== null) {
      try { await activeStartup } catch { /* startup owner reports failures */ }
    }
  }
}

function shutdown(code) {
  if (shuttingDown) return
  shuttingDown = true
  stopStartupWatcher()
  void drainStartupAndProcesses()
    .catch((error) => appendLog(`process shutdown failed: ${error.message}`))
    .finally(() => {
      appExitAllowed = true
      app.exit(code)
    })
}

function fatal(message) {
  try { dialog.showErrorBox('CedarDSH Desktop', message) } catch { /* no window yet */ }
  console.error(`dsh-shell: ${message}`)
  shutdown(1)
}

async function startServer() {
  requireActiveStartup()
  ensureDirs()
  await setStartupStage('folders')
  requireActiveStartup()
  if (!fs.existsSync(NODE_EXE)) throw new Error(`missing ${NODE_EXE}`)
  if (!fs.existsSync(DSH_BIN)) throw new Error(`missing ${DSH_BIN}; the portable app install is incomplete`)
  await setStartupStage('runtime')
  requireActiveStartup()

  const env = portableDshEnv(process.env, DSH_HOME, RUNTIME_ROOT)
  watchStartupMilestones()

  return new Promise((resolve, reject) => {
    requireActiveStartup()
    const child = spawn(NODE_EXE, dshServerArgs(DSH_BIN), {
      cwd: WORKSPACE,
      env,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    serverProcess = child

    let buffer = ''
    const feed = (chunk) => {
      const text = chunk.toString()
      buffer += text
      process.stdout.write(chunk)
      for (const line of text.split(/\r?\n/)) if (line.trim() !== '') appendLog(line.trim())
      if (!child.__urlKnown) {
        const match = URL_PATTERN.exec(buffer)
        if (match) {
          child.__urlKnown = true
          void completeStartupMilestones({
            firstRun: FIRST_RUN,
            total: STARTUP_LINK_TOTAL,
            countLinks: countPackagedProfileLinks,
            stopWatcher: stopStartupWatcher,
            setStage: setStartupStage,
            reportError: (error) => appendLog(`final startup component count unavailable: ${error.message}`),
          }).then(
            () => resolve(match[1].replace(/\r$/u, '')),
            reject,
          )
        }
      }
    }
    child.stdout.on('data', feed)
    child.stderr.on('data', feed)
    child.on('error', (error) => {
      if (!child.__urlKnown) {
        stopStartupWatcher()
        reject(error)
      }
    })
    child.on('exit', (code) => {
      serverProcess = null
      if (!child.__urlKnown) {
        stopStartupWatcher()
        reject(new Error(`dsh server exited before announcing its URL (code ${String(code)})`))
      }
      else if (!shuttingDown) fatal(`DeepSeek Harness server stopped unexpectedly (code ${String(code)}). See ${LOG_PATH}`)
    })

    setTimeout(() => {
      if (!child.__urlKnown) {
        stopStartupWatcher()
        reject(new Error('timed out waiting for the dsh server URL (120s); see dsh-home/logs/server.log'))
      }
    }, 120000)
  })
}

async function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 960,
    minHeight: 600,
    show: false,
    autoHideMenuBar: true,
    backgroundColor: '#101320',
    icon: fs.existsSync(APP_ICON) ? APP_ICON : undefined,
    title: 'CedarDSH Desktop',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  })
  mainWindow.on('closed', () => { mainWindow = null; shutdown(0) })
  // Instant feedback: the loading page renders immediately; show on first paint.
  mainWindow.once('ready-to-show', () => {
    if (!SMOKE) { mainWindow.show(); mainWindow.focus() }
  })
  const html = loadingPage({ locale: app.getLocale(), firstRun: FIRST_RUN, startedAt: STARTUP_STARTED_AT })
  const loadingUrl = `data:text/html;charset=utf-8,${encodeURIComponent(html)}`
  await mainWindow.loadURL(loadingUrl)
  loadingPageActive = true
  await setStartupStage('window')
  return mainWindow
}

async function serveServerUrl(url) {
  const navigate = async () => {
    if (mainWindow === null || mainWindow.isDestroyed()) return
    const targetWindow = mainWindow
    await setStartupStage('interface')
    if (targetWindow.isDestroyed() || mainWindow !== targetWindow) return
    loadingPageActive = false
    targetWindow.webContents.once('did-finish-load', () => {
      if (mainWindow !== targetWindow || targetWindow.isDestroyed()) return
      void setStartupStage('ready')
      targetWindow.setProgressBar(-1)
      if (SMOKE) {
        setTimeout(async () => {
          try {
            const image = await targetWindow.webContents.capturePage()
            fs.mkdirSync(path.dirname(SMOKE_OUT), { recursive: true })
            fs.writeFileSync(SMOKE_OUT, image.toPNG())
            console.log(`dsh-shell smoke: wrote ${SMOKE_OUT}`)
            shutdown(0)
          } catch (error) {
            fatal(`smoke capture failed: ${error.message}`)
          }
        }, SMOKE_DELAY_MS)
      } else {
        targetWindow.show()
        targetWindow.focus()
        maybePromptForUpdate().catch((error) => appendLog(`update prompt failed: ${error.message}`))
      }
    })
    await targetWindow.loadURL(url)
  }
  // In smoke mode the window stays hidden; re-showing it can interfere with
  // capture on some GPUs and is unnecessary for the screenshot.
  try {
    await navigate()
  } catch (error) {
    fatal(`could not load ${url}: ${error.message}`)
  }
}

if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  app.on('second-instance', () => {
    if (mainWindow !== null) {
      if (mainWindow.isMinimized()) mainWindow.restore()
      mainWindow.show()
      mainWindow.focus()
    }
  })
  app.on('window-all-closed', () => shutdown(0))
  app.on('before-quit', (event) => {
    if (appExitAllowed) return
    event.preventDefault()
    shutdown(0)
  })

  app.whenReady().then(() => {
    const task = (async () => {
      await createWindow()
      requireActiveStartup()
      const [url] = await Promise.all([startServer(), captureStartupProgress()])
      requireActiveStartup()
      await serveServerUrl(url)
    })()
    startupTask = task
    void task
      .catch((error) => {
        if (!shuttingDown) fatal(`cannot start DeepSeek Harness: ${error.message}`)
      })
      .finally(() => {
        if (startupTask === task) startupTask = null
      })
  })
}
