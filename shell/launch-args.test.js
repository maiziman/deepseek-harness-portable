'use strict'

const assert = require('node:assert/strict')
const { describe, it } = require('node:test')
const path = require('node:path')
const { dshServerArgs, portableDshEnv } = require('./launch-args.js')

describe('dsh server arguments', () => {
  it('adds the CedarDSH launcher patch before Web application flags', () => {
    assert.deepEqual(dshServerArgs('C:\\app\\dsh.js', 'C:\\shell\\cedardsh.patch.yml'), [
      'C:\\app\\dsh.js',
      'web',
      '--patch',
      'C:\\shell\\cedardsh.patch.yml',
      '--no-open',
      '--port',
      '0',
    ])
  })
})

describe('portable DSH environment', () => {
  it('keeps package-manager data under DSH_HOME and replaces inherited overrides', () => {
    const env = portableDshEnv({
      Path: 'C:\\Windows',
      PNPM_CONFIG_STORE_DIR: 'C:\\outside-store',
      pnpm_config_state_dir: 'C:\\outside-state',
      NODE_COMPILE_CACHE: 'C:\\outside-compile-cache',
      npm_config_cache: 'C:\\unrelated-npm-cache',
    }, 'D:\\Portable\\dsh-home', 'D:\\Portable\\runtime')
    assert.equal(env.DSH_HOME, 'D:\\Portable\\dsh-home')
    assert.equal(env.PATH, ['D:\\Portable\\runtime', 'C:\\Windows'].join(path.delimiter))
    assert.equal(env.pnpm_config_store_dir, path.join('D:\\Portable\\dsh-home', 'pnpm-store'))
    assert.equal(env.pnpm_config_cache_dir, path.join('D:\\Portable\\dsh-home', 'pnpm-cache'))
    assert.equal(env.pnpm_config_state_dir, path.join('D:\\Portable\\dsh-home', 'pnpm-state'))
    assert.equal(env.NODE_COMPILE_CACHE, path.join('D:\\Portable\\dsh-home', 'node-compile-cache'))
    assert.equal(env.NODE_COMPILE_CACHE_PORTABLE, '1')
    assert.equal(env.PNPM_CONFIG_STORE_DIR, undefined)
    assert.equal(env.npm_config_cache, 'C:\\unrelated-npm-cache')
  })
})
