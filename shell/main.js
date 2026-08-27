// DeepSeek Harness portable desktop shell.
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
//   DSH_SMOKE_DELAY_MS     settle time after page load, default 3500.
//   DSH_DEVTOOLS=1         open detached DevTools.
'use strict'

const { app, BrowserWindow, dialog, shell: electronShell } = require('electron')
const { spawn, execFile } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { availableUpdate, fetchPublicReleases, parseVersion, shouldCheck } = require('./update.js')

const SMOKE = process.env.DSH_SMOKE === '1'
const SMOKE_OUT = process.env.DSH_SMOKE_OUT || path.join(__dirname, 'smoke.png')
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
const NODE_EXE = path.join(ROOT, 'runtime', 'node.exe')
const DSH_BIN = path.join(ROOT, 'app', 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js')
const DSH_HOME = path.join(ROOT, 'dsh-home')
const WORKSPACE = path.join(ROOT, 'workspace')
const LOG_PATH = path.join(DSH_HOME, 'logs', 'server.log')
const MANIFEST_PATH = path.join(ROOT, 'manifest.json')
const UPDATE_STATE_PATH = path.join(DSH_HOME, 'update-state.json')
const APP_ICON = path.join(__dirname, 'icon.ico')

const URL_PATTERN = /dsh web: (http:\/\/\S+)/
const LOADING_HTML = '<!doctype html><html><head><meta charset="utf-8">'
  + '<style>body{background:#101320;color:#c8d0e8;font:16px/1.6 "Segoe UI",system-ui,sans-serif;'
  + 'display:flex;align-items:center;justify-content:center;height:100vh;margin:0}</style></head>'
  + '<body><div>正在启动 DeepSeek Harness…</div></body></html>'
const LOADING_URL = `data:text/html;charset=utf-8,${encodeURIComponent(LOADING_HTML)}`

let serverProcess = null
let mainWindow = null
let shuttingDown = false

function ensureDirs() {
  for (const dir of [DSH_HOME, WORKSPACE, path.dirname(LOG_PATH)]) fs.mkdirSync(dir, { recursive: true })
}

function appendLog(text) {
  try { fs.appendFileSync(LOG_PATH, `${text}${os.EOL}`) } catch { /* read-only fallback: log to stderr only */ }
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
  if (parseVersion(manifest.dshVersion) === null) {
    appendLog('update check skipped: manifest dshVersion is invalid')
    return
  }
  const state = readUpdateState()
  if (!shouldCheck(state.lastCheckedAt)) return

  let update = null
  try {
    update = availableUpdate(manifest.dshVersion, await fetchPublicReleases())
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
        title: 'DeepSeek Harness Portable 更新',
        message: `发现新版本 ${update.version}`,
        detail: `当前版本：${manifest.dshVersion}\n新版本：${update.version}\n\n下载前请在 GitHub Release 中核对 SHA256。更新便携版时请保留 dsh-home 和 workspace。`,
        buttons: ['打开下载页面', '稍后提醒'],
        defaultId: 0,
        cancelId: 1,
      }
    : {
        type: 'info',
        title: 'DeepSeek Harness Portable update',
        message: `Version ${update.version} is available`,
        detail: `Current version: ${manifest.dshVersion}\nNew version: ${update.version}\n\nVerify the SHA256 in the GitHub Release before updating. Preserve dsh-home and workspace when replacing the portable package.`,
        buttons: ['Open download page', 'Remind me later'],
        defaultId: 0,
        cancelId: 1,
      }
  const result = await dialog.showMessageBox(mainWindow, options)
  if (result.response === 0) await electronShell.openExternal(update.releaseUrl)
}

function killServerTree() {
  if (serverProcess === null || serverProcess.pid === undefined) return
  const pid = serverProcess.pid
  serverProcess = null
  try { execFile('taskkill', ['/PID', String(pid), '/T', '/F'], () => {}) } catch { /* process may already be gone */ }
}

function shutdown(code) {
  if (shuttingDown) return
  shuttingDown = true
  killServerTree()
  setTimeout(() => app.exit(code), 300).unref()
}

function fatal(message) {
  try { dialog.showErrorBox('DeepSeek Harness', message) } catch { /* no window yet */ }
  console.error(`dsh-shell: ${message}`)
  shutdown(1)
}

function startServer() {
  return new Promise((resolve, reject) => {
    ensureDirs()
    if (!fs.existsSync(NODE_EXE)) { reject(new Error(`missing ${NODE_EXE}`)); return }
    if (!fs.existsSync(DSH_BIN)) { reject(new Error(`missing ${DSH_BIN}; the portable app install is incomplete`)); return }

    const env = { ...process.env, DSH_HOME }
    env.PATH = [path.join(ROOT, 'runtime'), env.PATH || ''].join(path.delimiter)

    const child = spawn(NODE_EXE, [DSH_BIN, 'web', '--no-open', '--port', '0'], {
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
          resolve(match[1].replace(/\r$/u, ''))
        }
      }
    }
    child.stdout.on('data', feed)
    child.stderr.on('data', feed)
    child.on('error', (error) => { if (!child.__urlKnown) reject(error) })
    child.on('exit', (code) => {
      serverProcess = null
      if (!child.__urlKnown) reject(new Error(`dsh server exited before announcing its URL (code ${String(code)})`))
      else if (!shuttingDown) fatal(`DeepSeek Harness server stopped unexpectedly (code ${String(code)}). See ${LOG_PATH}`)
    })

    setTimeout(() => {
      if (!child.__urlKnown) reject(new Error('timed out waiting for the dsh server URL (120s); see dsh-home/logs/server.log'))
    }, 120000)
  })
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 960,
    minHeight: 600,
    show: false,
    autoHideMenuBar: true,
    backgroundColor: '#101320',
    icon: fs.existsSync(APP_ICON) ? APP_ICON : undefined,
    title: 'DeepSeek Harness',
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
  mainWindow.loadURL(LOADING_URL)
  return mainWindow
}

function serveServerUrl(url) {
  const navigate = () => {
    if (mainWindow === null || mainWindow.isDestroyed()) return
    mainWindow.webContents.once('did-finish-load', () => {
      if (mainWindow === null || mainWindow.isDestroyed()) return
      if (SMOKE) {
        setTimeout(async () => {
          try {
            const image = await mainWindow.webContents.capturePage()
            fs.mkdirSync(path.dirname(SMOKE_OUT), { recursive: true })
            fs.writeFileSync(SMOKE_OUT, image.toPNG())
            console.log(`dsh-shell smoke: wrote ${SMOKE_OUT}`)
            shutdown(0)
          } catch (error) {
            fatal(`smoke capture failed: ${error.message}`)
          }
        }, SMOKE_DELAY_MS)
      } else {
        mainWindow.show()
        mainWindow.focus()
        maybePromptForUpdate().catch((error) => appendLog(`update prompt failed: ${error.message}`))
      }
    })
    mainWindow.loadURL(url).catch((error) => fatal(`could not load ${url}: ${error.message}`))
  }
  // In smoke mode the window stays hidden; re-showing it can interfere with
  // capture on some GPUs and is unnecessary for the screenshot.
  navigate()
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
  app.on('before-quit', () => { shuttingDown = true; killServerTree() })

  app.whenReady().then(async () => {
    createWindow()
    try {
      const url = await startServer()
      serveServerUrl(url)
    } catch (error) {
      fatal(`cannot start DeepSeek Harness: ${error.message}`)
    }
  })
}
