/* eslint local/no-changelog-comments: "off" */

import { createServer } from 'node:http';

import { describe, it, expect } from 'test-anywhere';

import {
  DEFAULT_ATTEMPTS,
  DEFAULT_RETRY_DELAY_MS,
  DEFAULT_TIMEOUT_MS,
  describeModule,
  loadCommandStream,
  loadLinoArguments,
  loadUse,
  resolveNamedExport,
  USE_M_URL,
} from '../scripts/use-module.mjs';

const dollar = () => {};

function commandStreamExports() {
  return Object.assign(() => {}, { $: dollar, sh: () => {}, run: () => {} });
}

/**
 * Namespace `import()` produces for a CommonJS file on Node < 22.12. use-m
 * unwraps it because `default` is the only key, so `const { $ }` works.
 */
function nodeTwentyNamespace() {
  return { default: commandStreamExports() };
}

/**
 * Same file on Node >= 22.12: the synthetic `module.exports` key makes use-m
 * skip the unwrap and hand the raw namespace to the caller.
 */
function nodeTwentyFourNamespace() {
  return {
    default: commandStreamExports(),
    'module.exports': commandStreamExports(),
  };
}

function textResponse(
  body,
  { ok = true, status = 200, statusText = 'OK' } = {}
) {
  return {
    ok,
    status,
    statusText,
    async text() {
      return body;
    },
  };
}

/**
 * Whether this runtime may bind a local socket. Deno denies it unless the run
 * was granted --allow-net, and the denial is not catchable at the listen call.
 * @returns {Promise<boolean>}
 */
async function canListen() {
  if (typeof Deno === 'undefined') {
    return true;
  }
  const status = await Deno.permissions.query({
    name: 'net',
    host: '127.0.0.1',
  });
  return status.state === 'granted';
}

describe('use-module interop shim', () => {
  it('reproduces the Node 24 namespace that breaks destructuring', () => {
    const { $ } = nodeTwentyFourNamespace();
    expect($).toBe(undefined);
  });

  it('resolves $ from the Node >= 22.12 CommonJS namespace', () => {
    const resolved = resolveNamedExport(
      nodeTwentyFourNamespace(),
      '$',
      'command-stream'
    );
    expect(typeof resolved.$).toBe('function');
  });

  it('resolves $ from the Node < 22.12 CommonJS namespace', () => {
    const resolved = resolveNamedExport(
      nodeTwentyNamespace(),
      '$',
      'command-stream'
    );
    expect(typeof resolved.$).toBe('function');
  });

  it('resolves $ when use-m already unwrapped the module', () => {
    const resolved = resolveNamedExport(
      commandStreamExports(),
      '$',
      'command-stream'
    );
    expect(typeof resolved.$).toBe('function');
  });

  it('resolves $ from a real ES module namespace with named exports', () => {
    const namespace = { $: dollar, sh: () => {}, default: dollar };
    const resolved = resolveNamedExport(namespace, '$', 'command-stream');
    expect(resolved).toBe(namespace);
  });

  it('resolves a double-wrapped default', () => {
    const resolved = resolveNamedExport(
      { default: { default: commandStreamExports() } },
      '$',
      'command-stream'
    );
    expect(typeof resolved.$).toBe('function');
  });

  it('names the observed keys when no candidate exposes the export', () => {
    let message = '';
    try {
      resolveNamedExport({ nope: 1 }, '$', 'command-stream');
    } catch (error) {
      message = error.message;
    }
    expect(message.includes("use('command-stream')")).toBe(true);
    expect(message.includes('keys [nope]')).toBe(true);
  });

  it('reports the received value when use-m resolved nothing', () => {
    let message = '';
    try {
      resolveNamedExport(undefined, '$', 'command-stream');
    } catch (error) {
      message = error.message;
    }
    expect(message.includes('Received undefined')).toBe(true);
  });

  it('describes null, primitives and objects', () => {
    expect(describeModule(null)).toBe('null');
    expect(describeModule(7)).toBe('number');
    expect(describeModule({ a: 1, b: 2 })).toBe('object with keys [a, b]');
  });

  it('loads command-stream through an injected use() implementation', async () => {
    const calls = [];
    const use = async (name) => {
      calls.push(name);
      return nodeTwentyFourNamespace();
    };
    const module = await loadCommandStream(use);
    expect(calls).toEqual(['command-stream']);
    expect(typeof module.$).toBe('function');
  });

  it('loads lino-arguments through an injected use() implementation', async () => {
    const calls = [];
    const use = async (name) => {
      calls.push(name);
      return { default: { makeConfig: () => ({}) } };
    };
    const module = await loadLinoArguments(use);
    expect(calls).toEqual(['lino-arguments']);
    expect(typeof module.makeConfig).toBe('function');
  });

  it('points at the unpinned use-m entry point', () => {
    expect(USE_M_URL).toBe('https://unpkg.com/use-m/use.js');
  });

  it('reports the HTTP status when use.js cannot be fetched', async () => {
    let message = '';
    try {
      await loadUse({
        fetchImpl: async () =>
          textResponse('<html>Not Found</html>', {
            ok: false,
            status: 404,
            statusText: 'Not Found',
          }),
        attempts: 1,
      });
    } catch (error) {
      message = error.message;
    }
    expect(message.includes('404')).toBe(true);
    expect(message.includes('Not Found')).toBe(true);
  });

  it('reports a use.js payload that exposes no callable use()', async () => {
    let message = '';
    try {
      await loadUse({
        fetchImpl: async () => textResponse('({ nope: 1 })'),
        attempts: 1,
      });
    } catch (error) {
      message = error.message;
    }
    expect(message.includes('did not export a callable "use"')).toBe(true);
  });

  it('evaluates a well-formed use.js payload', async () => {
    const use = await loadUse({
      fetchImpl: async () => textResponse('({ use: async () => ({}) })'),
    });
    expect(typeof use).toBe('function');
  });
});

