'use strict'

/**
 * Format the fixed, non-secret CedarDSH support report.
 *
 * @param {object} info Desktop build and runtime facts.
 * @returns {string} Copy-ready support text.
 */
function formatDiagnostics(info) {
  const logState = info.serverLog.exists
    ? `${String(info.serverLog.size)} bytes, modified ${info.serverLog.modifiedAt}`
    : 'not created'
  return [
    'CedarDSH Desktop diagnostics',
    `Generated: ${info.generatedAt}`,
    `CedarDSH Desktop: ${info.portableVersion}`,
    `Official DeepSeek Harness: ${info.dshVersion}`,
    `Node runtime: ${info.nodeVersion}`,
    `Electron: ${info.electronVersion}`,
    `Windows: ${info.windowsVersion} (${info.architecture})`,
    `Built: ${info.builtAt}`,
    `Last update check: ${info.lastCheckedAt ?? 'never'}`,
    `Web profile: ${info.profileInitialized ? 'initialized' : 'not initialized'}`,
    `DSH server: ${info.serverRunning ? 'running' : 'stopped'}`,
    `Server log: ${logState}`,
    'Server log location: dsh-home\\logs\\server.log',
  ].join('\n')
}

module.exports = { formatDiagnostics }
