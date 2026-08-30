import assert from 'node:assert/strict'
import { afterEach, describe, it } from 'node:test'
import { apply } from '../index.js'

const originalFetch = globalThis.fetch

afterEach(() => {
  globalThis.fetch = originalFetch
})

function jsonResponse(value) {
  return new Response(JSON.stringify(value), { headers: { 'content-type': 'application/json' } })
}

async function waitFor(predicate, timeoutMs = 1_000) {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('timed out waiting for plugin work')
    await new Promise(resolve => setTimeout(resolve, 5))
  }
}

function harness(descriptor) {
  const listeners = new Map()
  const disposers = []
  const mutations = []
  const logs = []
  const ctx = {
    settings: {
      describe: () => [descriptor],
      mutate: async (ns, ops, revision) => {
        mutations.push({ ns, ops, revision })
      },
    },
    get: () => ({ resolve: async () => ({ value: 'stored-secret' }) }),
    logger: {
      debug: value => logs.push(['debug', String(value)]),
      info: value => logs.push(['info', String(value)]),
      warn: value => logs.push(['warn', String(value)]),
    },
    on: (event, callback) => {
      listeners.set(event, callback)
      return () => listeners.delete(event)
    },
    effect: (start) => {
      disposers.push(start())
    },
  }
  return {
    ctx,
    mutations,
    logs,
    emit: (event, ...args) => listeners.get(event)?.(...args),
    dispose: async () => {
      for (const disposer of disposers.reverse()) await disposer()
    },
  }
}

