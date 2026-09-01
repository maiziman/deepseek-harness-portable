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

const { app, BrowserWindow, clipboard, dialog, shell: electronShell } = require('electron')
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
const { formatDiagnostics } = require('./diagnostics.js')
const {
  availableUpdate,
  fetchPublicReleases,
  packagedPortableVersion,
  shouldCheck,
} = require('./update.js')
const {
  assertNoOwnershipCollisions,
  downloadReleaseAsset,
  formatBytes,
  isDesktopRequest,
  isDesktopUpdateRequest,
  ownedTopLevelEntries,
  removeUpdateTree,
  updateWorkDirectory,
  validateStagedPackage,
} = require('./update-install.js')
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
const UPDATE_PATCH_PATH = path.join(__dirname, 'cedardsh.patch.yml')
const UPDATE_HELPER_PATH = path.join(__dirname, 'update-helper.ps1')
const DIAGNOSTICS_REQUEST_PATH = '/__cedardsh/diagnostics'
const RELEASES_REQUEST_PATH = '/__cedardsh/releases'
const RELEASES_URL = 'https://github.com/maiziman/cedardsh-desktop/releases'
const APP_ICON = path.join(__dirname, 'icon.ico')
const PROFILE_MODULES = path.join(DSH_HOME, 'profiles', 'node_modules')
const PROFILE_MANIFEST = path.join(DSH_HOME, 'profiles', 'web', 'package.json')
const PACKAGED_MODULES = path.join(ROOT, 'app', 'node_modules')
const UPDATE_PLUGIN_PACKAGE = app.isPackaged
  ? path.join(PACKAGED_MODULES, '@cedardsh', 'desktop-update')
  : path.resolve(__dirname, '..', 'plugin', 'desktop-update')
const UPDATE_PLUGIN_LINK = path.join(PROFILE_MODULES, '@cedardsh', 'desktop-update')
const POWERSHELL_EXE = path.join(
  process.env.SystemRoot || 'C:\\Windows',
  'System32',
  'WindowsPowerShell',
  'v1.0',
  'powershell.exe',
)

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
let serverPageUrl = null
let updateProgressWindow = null
let updateTask = null

function ensureDirs() {
  for (const dir of [DSH_HOME, WORKSPACE, path.dirname(LOG_PATH)]) fs.mkdirSync(dir, { recursive: true })
  ensureUpdatePluginLink()
}