describe('loadCommandStream turns on errexit', () => {
  function shellExports(errexitCalls) {
    return Object.assign(commandStreamExports(), {
      shell: {
        errexit: (value) => {
          errexitCalls.push(value);
        },
      },
    });
  }

  it('enables shell.errexit on the resolved module', async () => {
    const errexitCalls = [];
    const use = async () => ({ default: shellExports(errexitCalls) });

    await loadCommandStream(use);

    expect(errexitCalls).toEqual([true]);
  });

  it('still loads a module that exposes no shell', async () => {
    const use = async () => ({ default: commandStreamExports() });

    const module = await loadCommandStream(use);

    expect(typeof module.$).toBe('function');
  });
});

describe('use-m load is bounded in time and retried', () => {
  it('passes a deadline to every attempt', async () => {
    const signals = [];
    await loadUse({
      fetchImpl: async (_url, init) => {
        signals.push(init?.signal);
        return textResponse('({ use: async () => ({}) })');
      },
      timeoutMs: 15000,
    });
    expect(signals.length).toBe(1);
    expect(signals[0] instanceof AbortSignal).toBe(true);
  });

  it('retries a transient failure and returns the later success', async () => {
    const delays = [];
    let attempts = 0;
    const use = await loadUse({
      fetchImpl: async () => {
        attempts += 1;
        if (attempts < 3) {
          throw new TypeError('fetch failed');
        }
        return textResponse('({ use: async () => ({}) })');
      },
      retryDelayMs: 10,
      sleep: async (ms) => {
        delays.push(ms);
      },
    });
    expect(attempts).toBe(3);
    expect(typeof use).toBe('function');
    // Exponential backoff: 10ms then 20ms.
    expect(delays).toEqual([10, 20]);
  });

  it('stops after the configured number of attempts', async () => {
    let attempts = 0;
    await loadUse({
      fetchImpl: async () => {
        attempts += 1;
        throw new TypeError('fetch failed');
      },
      attempts: 2,
      sleep: async () => {},
    }).catch(() => {});
    expect(attempts).toBe(2);
  });

  it('names the URL, the attempt count and the last reason', async () => {
    let error;
    try {
      await loadUse({
        fetchImpl: async () => {
          throw new TypeError('fetch failed');
        },
        url: 'https://203.0.113.1/use-m/use.js',
        attempts: 2,
        sleep: async () => {},
      });
    } catch (caught) {
      error = caught;
    }
    expect(error.message.includes('https://203.0.113.1/use-m/use.js')).toBe(
      true
    );
    expect(error.message.includes('after 2 attempt(s)')).toBe(true);
    expect(error.message.includes('fetch failed')).toBe(true);
    expect(error.message.includes('network dependency')).toBe(true);
  });

  it('preserves the original failure as the error cause', async () => {
    const original = new TypeError('fetch failed');
    let error;
    try {
      await loadUse({
        fetchImpl: async () => {
          throw original;
        },
        attempts: 1,
        sleep: async () => {},
      });
    } catch (caught) {
      error = caught;
    }
    expect(error.cause).toBe(original);
  });

  it('retries a non-2xx response instead of eval-ing an error page', async () => {
    let attempts = 0;
    let error;
    try {
      await loadUse({
        fetchImpl: async () => {
          attempts += 1;
          return textResponse('<html>Bad Gateway</html>', {
            ok: false,
            status: 502,
            statusText: 'Bad Gateway',
          });
        },
        attempts: 2,
        sleep: async () => {},
      });
    } catch (caught) {
      error = caught;
    }
    expect(attempts).toBe(2);
    expect(error.message.includes('502')).toBe(true);
  });

  it('aborts an attempt that exceeds the deadline', async () => {
    let error;
    try {
      await loadUse({
        // Never settles on its own; only the deadline can end it.
        fetchImpl: (_url, init) =>
          new Promise((_resolve, reject) => {
            init.signal.addEventListener('abort', () =>
              reject(new Error('aborted'))
            );
          }),
        url: 'https://unpkg.com/use-m/use.js',
        attempts: 1,
        timeoutMs: 50,
        sleep: async () => {},
      });
    } catch (caught) {
      error = caught;
    }
    expect(error.message.includes('after 1 attempt(s)')).toBe(true);
    expect(error.cause.message.includes('Timed out after 50ms')).toBe(true);
  });
});