describe('settings reconciliation', () => {
  it('actively proves local reasoning and image input during initial reconciliation', async () => {
    const descriptor = {
      ns: 'llm-pi-ai',
      revision: 3,
      user: {
        providers: {
          lab: {
            baseURL: 'http://192.168.50.10:3000/api',
            api: 'openai-completions',
            models: [{ id: 'custom-local-model' }],
          },
        },
      },
      value: {
        providers: {
          lab: {
            baseURL: 'http://192.168.50.10:3000/api',
            api: 'openai-completions',
            models: [{ id: 'custom-local-model' }],
          },
        },
      },
    }
    const requests = []
    globalThis.fetch = async (url, init) => {
      const body = init.body === undefined ? undefined : JSON.parse(init.body)
      requests.push({ url: String(url), method: init.method, body })
      if (init.method === 'GET') return jsonResponse({ data: [{ id: 'custom-local-model' }] })
      if (String(url).endsWith('/api/show')) return new Response('', { status: 404 })
      if (body.reasoning_effort === '__dsh_invalid_effort__') return new Response('', { status: 400 })
      if (body.reasoning_effort === 'high') {
        return jsonResponse({ choices: [{ message: { reasoning_content: 'brief calculation', content: '323' } }] })
      }
      const image = body.messages?.[0]?.content?.[1]?.image_url?.url
      return jsonResponse({ choices: [{ message: { content: image?.includes('fhqnpuF') ? 'red' : 'blue' } }] })
    }
    const app = harness(descriptor)
    apply(app.ctx, {
      reasoningProbeEfforts: ['high'],
      requestTimeoutMs: 1_000,
    })
    await waitFor(() => app.mutations.length === 1)
    assert.deepEqual(app.mutations[0].ops, [{
      op: 'set',
      path: ['providers', 'lab', 'models'],
      value: [{
        id: 'custom-local-model',
        input: ['text', 'image'],
        reasoningEfforts: { high: 'high' },
        compat: { supportsReasoningEffort: true, thinkingFormat: 'openai' },
      }],
    }])
    assert.equal(requests.filter(request => request.body?.reasoning_effort === 'high').length, 1)
    assert.equal(requests.filter(request => Array.isArray(request.body?.messages?.[0]?.content)).length, 2)
    await app.dispose()
  })

  it('adds declared capabilities while preserving every explicit field and the credential reference', async () => {
    const descriptor = {
      ns: 'llm-pi-ai',
      revision: 7,
      base: {},
      user: {
        providers: {
          office: {
            apiKeyEnv: 'OFFICE_API_KEY',
            baseURL: 'https://gateway.example/v1',
            api: 'openai-completions',
            headers: { 'x-tenant': 'redacted-name' },
            compat: { thinkingFormat: 'openrouter' },
            models: [
              { id: 'auto', name: 'Automatic' },
              { id: 'manual', input: ['text'], reasoningEfforts: false, compat: { supportsReasoningEffort: false } },
              { id: 'manual-compat', compat: { supportsReasoningEffort: false } },
            ],
          },
        },
      },
      value: {
        providers: {
          office: {
            apiKeyEnv: 'OFFICE_API_KEY',
            baseURL: 'https://gateway.example/v1',
            api: 'openai-completions',
            headers: { 'x-tenant': 'redacted-name' },
            compat: { thinkingFormat: 'openrouter' },
            models: [
              { id: 'auto', name: 'Automatic' },
              { id: 'manual', input: ['text'], reasoningEfforts: false, compat: { supportsReasoningEffort: false } },
              { id: 'manual-compat', compat: { supportsReasoningEffort: false } },
            ],
          },
        },
      },
    }
    globalThis.fetch = async (_url, init) => {
      assert.equal(init.headers.authorization, 'Bearer stored-secret')
      return jsonResponse({
        data: [
          {
            id: 'auto',
            architecture: { input_modalities: ['text', 'image'] },
            supported_parameters: ['reasoning_effort'],
          },
          {
            id: 'manual',
            architecture: { input_modalities: ['text', 'image'] },
            supported_parameters: ['reasoning_effort'],
          },
          {
            id: 'manual-compat',
            supported_parameters: ['reasoning_effort'],
          },
        ],
      })
    }
    const app = harness(descriptor)
    apply(app.ctx, { activeProbePolicy: 'never', requestTimeoutMs: 1_000 })
    await waitFor(() => app.mutations.length === 1)
    assert.equal(app.mutations[0].ns, 'llm-pi-ai')
    assert.equal(app.mutations[0].revision, 7)
    assert.deepEqual(app.mutations[0].ops, [{
      op: 'set',
      path: ['providers', 'office', 'models'],
      value: [
        {
          id: 'auto',
          name: 'Automatic',
          input: ['text', 'image'],
          reasoningEfforts: { off: 'none', low: 'low', medium: 'medium', high: 'high' },
          compat: { supportsReasoningEffort: true },
        },
        { id: 'manual', input: ['text'], reasoningEfforts: false, compat: { supportsReasoningEffort: false } },
        { id: 'manual-compat', compat: { supportsReasoningEffort: false } },
      ],
    }])
    assert.match(app.logs.find(([level]) => level === 'info')[1], /office\/auto/u)
    await app.dispose()
  })

  it('preserves provider compatibility fields merged across settings layers', async () => {
    const descriptor = {
      ns: 'llm-pi-ai',
      revision: 4,
      base: {
        providers: {
          disabled: {
            compat: { supportsReasoningEffort: false },
          },
          formatted: {
            compat: { thinkingFormat: 'openrouter' },
          },
        },
      },
      user: {
        providers: {
          disabled: {
            baseURL: 'https://disabled.example/v1',
            api: 'openai-completions',
            compat: { thinkingFormat: 'openrouter' },
            models: [{ id: 'disabled-model', input: ['text'] }],
          },
          formatted: {
            baseURL: 'https://formatted.example/v1',
            api: 'openai-completions',
            models: [{ id: 'formatted-model', input: ['text'] }],
          },
        },
      },
      value: {
        providers: {
          disabled: {
            baseURL: 'https://disabled.example/v1',
            api: 'openai-completions',
            compat: { supportsReasoningEffort: false, thinkingFormat: 'openrouter' },
            models: [{ id: 'disabled-model', input: ['text'] }],
          },
          formatted: {
            baseURL: 'https://formatted.example/v1',
            api: 'openai-completions',
            compat: { thinkingFormat: 'openrouter' },
            models: [{ id: 'formatted-model', input: ['text'] }],
          },
        },
      },
    }
    globalThis.fetch = async (url) => jsonResponse({
      data: [{
        id: String(url).includes('disabled.example') ? 'disabled-model' : 'formatted-model',
        supported_parameters: ['reasoning_effort'],
      }],
    })
    const app = harness(descriptor)
    apply(app.ctx, { activeProbePolicy: 'never', requestTimeoutMs: 1_000 })
    await waitFor(() => app.mutations.length === 1)
    assert.deepEqual(app.mutations[0].ops, [{
      op: 'set',
      path: ['providers', 'formatted', 'models'],
      value: [{
        id: 'formatted-model',
        input: ['text'],
        reasoningEfforts: { off: 'none', low: 'low', medium: 'medium', high: 'high' },
        compat: { supportsReasoningEffort: true },
      }],
    }])
    await app.dispose()
  })

  it('ignores other settings namespaces and leaves an unknown listing unchanged', async () => {
    const descriptor = {
      ns: 'llm-pi-ai',
      revision: 1,
      user: { providers: { office: { baseURL: 'https://gateway.example/v1', models: [{ id: 'plain' }] } } },
      value: { providers: { office: { baseURL: 'https://gateway.example/v1', models: [{ id: 'plain' }] } } },
    }
    globalThis.fetch = async () => jsonResponse({ data: [{ id: 'plain' }] })
    const app = harness(descriptor)
    apply(app.ctx, { activeProbePolicy: 'never', requestTimeoutMs: 1_000 })
    app.emit('settings/document-updated', 'ui-theme', 2)
    await new Promise(resolve => setTimeout(resolve, 30))
    assert.deepEqual(app.mutations, [])
    await app.dispose()
  })

  it('reads the committed provider value after the settings update event', async () => {
    const descriptor = {
      ns: 'llm-pi-ai',
      revision: 1,
      user: { providers: {} },
      value: { providers: {} },
    }
    globalThis.fetch = async () => jsonResponse({
      data: [{
        id: 'new-model',
        architecture: { input_modalities: ['text', 'image'] },
      }],
    })
    const app = harness(descriptor)
    apply(app.ctx, { activeProbePolicy: 'never', requestTimeoutMs: 1_000 })
    await new Promise(resolve => setImmediate(resolve))

    descriptor.revision = 2
    descriptor.user = {
      providers: {
        added: {
          baseURL: 'https://gateway.example/v1',
          api: 'openai-completions',
          models: [{ id: 'new-model' }],
        },
      },
    }
    app.emit('settings/document-updated', 'llm-pi-ai', 2)
    descriptor.value = structuredClone(descriptor.user)

    await waitFor(() => app.mutations.length === 1)
    assert.equal(app.mutations[0].revision, 2)
    assert.deepEqual(app.mutations[0].ops[0].value, [{ id: 'new-model', input: ['text', 'image'] }])
    await app.dispose()
  })

  it('does not send OpenAI discovery requests to another provider protocol', async () => {
    const descriptor = {
      ns: 'llm-pi-ai',
      revision: 1,
      user: {
        providers: {
          anthropic: {
            baseURL: 'http://127.0.0.1:3000',
            api: 'anthropic-messages',
            models: [{ id: 'claude-compatible' }],
          },
        },
      },
      value: {
        providers: {
          anthropic: {
            baseURL: 'http://127.0.0.1:3000',
            api: 'anthropic-messages',
            models: [{ id: 'claude-compatible' }],
          },
        },
      },
    }
    let requests = 0
    globalThis.fetch = async () => {
      requests++
      return jsonResponse({})
    }
    const app = harness(descriptor)
    apply(app.ctx, { requestTimeoutMs: 1_000 })
    await new Promise(resolve => setTimeout(resolve, 30))
    assert.equal(requests, 0)
    assert.deepEqual(app.mutations, [])
    await app.dispose()
  })

  it('retries after route headers or the route credential reference changes', async () => {
    const descriptor = {
      ns: 'llm-pi-ai',
      revision: 5,
      user: {
        providers: {
          secured: {
            baseURL: 'http://127.0.0.1:3000/api',
            api: 'openai-completions',
            apiKeyEnv: 'LOCAL_MODEL_KEY',
            models: [{ id: 'reasoner', input: ['text'] }],
          },
        },
      },
      value: {
        providers: {
          secured: {
            baseURL: 'http://127.0.0.1:3000/api',
            api: 'openai-completions',
            apiKeyEnv: 'LOCAL_MODEL_KEY',
            models: [{ id: 'reasoner', input: ['text'] }],
          },
        },
      },
    }
    let authorized = false
    let validEffortCalls = 0
    globalThis.fetch = async (_url, init) => {
      const body = init.body === undefined ? undefined : JSON.parse(init.body)
      if (init.method === 'GET') return jsonResponse({ data: [{ id: 'reasoner' }] })
      if (body?.model !== undefined && body.reasoning_effort === undefined) return new Response('', { status: 404 })
      if (body?.reasoning_effort === '__dsh_invalid_effort__') return new Response('', { status: 400 })
      if (body?.reasoning_effort === 'high') {
        validEffortCalls++
        return authorized
          ? jsonResponse({ choices: [{ message: { reasoning_content: 'trace', content: '323' } }] })
          : new Response('', { status: 401 })
      }
      return jsonResponse({ choices: [{ message: { content: 'not used' } }] })
    }
    const app = harness(descriptor)
    apply(app.ctx, {
      reasoningProbeEfforts: ['high'],
      visionProbe: false,
      requestTimeoutMs: 1_000,
    })
    await waitFor(() => validEffortCalls === 1)
    descriptor.user.providers.secured.headers = { 'x-tenant': 'fixed' }
    descriptor.value.providers.secured.headers = { 'x-tenant': 'fixed' }
    app.emit('settings/document-updated', 'llm-pi-ai', 6)
    await waitFor(() => validEffortCalls === 2)
    authorized = true
    app.emit('credentials/reference-updated', 'UNRELATED_KEY')
    await new Promise(resolve => setTimeout(resolve, 30))
    assert.equal(validEffortCalls, 2)
    app.emit('credentials/reference-updated', 'LOCAL_MODEL_KEY')
    await waitFor(() => app.mutations.length === 1)
    assert.equal(validEffortCalls, 3)
    assert.deepEqual(app.mutations[0].ops[0].value[0].reasoningEfforts, { high: 'high' })
    await app.dispose()
  })

  it('retries positive evidence after a revision-checked settings write fails', async () => {
    const descriptor = {
      ns: 'llm-pi-ai',
      revision: 5,
      user: {
        providers: {
          local: {
            baseURL: 'http://127.0.0.1:3000/api',
            api: 'openai-completions',
            models: [{ id: 'reasoner', input: ['text'] }],
          },
        },
      },
      value: {
        providers: {
          local: {
            baseURL: 'http://127.0.0.1:3000/api',
            api: 'openai-completions',
            models: [{ id: 'reasoner', input: ['text'] }],
          },
        },
      },
    }
    let validEffortCalls = 0
    globalThis.fetch = async (_url, init) => {
      const body = init.body === undefined ? undefined : JSON.parse(init.body)
      if (init.method === 'GET') return jsonResponse({ data: [{ id: 'reasoner' }] })
      if (body?.model !== undefined && body.reasoning_effort === undefined) return new Response('', { status: 404 })
      if (body?.reasoning_effort === '__dsh_invalid_effort__') return new Response('', { status: 400 })
      validEffortCalls++
      return jsonResponse({ choices: [{ message: { reasoning_content: 'trace', content: '323' } }] })
    }
    const app = harness(descriptor)
    const mutate = app.ctx.settings.mutate
    let rejectWrite = true
    app.ctx.settings.mutate = async (...args) => {
      if (rejectWrite) {
        rejectWrite = false
        descriptor.revision = 6
        app.emit('settings/document-updated', 'llm-pi-ai', 6)
        throw new Error('revision changed')
      }
      return mutate(...args)
    }
    apply(app.ctx, {
      reasoningProbeEfforts: ['high'],
      visionProbe: false,
      requestTimeoutMs: 1_000,
    })
    await waitFor(() => app.mutations.length === 1)
    assert.equal(validEffortCalls, 2)
    assert.equal(app.mutations[0].revision, 6)
    await app.dispose()
  })

  it('does not repeat probes for its own settings document event', async () => {
    const descriptor = {
      ns: 'llm-pi-ai',
      revision: 3,
      user: {
        providers: {
          local: {
            baseURL: 'http://127.0.0.1:3000/api',
            api: 'openai-completions',
            models: [{ id: 'reasoner', input: ['text'] }],
          },
        },
      },
      value: {
        providers: {
          local: {
            baseURL: 'http://127.0.0.1:3000/api',
            api: 'openai-completions',
            models: [{ id: 'reasoner', input: ['text'] }],
          },
        },
      },
    }
    let validEffortCalls = 0
    globalThis.fetch = async (_url, init) => {
      const body = init.body === undefined ? undefined : JSON.parse(init.body)
      if (init.method === 'GET') return jsonResponse({ data: [{ id: 'reasoner' }] })
      if (body?.model !== undefined && body.reasoning_effort === undefined) return new Response('', { status: 404 })
      if (body?.reasoning_effort === '__dsh_invalid_effort__') return new Response('', { status: 400 })
      validEffortCalls++
      return jsonResponse({ choices: [{ message: { reasoning_content: 'trace', content: '323' } }] })
    }
    const app = harness(descriptor)
    const mutate = app.ctx.settings.mutate
    app.ctx.settings.mutate = async (...args) => {
      await mutate(...args)
      descriptor.revision = 4
      app.emit('settings/document-updated', 'llm-pi-ai', 4)
    }
    apply(app.ctx, {
      reasoningProbeEfforts: ['high'],
      visionProbe: false,
      requestTimeoutMs: 1_000,
    })
    await waitFor(() => app.mutations.length === 1)
    await new Promise(resolve => setTimeout(resolve, 30))
    assert.equal(validEffortCalls, 1)
    assert.equal(app.mutations.length, 1)
    await app.dispose()
  })

  it('discards an in-flight probe generation when its credential changes', async () => {
    const descriptor = {
      ns: 'llm-pi-ai',
      revision: 8,
      user: {
        providers: {
          local: {
            baseURL: 'http://127.0.0.1:3000/api',
            api: 'openai-completions',
            apiKeyEnv: 'ROTATING_KEY',
            models: [{ id: 'reasoner', input: ['text'] }],
          },
        },
      },
      value: {
        providers: {
          local: {
            baseURL: 'http://127.0.0.1:3000/api',
            api: 'openai-completions',
            apiKeyEnv: 'ROTATING_KEY',
            models: [{ id: 'reasoner', input: ['text'] }],
          },
        },
      },
    }
    const release = []
    let validEffortCalls = 0
    globalThis.fetch = async (_url, init) => {
      const body = init.body === undefined ? undefined : JSON.parse(init.body)
      if (init.method === 'GET') return jsonResponse({ data: [{ id: 'reasoner' }] })
      if (body?.model !== undefined && body.reasoning_effort === undefined) return new Response('', { status: 404 })
      if (body?.reasoning_effort === '__dsh_invalid_effort__') return new Response('', { status: 400 })
      validEffortCalls++
      return new Promise(resolve => release.push(() => resolve(jsonResponse({
        choices: [{ message: { reasoning_content: 'trace', content: '323' } }],
      }))))
    }
    const app = harness(descriptor)
    apply(app.ctx, {
      reasoningProbeEfforts: ['high'],
      visionProbe: false,
      requestTimeoutMs: 1_000,
    })
    await waitFor(() => validEffortCalls === 1)
    app.emit('credentials/reference-updated', 'ROTATING_KEY')
    release[0]()
    await waitFor(() => validEffortCalls === 2)
    assert.equal(app.mutations.length, 0)
    release[1]()
    await waitFor(() => app.mutations.length === 1)
    assert.equal(app.mutations[0].revision, 8)
    await app.dispose()
  })

  it('revalidates fields written while a credential update is in flight', async () => {
    const originalModel = { id: 'reasoner', input: ['text'] }
    const descriptor = {
      ns: 'llm-pi-ai',
      revision: 8,
      user: {
        providers: {
          local: {
            baseURL: 'http://127.0.0.1:3000/api',
            api: 'openai-completions',
            apiKeyEnv: 'ROTATING_KEY',
            models: [originalModel],
          },
        },
      },
      value: {
        providers: {
          local: {
            baseURL: 'http://127.0.0.1:3000/api',
            api: 'openai-completions',
            apiKeyEnv: 'ROTATING_KEY',
            models: [originalModel],
          },
        },
      },
    }
    let validEffortCalls = 0
    globalThis.fetch = async (_url, init) => {
      const body = init.body === undefined ? undefined : JSON.parse(init.body)
      if (init.method === 'GET') return jsonResponse({ data: [{ id: 'reasoner' }] })
      if (body?.model !== undefined && body.reasoning_effort === undefined) return new Response('', { status: 404 })
      if (body?.reasoning_effort === '__dsh_invalid_effort__') return new Response('', { status: 400 })
      validEffortCalls++
      return validEffortCalls === 1
        ? jsonResponse({ choices: [{ message: { reasoning_content: 'trace', content: '323' } }] })
        : new Response('', { status: 401 })
    }
    const app = harness(descriptor)
    let releaseFirstWrite
    const firstWrite = new Promise(resolve => { releaseFirstWrite = resolve })
    let mutationCalls = 0
    app.ctx.settings.mutate = async (ns, ops, revision) => {
      mutationCalls++
      if (mutationCalls === 1) {
        await firstWrite
        const savedModels = structuredClone(ops[0].value)
        descriptor.user.providers.local.models = savedModels
        descriptor.value.providers.local.models = savedModels
        descriptor.revision = 9
      }
      app.mutations.push({ ns, ops, revision })
    }
    apply(app.ctx, {
      reasoningProbeEfforts: ['high'],
      visionProbe: false,
      requestTimeoutMs: 1_000,
    })
    await waitFor(() => mutationCalls === 1)
    app.emit('credentials/reference-updated', 'ROTATING_KEY')
    releaseFirstWrite()
    await waitFor(() => app.mutations.length === 2)
    assert.equal(validEffortCalls, 2)
    assert.deepEqual(app.mutations[0].ops[0].value[0].reasoningEfforts, { high: 'high' })
    assert.deepEqual(app.mutations[1].ops[0].value, [originalModel])
    assert.equal(app.mutations[1].revision, 9)
    await app.dispose()
  })

  it('forgets tentative ownership when a model is removed', async () => {
    const originalModel = { id: 'reasoner', input: ['text'] }
    const descriptor = {
      ns: 'llm-pi-ai',
      revision: 8,
      user: {
        providers: {
          local: {
            baseURL: 'http://127.0.0.1:3000/api',
            api: 'openai-completions',
            apiKeyEnv: 'ROTATING_KEY',
            models: [originalModel],
          },
        },
      },
      value: {
        providers: {
          local: {
            baseURL: 'http://127.0.0.1:3000/api',
            api: 'openai-completions',
            apiKeyEnv: 'ROTATING_KEY',
            models: [originalModel],
          },
        },
      },
    }
    let validEffortCalls = 0
    globalThis.fetch = async (_url, init) => {
      const body = init.body === undefined ? undefined : JSON.parse(init.body)
      if (init.method === 'GET') return jsonResponse({ data: [{ id: 'reasoner' }] })
      if (body?.model !== undefined && body.reasoning_effort === undefined) return new Response('', { status: 404 })
      if (body?.reasoning_effort === '__dsh_invalid_effort__') return new Response('', { status: 400 })
      validEffortCalls++
      return validEffortCalls === 1
        ? jsonResponse({ choices: [{ message: { reasoning_content: 'trace', content: '323' } }] })
        : new Response('', { status: 401 })
    }
    const app = harness(descriptor)
    let releaseFirstWrite
    const firstWrite = new Promise(resolve => { releaseFirstWrite = resolve })
    let mutationCalls = 0
    let savedModel
    app.ctx.settings.mutate = async (ns, ops, revision) => {
      mutationCalls++
      await firstWrite
      savedModel = structuredClone(ops[0].value[0])
      descriptor.user.providers.local.models = []
      descriptor.value.providers.local.models = []
      descriptor.revision = 10
      app.mutations.push({ ns, ops, revision })
    }
    apply(app.ctx, {
      reasoningProbeEfforts: ['high'],
      visionProbe: false,
      requestTimeoutMs: 1_000,
    })
    await waitFor(() => mutationCalls === 1)
    app.emit('credentials/reference-updated', 'ROTATING_KEY')
    releaseFirstWrite()
    await waitFor(() => app.mutations.length === 1)
    await new Promise(resolve => setTimeout(resolve, 30))
    descriptor.user.providers.local.models = [savedModel]
    descriptor.value.providers.local.models = [savedModel]
    descriptor.revision = 11
    app.emit('settings/document-updated', 'llm-pi-ai', 11)
    await new Promise(resolve => setTimeout(resolve, 30))
    assert.equal(validEffortCalls, 1)
    assert.equal(app.mutations.length, 1)
    await app.dispose()
  })
})