function ensureUpdatePluginLink() {
  if (!fs.existsSync(path.join(UPDATE_PLUGIN_PACKAGE, 'package.json'))) {
    throw new Error(`missing CedarDSH update package: ${UPDATE_PLUGIN_PACKAGE}`)
  }
  fs.mkdirSync(path.dirname(UPDATE_PLUGIN_LINK), { recursive: true })
  let current
  try {
    current = fs.lstatSync(UPDATE_PLUGIN_LINK)
  } catch (error) {
    if (error.code !== 'ENOENT') throw error
  }
  if (current !== undefined) {
    if (!current.isSymbolicLink()) {
      throw new Error(`${UPDATE_PLUGIN_LINK} exists and is not a CedarDSH-managed link`)
    }
    const linked = path.resolve(path.dirname(UPDATE_PLUGIN_LINK), fs.readlinkSync(UPDATE_PLUGIN_LINK))
    if (linked === path.resolve(UPDATE_PLUGIN_PACKAGE)) return
    fs.unlinkSync(UPDATE_PLUGIN_LINK)
  }
  fs.symlinkSync(UPDATE_PLUGIN_PACKAGE, UPDATE_PLUGIN_LINK, 'junction')
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

function readDesktopInfo() {
  const { manifest, currentPortableVersion } = readPackagedManifest()
  const state = readUpdateState()
  const serverLogStat = fs.existsSync(LOG_PATH) ? fs.statSync(LOG_PATH) : null
  return {
    portableVersion: currentPortableVersion,
    dshVersion: manifest.dshVersion,
    nodeVersion: manifest.nodeVersion,
    electronVersion: process.versions.electron,
    windowsVersion: os.release(),
    architecture: process.arch,
    builtAt: manifest.builtAt,
    lastCheckedAt: typeof state.lastCheckedAt === 'string' ? state.lastCheckedAt : null,
    profileInitialized: fs.existsSync(PROFILE_MANIFEST),
    serverRunning: serverProcess !== null,
    serverLog: serverLogStat === null
      ? { exists: false, size: 0, modifiedAt: null }
      : { exists: true, size: serverLogStat.size, modifiedAt: serverLogStat.mtime.toISOString() },
  }
}

async function publishDesktopInfo(targetWindow) {
  const payload = JSON.stringify(readDesktopInfo()).replace(/</gu, '\\u003c')
  await targetWindow.webContents.executeJavaScript(
    `globalThis.__CEDARDSH_DESKTOP_INFO__=${payload}`,
    true,
  )
}

async function copyDesktopDiagnostics() {
  const report = formatDiagnostics({
    ...readDesktopInfo(),
    generatedAt: new Date().toISOString(),
  })
  await clipboard.writeText(report)
  const chinese = app.getLocale().toLowerCase().startsWith('zh')
  await dialog.showMessageBox(mainWindow, {
    type: 'info',
    title: chinese ? 'CedarDSH Desktop 诊断信息' : 'CedarDSH Desktop diagnostics',
    message: chinese ? '诊断信息已复制' : 'Diagnostics copied',
    detail: chinese
      ? '可以直接粘贴到 GitHub Issue。内容不包含日志正文、API 密钥或访问令牌。'
      : 'Paste it into a GitHub Issue. It contains no log text, API keys, or access tokens.',
    buttons: ['OK'],
  })
}

function updateCopy() {
  const locale = app.getLocale().toLowerCase()
  const chinese = locale === 'zh' || locale.startsWith('zh-')
  return chinese
    ? {
        title: 'CedarDSH Desktop 更新',
        checking: '正在检查官方更新…',
        downloading: '正在下载官方主程序…',
        preparing: '正在校验并准备更新…',
        restarting: '更新已准备完成，正在重启…',
        preserved: '会话历史、模型设置、凭据、插件和工作区都会保留。',
        available: version => `发现新版本 ${version}`,
        current: '当前版本',
        next: '新版本',
        install: '立即更新',
        later: '稍后',
        latest: '已经是最新版本',
        latestDetail: (portableVersion, dshVersion) => `CedarDSH Desktop ${portableVersion}\n官方 DSH ${dshVersion}`,
        failed: '更新失败',
      }
    : {
        title: 'CedarDSH Desktop update',
        checking: 'Checking for an official update…',
        downloading: 'Downloading the official application…',
        preparing: 'Verifying and preparing the update…',
        restarting: 'Update is ready. Restarting…',
        preserved: 'Session history, model settings, credentials, plugins, and workspaces will be preserved.',
        available: version => `Version ${version} is available`,
        current: 'Current version',
        next: 'New version',
        install: 'Update now',
        later: 'Later',
        latest: 'You are up to date',
        latestDetail: (portableVersion, dshVersion) => `CedarDSH Desktop ${portableVersion}\nOfficial DSH ${dshVersion}`,
        failed: 'Update failed',
      }
}

function updateProgressPage(copy) {
  return `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{color-scheme:dark;font-family:"Segoe UI",system-ui,sans-serif}*{box-sizing:border-box}body{margin:0;background:#15171d;color:#f4f5f7}.card{padding:28px 30px}.title{font-size:18px;font-weight:600}.stage{margin-top:18px;font-size:14px}.track{height:8px;margin-top:16px;overflow:hidden;border-radius:99px;background:#30343d}.bar{width:18%;height:100%;border-radius:99px;background:linear-gradient(90deg,#75b4ff,#4f7df3);transition:width .15s ease}.bar.indeterminate{animation:scan 1.2s ease-in-out infinite}@keyframes scan{0%{transform:translateX(-120%)}100%{transform:translateX(620%)}}.detail{min-height:20px;margin-top:10px;color:#aeb5c2;font-size:12px;font-variant-numeric:tabular-nums}.note{margin-top:20px;color:#8f98a8;font-size:12px;line-height:18px}
</style></head><body><main class="card"><div class="title">${copy.title}</div><div id="stage" class="stage">${copy.checking}</div><div class="track"><div id="bar" class="bar indeterminate"></div></div><div id="detail" class="detail"></div><div class="note">${copy.preserved}</div></main>
<script>globalThis.cedardshUpdateProgress=(state)=>{document.getElementById('stage').textContent=state.stage;document.getElementById('detail').textContent=state.detail||'';const bar=document.getElementById('bar');if(state.percent===null){bar.classList.add('indeterminate');bar.style.width='18%'}else{bar.classList.remove('indeterminate');bar.style.transform='none';bar.style.width=Math.max(0,Math.min(100,state.percent))+'%'}}</script></body></html>`
}

async function openUpdateProgress(stage) {
  if (updateProgressWindow !== null && !updateProgressWindow.isDestroyed()) {
    updateProgressWindow.focus()
    await setUpdateProgress(stage)
    return
  }
  const copy = updateCopy()
  const progressWindow = new BrowserWindow({
    parent: mainWindow ?? undefined,
    modal: mainWindow !== null,
    width: 470,
    height: 235,
    resizable: false,
    minimizable: false,
    maximizable: false,
    closable: false,
    autoHideMenuBar: true,
    show: false,
    backgroundColor: '#15171d',
    title: copy.title,
    icon: fs.existsSync(APP_ICON) ? APP_ICON : undefined,
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true },
  })
  updateProgressWindow = progressWindow
  progressWindow.on('closed', () => {
    if (updateProgressWindow === progressWindow) updateProgressWindow = null
  })
  await progressWindow.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(updateProgressPage(copy))}`)
  if (progressWindow.isDestroyed()) return
  progressWindow.show()
  await setUpdateProgress(stage)
}

async function setUpdateProgress(stage, progress = null) {
  const target = updateProgressWindow
  if (target === null || target.isDestroyed()) return
  const percent = progress === null ? null : Math.round((progress.transferred / progress.total) * 1000) / 10
  const detail = progress === null ? '' : `${formatBytes(progress.transferred)} / ${formatBytes(progress.total)} · ${percent.toFixed(1)}%`
  const payload = JSON.stringify({ stage, detail, percent }).replace(/</gu, '\\u003c')
  await target.webContents.executeJavaScript(`globalThis.cedardshUpdateProgress(${payload})`, true)
    .catch((error) => appendLog(`update progress display failed: ${error.message}`))
  if (mainWindow !== null && !mainWindow.isDestroyed()) {
    if (percent === null) mainWindow.setProgressBar(2, { mode: 'indeterminate' })
    else mainWindow.setProgressBar(percent / 100)
  }
}

function closeUpdateProgress() {
  if (updateProgressWindow !== null && !updateProgressWindow.isDestroyed()) updateProgressWindow.destroy()
  updateProgressWindow = null
  if (mainWindow !== null && !mainWindow.isDestroyed()) mainWindow.setProgressBar(-1)
}

function runPowerShell(scriptPath, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(POWERSHELL_EXE, [
      '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', scriptPath,
      ...args,
    ], { windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] })
    let stderr = ''
    child.stderr.on('data', chunk => { stderr += chunk.toString() })
    child.on('error', reject)
    child.on('exit', (code) => {
      if (code === 0) resolve()
      else reject(new Error(stderr.trim() || `PowerShell exited with code ${String(code)}`))
    })
  })
}

function launchDetachedUpdater(helperPath, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(POWERSHELL_EXE, [
      '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', helperPath,
      ...args,
    ], { detached: true, windowsHide: true, stdio: 'ignore' })
    child.once('error', reject)
    child.once('spawn', () => {
      child.unref()
      resolve()
    })
  })
}

function readPackagedManifest() {
  const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'))
  const currentPortableVersion = packagedPortableVersion(manifest)
  if (currentPortableVersion === null) throw new Error('manifest portable version is invalid')
  return { manifest, currentPortableVersion }
}

async function checkForUpdate(respectInterval) {
  const { manifest, currentPortableVersion } = readPackagedManifest()
  const state = readUpdateState()
  if (respectInterval && !shouldCheck(state.lastCheckedAt)) {
    return { skipped: true, manifest, currentPortableVersion, update: null }
  }
  try {
    const update = availableUpdate(currentPortableVersion, await fetchPublicReleases())
    return { skipped: false, manifest, currentPortableVersion, update }
  } finally {
    state.lastCheckedAt = new Date().toISOString()
    writeUpdateState(state)
    if (mainWindow !== null && !mainWindow.isDestroyed()) {
      void publishDesktopInfo(mainWindow)
        .catch(error => appendLog(`desktop info refresh failed: ${error.message}`))
    }
  }
}

async function stageAndLaunchUpdate(update, currentManifest) {
  if (!fs.existsSync(UPDATE_HELPER_PATH)) throw new Error(`update helper is missing: ${UPDATE_HELPER_PATH}`)
  if (!fs.existsSync(POWERSHELL_EXE)) throw new Error(`Windows PowerShell is missing: ${POWERSHELL_EXE}`)
  ownedTopLevelEntries(currentManifest)

  const versionRoot = updateWorkDirectory(ROOT, update.version)
  fs.mkdirSync(versionRoot, { recursive: true })
  const work = fs.mkdtempSync(path.join(versionRoot, 'run-'))
  try {
    const archive = path.join(work, update.asset.name)
    let lastProgressAt = 0
    await downloadReleaseAsset(update.asset, archive, {
      onProgress: (progress) => {
        const now = Date.now()
        if (progress.transferred !== progress.total && now - lastProgressAt < 100) return
        lastProgressAt = now
        void setUpdateProgress(updateCopy().downloading, progress)
      },
    })

    await setUpdateProgress(updateCopy().preparing)
    const extractRoot = path.join(work, 'extract')
    await runPowerShell(UPDATE_HELPER_PATH, [
      '-Mode', 'Extract',
      '-ArchivePath', archive,
      '-DestinationPath', extractRoot,
    ])
    const extracted = fs.readdirSync(extractRoot)
    if (extracted.length !== 1 || extracted[0] !== 'CedarDSH-Desktop') {
      throw new Error('update ZIP must contain exactly one CedarDSH-Desktop directory')
    }
    const stagedRoot = path.join(extractRoot, 'CedarDSH-Desktop')
    const stagedManifest = validateStagedPackage(stagedRoot, update.version)
    assertNoOwnershipCollisions(ROOT, currentManifest, stagedManifest)

    const helperCopy = path.join(os.tmpdir(), `cedardsh-update-helper-${process.pid}-${Date.now()}.ps1`)
    fs.copyFileSync(UPDATE_HELPER_PATH, helperCopy)
    await launchDetachedUpdater(helperCopy, [
      '-Mode', 'Install',
      '-RootPath', ROOT,
      '-StagedRootPath', stagedRoot,
      '-WorkPath', work,
      '-ParentProcessId', String(process.pid),
    ])
    return stagedManifest
  } catch (error) {
    try {
      removeUpdateTree(work)
    } catch (cleanupError) {
      appendLog(`update staging cleanup failed: ${cleanupError.message}`)
    }
    throw error
  }
}

async function offerUpdate(update, currentPortableVersion, currentManifest) {
  const copy = updateCopy()
  const answer = await dialog.showMessageBox(mainWindow, {
    type: 'info',
    title: copy.title,
    message: copy.available(update.version),
    detail: `${copy.current}: ${currentPortableVersion}\n${copy.next}: ${update.version} (${formatBytes(update.asset.size)})\n\n${copy.preserved}`,
    buttons: [copy.install, copy.later],
    defaultId: 0,
    cancelId: 1,
  })
  if (answer.response !== 0) return false

  await openUpdateProgress(copy.downloading)
  const stagedManifest = await stageAndLaunchUpdate(update, currentManifest)
  await setUpdateProgress(`${copy.restarting}\nDSH ${stagedManifest.dshVersion}`, {
    transferred: update.asset.size,
    total: update.asset.size,
  })
  shutdown(0)
  return true
}

function showUpdateFailure(error) {
  closeUpdateProgress()
  const message = error instanceof Error ? error.message : String(error)
  appendLog(`update failed: ${message}`)
  dialog.showErrorBox(updateCopy().failed, message)
}

async function performManualUpdate() {
  const copy = updateCopy()
  await openUpdateProgress(copy.checking)
  const result = await checkForUpdate(false)
  closeUpdateProgress()
  if (result.update === null) {
    await dialog.showMessageBox(mainWindow, {
      type: 'info',
      title: copy.title,
      message: copy.latest,
      detail: copy.latestDetail(result.currentPortableVersion, result.manifest.dshVersion),
      buttons: ['OK'],
    })
    return
  }
  await offerUpdate(result.update, result.currentPortableVersion, result.manifest)
}

function startUpdateTask(taskFactory, onError, focusExisting) {
  if (updateTask !== null) {
    if (focusExisting && updateProgressWindow !== null && !updateProgressWindow.isDestroyed()) {
      updateProgressWindow.focus()
    }
    return false
  }
  const task = taskFactory()
  updateTask = task
  void task
    .catch(onError)
    .finally(() => {
      if (updateTask === task) updateTask = null
    })
  return true
}

function requestManualUpdate() {
  startUpdateTask(performManualUpdate, showUpdateFailure, true)
}

async function performAutomaticUpdate() {
  let result
  try {
    result = await checkForUpdate(true)
  } catch (error) {
    appendLog(`update check failed: ${error.message}`)
    return
  }
  if (result.skipped || result.update === null || mainWindow === null || mainWindow.isDestroyed()) return
  try {
    await offerUpdate(result.update, result.currentPortableVersion, result.manifest)
  } catch (error) {
    showUpdateFailure(error)
  }
}

function requestAutomaticUpdate() {
  if (SMOKE || process.env.DSH_UPDATE_CHECK === '0' || !fs.existsSync(MANIFEST_PATH)) return
  startUpdateTask(
    performAutomaticUpdate,
    error => appendLog(`update prompt failed: ${error.message}`),
    false,
  )
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
  console.error(`dsh-shell: ${message}`)
  if (!SMOKE) {
    try { dialog.showErrorBox('CedarDSH Desktop', message) } catch { /* no window yet */ }
  }
  shutdown(1)
}

async function startServer() {
  requireActiveStartup()
  ensureDirs()
  await setStartupStage('folders')
  requireActiveStartup()
  if (!fs.existsSync(NODE_EXE)) throw new Error(`missing ${NODE_EXE}`)
  if (!fs.existsSync(DSH_BIN)) throw new Error(`missing ${DSH_BIN}; the portable app install is incomplete`)
  if (!fs.existsSync(UPDATE_PATCH_PATH)) throw new Error(`missing ${UPDATE_PATCH_PATH}`)
  await setStartupStage('runtime')
  requireActiveStartup()

  const env = portableDshEnv(process.env, DSH_HOME, RUNTIME_ROOT)
  watchStartupMilestones()

  return new Promise((resolve, reject) => {
    requireActiveStartup()
    const child = spawn(NODE_EXE, dshServerArgs(DSH_BIN, UPDATE_PATCH_PATH), {
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
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (serverPageUrl !== null) {
      if (isDesktopUpdateRequest(url, serverPageUrl)) {
        requestManualUpdate()
        return { action: 'deny' }
      }
      if (isDesktopRequest(url, serverPageUrl, DIAGNOSTICS_REQUEST_PATH)) {
        void copyDesktopDiagnostics()
          .catch(error => dialog.showErrorBox('CedarDSH Desktop diagnostics', error.message))
        return { action: 'deny' }
      }
      if (isDesktopRequest(url, serverPageUrl, RELEASES_REQUEST_PATH)) {
        void electronShell.openExternal(RELEASES_URL)
          .catch(error => appendLog(`could not open release notes: ${error.message}`))
        return { action: 'deny' }
      }
    }
    return { action: 'allow' }
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
    serverPageUrl = url
    await setStartupStage('interface')
    if (targetWindow.isDestroyed() || mainWindow !== targetWindow) return
    loadingPageActive = false
    targetWindow.webContents.once('did-finish-load', async () => {
      if (mainWindow !== targetWindow || targetWindow.isDestroyed()) return
      try {
        await publishDesktopInfo(targetWindow)
      } catch (error) {
        fatal(`could not publish CedarDSH version information: ${error.message}`)
        return
      }
      void setStartupStage('ready')
      targetWindow.setProgressBar(-1)
      if (SMOKE) {
        setTimeout(async () => {
          try {
            const updateButtonLayout = await targetWindow.webContents.executeJavaScript(`(() => {
              const button = document.querySelector('[data-cedardsh-update]')
              if (!(button instanceof HTMLElement)) return null
              const actionContainer = button.parentElement?.parentElement?.parentElement
              const settingsArea = actionContainer?.nextElementSibling
              if (!(settingsArea instanceof HTMLElement)) return { present: true, adjacent: false }
              const buttonRect = button.getBoundingClientRect()
              const settingsRect = settingsArea.getBoundingClientRect()
              const centerY = buttonRect.top + buttonRect.height / 2
              const rail = button.parentElement?.classList.contains('cedardshUpdateRail') === true
              return {
                present: true,
                adjacent: rail
                  ? buttonRect.left === settingsRect.left
                    && buttonRect.width === settingsRect.width
                    && buttonRect.bottom === settingsRect.top
                  : buttonRect.left >= settingsRect.left + settingsRect.width / 2
                    && buttonRect.right <= settingsRect.right
                    && buttonRect.right >= settingsRect.right - 24
                    && centerY >= settingsRect.top
                    && centerY <= settingsRect.bottom,
                mode: rail ? 'rail' : 'wide',
                button: { x: buttonRect.x, y: buttonRect.y, width: buttonRect.width, height: buttonRect.height },
                settings: { x: settingsRect.x, y: settingsRect.y, width: settingsRect.width, height: settingsRect.height },
              }
            })()`, true)
            if (updateButtonLayout === null) throw new Error('CedarDSH update button was not registered')
            if (!updateButtonLayout.adjacent) {
              throw new Error(`CedarDSH update button is not adjacent to Settings: ${JSON.stringify(updateButtonLayout)}`)
            }
            await targetWindow.webContents.executeJavaScript(`(async () => {
              const dismiss = async labels => {
                const button = [...document.querySelectorAll('button')]
                  .find(candidate => labels.includes(candidate.textContent?.trim() ?? ''))
                if (!(button instanceof HTMLButtonElement)) return
                button.click()
                await new Promise((resolve, reject) => {
                  const startedAt = performance.now()
                  const observe = () => {
                    if (!button.isConnected) {
                      resolve()
                      return
                    }
                    if (performance.now() - startedAt >= 5000) {
                      reject(new Error('Onboarding action did not finish'))
                      return
                    }
                    requestAnimationFrame(observe)
                  }
                  observe()
                })
                await new Promise(resolve => requestAnimationFrame(resolve))
              }
              await dismiss(['继续', 'Continue'])
              await dismiss(['稍后配置', 'Configure later'])
            })()`, true)
            const settingsOpened = await targetWindow.webContents.executeJavaScript(`(() => {
              const updateButton = document.querySelector('[data-cedardsh-update]')
              const actionContainer = updateButton?.parentElement?.parentElement?.parentElement
              const settingsArea = actionContainer?.nextElementSibling
              const trigger = settingsArea?.querySelector('button')
              if (!(trigger instanceof HTMLButtonElement)) return false
              trigger.click()
              return true
            })()`, true)
            if (!settingsOpened) throw new Error('Settings trigger was not found adjacent to the update button')
            await new Promise(resolve => setTimeout(resolve, 500))
            const aboutOpened = await targetWindow.webContents.executeJavaScript(`(() => {
              const trigger = [...document.querySelectorAll('button')]
                .find(button => ['关于', 'About'].includes(button.textContent?.trim() ?? '')
                  && button.getBoundingClientRect().height > 0)
              if (!(trigger instanceof HTMLButtonElement)) return false
              trigger.click()
              return true
            })()`, true)
            if (!aboutOpened) throw new Error('CedarDSH About settings entry was not registered')
            await new Promise(resolve => setTimeout(resolve, 500))
            const aboutText = await targetWindow.webContents.executeJavaScript(`(() => {
              const section = document.querySelector('[data-cedardsh-about]')
              const diagnostics = section?.querySelector('[data-cedardsh-diagnostics]')
              return section instanceof HTMLElement
                && section.getBoundingClientRect().height > 0
                && diagnostics instanceof HTMLButtonElement
                ? section.textContent
                : null
            })()`, true)
            const desktopInfo = readDesktopInfo()
            if (aboutText === null
              || !aboutText.includes(desktopInfo.portableVersion)
              || !aboutText.includes(desktopInfo.dshVersion)) {
              throw new Error(`CedarDSH About information is incomplete: ${JSON.stringify(aboutText)}`)
            }
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
        requestAutomaticUpdate()
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
