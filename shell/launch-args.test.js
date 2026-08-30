'use strict'

const assert = require('node:assert/strict')
const { describe, it } = require('node:test')
const {
  capabilityBundleRegistered,
  capabilityInstallArgs,
  capabilityProfileRegistered,
  capabilityRepairArgs,
  dshServerArgs,
} = require('./launch-args.js')

describe('dsh server arguments', () => {
  it('boots the Web profile after Bundle registration', () => {
    assert.deepEqual(dshServerArgs('C:\\app\\dsh.js'), [
      'C:\\app\\dsh.js',
      'web',
      '--no-open',
      '--port',
      '0',
    ])
  })

  it('uses the official offline plugin workflow for the packaged Bundle', () => {
    assert.deepEqual(capabilityInstallArgs('dsh.js'), [
      'dsh.js',
      'plugin',
      '--profile',
      'web',
      'add',
      '--offline',
      '@maiziman/dsh-model-capabilities@link:./.portable-plugins/dsh-model-capabilities',
    ])
    assert.deepEqual(capabilityRepairArgs('dsh.js'), [
      'dsh.js',
      'plugin',
      '--profile',
      'web',
      'install',
      '--offline',
      '--force',
    ])
  })

  it('requires both the profile dependency, layer entry, and installed version', () => {
    const profile = {
      dependencies: { '@maiziman/dsh-model-capabilities': 'link:.portable-plugins\\dsh-model-capabilities' },
      dsh: { profile: { bundles: ['@deepseek-ai/dsh-base', '@maiziman/dsh-model-capabilities'] } },
    }
    const installed = { name: '@maiziman/dsh-model-capabilities', version: '0.1.0' }
    assert.equal(capabilityProfileRegistered(profile), true)
    assert.equal(capabilityProfileRegistered({
      ...profile,
      dependencies: { '@maiziman/dsh-model-capabilities': 'link:./.portable-plugins/dsh-model-capabilities' },
    }), true)
    assert.equal(capabilityBundleRegistered(profile, installed, '0.1.0'), true)
    assert.equal(capabilityBundleRegistered({ ...profile, dependencies: {} }, installed, '0.1.0'), false)
    assert.equal(capabilityProfileRegistered({
      ...profile,
      dependencies: { '@maiziman/dsh-model-capabilities': 'link:C:/old/absolute/path' },
    }), false)
    assert.equal(capabilityBundleRegistered(profile, installed, '0.2.0'), false)
  })
})