describe('use-m load survives a stalled connection', () => {
  it('bounds a real connection that is accepted and never answered', async () => {
    // A stalled connection is bounded only by undici's 300s headersTimeout
    // default, so without a per-attempt deadline one fetch can burn five
    // minutes of the job's budget.
    //
    // Binding a socket needs a permission the Deno job does not grant (it runs
    // with --allow-read alone) and the denial surfaces as an uncaught
    // NotCapable from inside the listen handle, so the check is skipped there;
    // the Node and Bun runs of this same test keep the coverage.
    if (!(await canListen())) {
      console.log(
        'Skipping: this runtime is not allowed to listen on 127.0.0.1.'
      );
      return;
    }
    const server = createServer(() => {});
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const url = `http://127.0.0.1:${server.address().port}/use-m/use.js`;
    const started = Date.now();
    let error;
    try {
      await loadUse({
        url,
        attempts: 1,
        timeoutMs: 300,
        sleep: async () => {},
      });
    } catch (caught) {
      error = caught;
    } finally {
      server.close();
    }
    expect(error.message.includes(url)).toBe(true);
    expect(Date.now() - started < 10000).toBe(true);
  });

  it('exposes the defaults that keep the worst case inside a job budget', () => {
    // 3 x 15s of attempts plus 2s + 4s of backoff = 51s.
    expect(DEFAULT_ATTEMPTS * DEFAULT_TIMEOUT_MS).toBe(45000);
    expect(DEFAULT_RETRY_DELAY_MS).toBe(2000);
  });
});
