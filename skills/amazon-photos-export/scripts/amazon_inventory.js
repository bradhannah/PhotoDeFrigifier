// Amazon Photos / Drive inventory, run inside a signed-in Amazon Photos tab (www.amazon.<tld>/photos).
// Read-only: GET requests only. The session never leaves the page.
//
// Usage with a browser tool such as javascript_tool:
//   1. Run this whole file once. It starts the job in the background and returns at once, so it
//      doesn't hit the tool's ~45 s timeout.
//   2. Poll `window.AMZ.progress` every few seconds until `done` is true, or `error` is set.
//   3. Read the results:
//        JSON.stringify(window.AMZ.summary())        totals by extension, size, missing MD5s
//        window.AMZ.manifest()                       [{id, path, md5, size, contentDate, ...}], ready to save
//   4. To save the manifest, make a blob link and click it. The user must allow the download.
//
// Paging uses /nodes with startToken, which proved reliable (16,500 files, no repeats). Offset paging on
// /search was not.
(() => {
  const sid = (document.cookie.match(/(?:^|;\s*)session-id=([^;]+)/) || [])[1];
  const AMZ = (window.AMZ = { progress: { phase: 'starting', pages: 0, items: 0, done: false, error: null },
                               folders: new Map(), files: [] });
  if (!sid) { AMZ.progress.error = 'No session-id cookie: sign in to Amazon Photos in this tab first.'; return AMZ.progress; }

  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const get = async (path, params = {}) => {
    const q = new URLSearchParams({ resourceVersion: 'V2', ContentType: 'JSON', ...params });
    for (let attempt = 1; ; attempt++) {
      const r = await fetch(`/drive/v1/${path}?${q}`, {
        credentials: 'include', headers: { accept: 'application/json', 'x-amzn-sessionid': sid } });
      if (r.ok) return r.json();
      if (r.status === 401 || r.status === 403) throw new Error(`HTTP ${r.status}: signed out or session expired`);
      if (r.status === 400) throw new Error(`HTTP 400 for ${path}: request shape rejected (API may have changed)`);
      if (attempt >= 4) throw new Error(`HTTP ${r.status} for ${path} after ${attempt} tries`);
      await sleep(1000 * attempt);
    }
  };

  const pageAll = async (kind, onNode) => {
    let token;
    do {
      const page = await get('nodes', { filters: `kind:${kind}`, limit: 200, ...(token ? { startToken: token } : {}) });
      (page.data || []).forEach(onNode);
      AMZ.progress.pages++;
      token = page.nextToken;
      await sleep(200);
    } while (token);
  };

  const pathOf = (parentIds) => {
    const parts = [];
    let id = parentIds && parentIds[0];
    for (let guard = 0; id && guard < 64; guard++) {
      const f = AMZ.folders.get(id);
      if (!f) break;
      if (f.name) parts.unshift(f.name);
      id = f.parent;
    }
    return parts.join('/');
  };

  AMZ.manifest = () => AMZ.files.map(f => ({ ...f, path: [pathOf(f.parents), f.name].filter(Boolean).join('/') }));
  AMZ.summary = () => {
    const byExt = {};
    let bytes = 0, noMd5 = 0;
    for (const f of AMZ.files) {
      const e = (f.extension || '').toLowerCase();
      byExt[e] = (byExt[e] || 0) + 1;
      bytes += f.size || 0;
      if (!f.md5) noMd5++;
    }
    const ids = new Set(AMZ.files.map(f => f.id));
    return { files: AMZ.files.length, uniqueIds: ids.size, folders: AMZ.folders.size, gigabytes: +(bytes / 1e9).toFixed(2),
             missingMd5: noMd5, byExtension: byExt };
  };

  AMZ.run = (async () => {
    try {
      AMZ.progress.phase = 'folders';
      await pageAll('FOLDER', n => AMZ.folders.set(n.id, { name: n.name, parent: (n.parents || [])[0] }));
      AMZ.progress.phase = 'files';
      await pageAll('FILE', n => {
        const c = n.contentProperties || {};
        AMZ.files.push({ id: n.id, name: n.name, parents: n.parents || [], status: n.status, ownerId: n.ownerId,
                         size: c.size, md5: c.md5, contentType: c.contentType, extension: c.extension,
                         contentDate: c.contentDate, createdDate: n.createdDate, modifiedDate: n.modifiedDate,
                         favorite: !!(n.settings && n.settings.favorite) });
        AMZ.progress.items = AMZ.files.length;
      });
      AMZ.progress.phase = 'complete';
      AMZ.progress.done = true;
    } catch (e) {
      AMZ.progress.error = String(e && e.message || e);
      AMZ.progress.done = true;
    }
  })();
  return AMZ.progress;
})();
