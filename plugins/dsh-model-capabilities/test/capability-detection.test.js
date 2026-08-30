import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import {
  allowsActiveProbe,
  capabilitiesFromModelEntry,
  capabilitiesFromOllamaShow,
  isLocalEndpoint,
  probeReasoningEfforts,
  probeVision,
  readProviderMetadata,
  resolveConfig,
} from '../capability-detection.js'

const CONFIG = resolveConfig({ requestTimeoutMs: 1_000 })

function jsonResponse(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

describe('configuration', () => {
  it('resolves conservative public-endpoint defaults', () => {
    assert.deepEqual(resolveConfig(), {
      metadataDiscovery: true,
      activeProbePolicy: 'local-only',
      reasoningProbe: true,
      visionProbe: true,
      reasoningProbeEfforts: ['low', 'high', 'max'],
      probeConcurrency: 1,
      requestTimeoutMs: 10_000,
      probeMaxTokens: 128,
    })
  })

  it('rejects unsupported or duplicate probe levels', () => {
    assert.throws(() => resolveConfig({ reasoningProbeEfforts: ['turbo'] }), /supported effort names/u)
    assert.throws(() => resolveConfig({ reasoningProbeEfforts: ['low', 'low'] }), /duplicates/u)
  })
})

describe('endpoint classification', () => {
  it('recognizes literal loopback, private IPv4, link-local, and local IPv6 addresses', () => {
    for (const url of [
      'http://127.0.0.1:8000/v1',
      'http://10.0.2.3/v1',
      'http://172.31.2.3/v1',
      'http://192.168.50.10:3000/api',
      'http://169.254.2.3/v1',
      'http://localhost:11434/v1',
      'http://[::1]:8000/v1',
      'http://[fd00::1]:8000/v1',
    ]) assert.equal(isLocalEndpoint(url), true, url)
  })

  it('keeps active probes off public and malformed endpoints', () => {
    assert.equal(isLocalEndpoint('https://openrouter.ai/api/v1'), false)
    assert.equal(isLocalEndpoint('http://modelbox.local/v1'), false)
    assert.equal(isLocalEndpoint('not a url'), false)
    assert.equal(allowsActiveProbe('local-only', 'https://openrouter.ai/api/v1'), false)
    assert.equal(allowsActiveProbe('always', 'https://openrouter.ai/api/v1'), true)
    assert.equal(allowsActiveProbe('never', 'http://127.0.0.1/v1'), false)
  })
})

describe('declared metadata', () => {
  it('reads OpenRouter image modalities and exact reasoning levels', () => {
    assert.deepEqual(capabilitiesFromModelEntry({
      architecture: { input_modalities: ['text', 'image'] },
      supported_parameters: ['reasoning'],
      reasoning: {
        supported_efforts: ['high', 'low'],
        mandatory: false,
      },
    }), {
      image: true,
      reasoningEfforts: { high: 'high', low: 'low', off: null },
      supportsReasoningEffort: true,
      thinkingFormat: 'openrouter',
    })
  })

  it('uses the documented OpenAI-compatible effort vocabulary', () => {
    assert.deepEqual(capabilitiesFromModelEntry({ supported_parameters: ['reasoning_effort'] }), {
      reasoningEfforts: { off: 'none', low: 'low', medium: 'medium', high: 'high' },
      supportsReasoningEffort: true,
      thinkingFormat: 'openai',
    })
  })

  it('does not infer capabilities from a model name', () => {
    assert.deepEqual(capabilitiesFromModelEntry({ id: 'deepseek-vision-thinking-max' }), {})
  })

  it('reads Ollama show capabilities without inference calls', () => {
    assert.deepEqual(capabilitiesFromOllamaShow({ capabilities: ['completion', 'vision', 'thinking'] }), {
      image: true,
      reasoningEfforts: { off: 'none', low: 'low', medium: 'medium', high: 'high' },
      supportsReasoningEffort: true,
      thinkingFormat: 'openai',
    })
  })
})

describe('metadata requests', () => {
  it('combines an OpenAI listing with local Ollama details', async () => {
    const calls = []
    const fetchImpl = async (url, init) => {
      calls.push({ url, init })
      if (url.endsWith('/models')) return jsonResponse({ data: [{ id: 'local-model' }] })
      return jsonResponse({ capabilities: ['vision', 'thinking'] })
    }
    const result = await readProviderMetadata({
      profile: { baseURL: 'http://192.168.1.8:11434/v1', headers: { 'x-tenant': 'demo' } },
      modelIds: ['local-model'],
      apiKey: 'secret-key',
      fetchImpl,
      config: CONFIG,
    })
    assert.deepEqual(result.capabilities.get('local-model'), {
      image: true,
      reasoningEfforts: { off: 'none', low: 'low', medium: 'medium', high: 'high' },
      supportsReasoningEffort: true,
      thinkingFormat: 'openai',
    })
    assert.deepEqual(calls.map(call => [call.init.method, call.url]), [
      ['GET', 'http://192.168.1.8:11434/v1/models'],
      ['POST', 'http://192.168.1.8:11434/api/show'],
    ])
    assert.equal(calls[0].init.headers.authorization, 'Bearer secret-key')
    assert.equal(calls[0].init.headers['x-tenant'], 'demo')
    assert.equal(calls[0].init.redirect, 'error')
  })

  it('does not call an Ollama-specific path on public endpoints', async () => {
    const calls = []
    const result = await readProviderMetadata({
      profile: { baseURL: 'https://gateway.example/v1' },
      modelIds: ['cloud-model'],
      fetchImpl: async (url) => {
        calls.push(url)
        return jsonResponse({ data: [{ id: 'cloud-model' }] })
      },
      config: CONFIG,
    })
    assert.deepEqual(calls, ['https://gateway.example/v1/models'])
    assert.deepEqual(result.capabilities.get('cloud-model'), {})
  })

  it('preserves endpoint query parameters for the request but redacts them from diagnostics', async () => {
    const calls = []
    const result = await readProviderMetadata({
      profile: { baseURL: 'https://gateway.example/v1?api-version=secret-value' },
      modelIds: ['cloud-model'],
      fetchImpl: async (url) => {
        calls.push(url)
        return jsonResponse({ error: 'nope' }, 500)
      },
      config: CONFIG,
    })
    assert.deepEqual(calls, ['https://gateway.example/v1/models?api-version=secret-value'])
    assert.equal(result.diagnostics.length, 1)
    assert.doesNotMatch(result.diagnostics[0], /secret-value/u)
  })
})

describe('active probes', () => {
  it('offers only levels whose replies contain reasoning evidence', async () => {
    const bodies = []
    const efforts = await probeReasoningEfforts({
      profile: { baseURL: 'http://127.0.0.1:3000/api' },
      modelId: 'reasoner',
      apiKey: 'local-key',
      fetchImpl: async (_url, init) => {
        const body = JSON.parse(init.body)
        bodies.push(body)
        if (body.reasoning_effort === '__dsh_invalid_effort__') return jsonResponse({ error: 'invalid effort' }, 400)
        if (body.reasoning_effort === 'max') return jsonResponse({ error: 'unsupported' }, 400)
        return jsonResponse({
          choices: [{ message: {
            reasoning_content: body.reasoning_effort === 'high' ? 'brief trace' : '',
            content: '323',
          } }],
        })
      },
      config: resolveConfig({ requestTimeoutMs: 1_000, reasoningProbeEfforts: ['low', 'high', 'max'] }),
    })
    assert.deepEqual(efforts, { high: 'high' })
    assert.deepEqual(bodies.map(body => body.reasoning_effort), ['__dsh_invalid_effort__', 'low', 'high', 'max'])
  })

  it('rejects reasoning evidence when an invalid effort is silently ignored', async () => {
    let calls = 0
    const efforts = await probeReasoningEfforts({
      profile: { baseURL: 'http://127.0.0.1:3000/api' },
      modelId: 'always-thinking',
      fetchImpl: async () => {
        calls++
        return jsonResponse({ choices: [{ message: { reasoning_content: 'default trace', content: '323' } }] })
      },
      config: CONFIG,
    })
    assert.equal(efforts, undefined)
    assert.equal(calls, 1)
  })

  it('requires the image answer to identify the hidden probe color', async () => {
    const requestBodies = []
    const yes = await probeVision({
      profile: { baseURL: 'http://127.0.0.1:3000/api' },
      modelId: 'vision-model',
      fetchImpl: async (_url, init) => {
        const body = JSON.parse(init.body)
        requestBodies.push(body)
        const image = body.messages[0].content[1].image_url.url
        const content = image.includes('fhqnpuF') ? 'Red.' : 'Blue.'
        return jsonResponse({ choices: [{ message: { content } }] })
      },
      config: CONFIG,
    })
    const no = await probeVision({
      profile: { baseURL: 'http://127.0.0.1:3000/api' },
      modelId: 'text-model',
      fetchImpl: async () => jsonResponse({ choices: [{ message: { content: 'I cannot see an image.' } }] }),
      config: CONFIG,
    })
    const ambiguous = await probeVision({
      profile: { baseURL: 'http://127.0.0.1:3000/api' },
      modelId: 'guessing-model',
      fetchImpl: async () => jsonResponse({ choices: [{ message: { content: 'I cannot see the image; it may be red or blue.' } }] }),
      config: CONFIG,
    })
    assert.equal(yes, true)
    assert.equal(no, false)
    assert.equal(ambiguous, false)
    assert.equal(requestBodies.length, 2)
    assert.match(requestBodies[0].messages[0].content[1].image_url.url, /^data:image\/png;base64,/u)
  })
})
