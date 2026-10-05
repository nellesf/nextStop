// The only upstream gaxios6 UUID use is a v4 multipart boundary. Exercise that
// actual transport-preparation path after the narrowly scoped uuid11 override.
const assert = require('node:assert/strict');
const { createRequire } = require('node:module');
const path = require('node:path');
const test = require('node:test');
const backend = createRequire(path.resolve(__dirname, '../../backend/package.json'));
const storage = createRequire(backend.resolve('@google-cloud/storage'));
const { Gaxios } = storage('gaxios');

test('storage gaxios6 builds valid unique multipart boundaries with patched CommonJS uuid', async () => {
  const boundaries = new Set();
  for (let index = 0; index < 3; index += 1) {
    const client = new Gaxios({ adapter: async (options) => {
      const contentType = options.headers['Content-Type'];
      assert.match(contentType, /^multipart\/related; boundary=[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
      const boundary = contentType.split('boundary=')[1];
      boundaries.add(boundary);
      const chunks = [];
      for await (const chunk of options.body) chunks.push(Buffer.from(chunk));
      const body = Buffer.concat(chunks).toString();
      assert.ok(body.includes(`--${boundary}`));
      assert.ok(body.includes('public-fixture'));
      return { config: options, data: {}, headers: {}, status: 200, statusText: 'OK' };
    }});
    await client.request({ url: 'https://example.invalid/upload', method: 'POST',
      multipart: [{ headers: { 'Content-Type': 'text/plain' }, content: 'public-fixture' }] });
  }
  assert.equal(boundaries.size, 3);
});
