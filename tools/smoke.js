// jsdom smoke test of the built editor (logic only: jsdom has no layout).
//   NODE_PATH=<dir with jsdom> node tools/smoke.js mockup/pipeline-editor.html
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

const file = process.argv[2] || 'mockup/pipeline-editor.html';
const html = fs.readFileSync(file, 'utf8');
const errors = [];

function makeDom(src, extra = {}, errs = errors) {
  const vcx = new VirtualConsole();
  vcx.on('error', (...a) => errs.push(a.join(' ')));
  vcx.on('jsdomError', e => errs.push(String(e && (e.stack || e.message) || e)));
  return new JSDOM(src, {
    runScripts: 'dangerously', pretendToBeVisual: true, virtualConsole: vcx, url: extra.url,
    beforeParse(w) {
      w.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
      w.addEventListener('error', e => errs.push(String(e.error && e.error.stack || e.message)));
      if (extra.fetch) w.fetch = extra.fetch;
    },
  });
}
const dom = makeDom(html);
let w = dom.window, d = w.document;
let failed = 0;
const ok = (cond, msg) => { console.log(`${cond ? 'ok  ' : 'FAIL'} ${msg}`); if (!cond) failed++; };
const $$ = s => [...d.querySelectorAll(s)];
const shown = el => !!el && !el.closest('[hidden]');
const click = el => {
  if (!el) return;
  const opts = { bubbles: true, button: 0, clientX: 1, clientY: 1, pointerId: 1 };
  const Ev = w.PointerEvent || w.MouseEvent;
  el.dispatchEvent(new Ev('pointerdown', opts));
  el.dispatchEvent(new Ev('pointerup', opts));
  el.dispatchEvent(new w.MouseEvent('click', opts));
};
const key = (k, extra = {}) => d.body.dispatchEvent(new w.KeyboardEvent('keydown', { key: k, bubbles: true, ...extra }));
const wait = ms => new Promise(r => setTimeout(r, ms));
const openModalOf0 = async id => { d.querySelector(`#nodes .node[data-id="${id}"]`).dispatchEvent(new w.MouseEvent('dblclick', { bubbles: true })); await wait(30); };
const colour = el => (el.className.match(/mc-\d/) || [''])[0];

(async () => {
  await wait(50);
  const model = JSON.parse(d.getElementById('pipeworks-data').textContent);
  const blocks = [].concat(model.blocks);

  ok(!d.querySelector('link[href*="fonts.googleapis"]'), 'no Google Fonts links');
  ok(d.getElementById('nodata').hidden, 'model loaded');

  // one box per block
  const groups = $$('#groups .group').map(g => g.dataset.block);
  ok(groups.length === blocks.length && blocks.every(b => groups.includes(b)), `one box per block: ${groups.join(', ')}`);
  ok($$('#blocks .fam').length === blocks.length, 'sidebar lists the blocks');
  ok(!/@family/.test(d.querySelector('.canvas-hint').textContent), 'no family drop hint');

  // maps: folded cards with pills
  const nTargets = model.targets.length;
  const nodes = () => $$('#nodes .node').length;
  const folded = nodes();
  ok(folded === nTargets - 3, `folded: ${folded} nodes for ${nTargets} targets (6 variants -> 3 cards)`);
  const stacks = $$('#nodes .node.stack');
  ok(stacks.length === 3, `3 stacked cards: ${stacks.map(s => s.dataset.id).join(', ')}`);
  const pillText = $$('#nodes .mpill').map(p => p.textContent.trim());
  ok(pillText.includes('spec ×2') && pillText.includes('area ×2'), `pill texts: ${[...new Set(pillText)].join(', ')}`);
  const areaCards = stacks.filter(n => n.dataset.id.startsWith('map:area_data+area_hist'));
  ok(areaCards.length === 2 && colour(areaCards[0]) && colour(areaCards[0]) === colour(areaCards[1]), 'cards of one map share its colour');
  const fitCard = stacks.find(n => n.dataset.id === 'map:model_fit::model_fit');
  ok(fitCard && colour(fitCard) && colour(fitCard) !== colour(areaCards[0]), 'different maps get different colours');
  ok($$('#nodes .chip').some(c => c.textContent === '×?'), 'dynamic branch marker ×?');
  ok($$('#edges .edge-g').length > 0, 'edges drawn');

  // unfold the spanning map: all its targets across both blocks
  click(d.querySelector('#nodes .mpill[data-map="map:area_data+area_hist"]'));
  await wait(30);
  ok(nodes() === folded + 2, `unfold area: ${nodes()} nodes`);
  ok(['area_data_urban', 'area_data_rural', 'area_hist_urban', 'area_hist_rural'].every(n => d.querySelector(`#nodes .node[data-id="${n}"]`)), 'area variants shown in both blocks');
  const areaPills = $$('#nodes .mpill[data-map="map:area_data+area_hist"]').map(p => p.textContent.trim());
  ok(areaPills.length === 4 && areaPills.every(t => t === 'collapse'), 'unfolded pills read "collapse"');
  click(d.querySelector('#nodes .mpill[data-map="map:model_fit"]'));
  await wait(30);
  ok(nodes() === nTargets, `everything unfolded: ${nodes()} nodes`);
  ok(d.querySelector('#nodes .node[data-id="model_fit_full"]'), 'model_fit_full shown');
  click(d.querySelector('#nodes .mpill[data-map="map:area_data+area_hist"]'));
  await wait(30);
  ok(nodes() === nTargets - 2, `fold area again: ${nodes()} nodes`);
  click(d.querySelector('#maps .mpill[data-map="map:model_fit"]'));
  await wait(30);
  ok(nodes() === folded, `fold model_fit from the sidebar: ${nodes()} nodes`);

  // selection still shows in/out flows on cards
  let card = d.querySelector('#nodes .node[data-id="map:model_fit::model_fit"]');
  click(card);
  ok(d.querySelector('#nodes .node.sel[data-id="map:model_fit::model_fit"]'), 'card selectable');
  ok($$('#nodes .node.dim').length > 0, 'selection dims unrelated nodes');
  ok($$('#edges .edge-g.hl').length > 0, 'selection highlights flows');
  key('Escape');

  // QA overlay
  if (model.qa_summary) {
    ok(!d.getElementById('qa-bar').hidden, 'QA bar shown');
    const s = model.qa_summary, txt = d.getElementById('qa-progress').textContent;
    ok(txt === `${s.done} of ${s.total} done · ${s.open} open${s.wrong ? ` · ${s.wrong} wrong` : ''}${s.check_again ? ` · ${s.check_again} check again` : ''}`, `progress text: "${txt}"`);
    const outside = (s.outside || []).filter(o => !o.passing);
    ok(!d.getElementById('qa-outside-section').hidden, 'items outside the canvas listed in the sidebar');
    ok($$('#qa-outside [data-qaloc]').length === outside.length && outside.length > 0, `open items outside the canvas: ${$$('#qa-outside [data-qaloc]').map(b => b.dataset.qaloc).join(', ')}`);
    ok(d.getElementById('btn-outside')?.textContent.startsWith(`${outside.length} of ${(s.outside || []).length}`), 'QA bar counts items outside the canvas');
    click(d.querySelector('#qa-outside [data-qaloc]'));
    ok(d.getElementById('drawer').classList.contains('open'), 'an outside item opens its source');
    ok(d.getElementById('canvas').classList.contains('qa-on'), 'canvas has QA overlay on');
    for (const c of ['qa-todo', 'qa-doubt', 'qa-ok']) ok($$(`#nodes .node.${c}`).length > 0, `nodes with ${c}: ${$$(`#nodes .node.${c}`).map(n => n.dataset.id).join(', ')}`);
    ok(d.querySelector('#nodes .node[data-id="channel_counts"]').classList.contains('qa-todo'), 'channel_counts needs review');
    ok(d.querySelector('#nodes .node[data-id="clean_data"]').classList.contains('qa-todo'), 'clean_data: its function changed -> needs review');
    const rs = d.querySelector('#nodes .node[data-id="region_summary"]');
    ok(rs.classList.contains('qa-doubt') && !rs.classList.contains('qa-bad'), 'region_summary: questionable function is amber (qa-doubt), not red');
    ok(!$$('#nodes .node.qa-bad').length, 'no red nodes without a wrong verdict');
    ok(!$$('.inp.sel, .txt.sel, .select.sel, .inp.dim, .txt.dim, .inp.hl, .inp.drop').length, 'state classes not on form controls');
    d.querySelector('#nodes .node[data-id="region_summary"]').dispatchEvent(new w.MouseEvent('dblclick', { bubbles: true }));
    await wait(30);
    const qa = d.getElementById('m-qa');
    ok(qa && /questionable/.test(qa.textContent), 'modal shows QA status');
    ok(qa && /Group by region/.test(qa.textContent), 'modal shows verdict history');
    ok(qa && qa.textContent.includes('pipeworks::qa_review("function:summarise_region", "correct")'), 'modal shows the qa_review() call');
    ok(qa && qa.querySelector('[data-copy]'), 'copy button');
    ok(qa && !qa.querySelector('[data-verdict]'), 'static page: no verdict buttons in the modal');
    key('Escape');
    await wait(10);
    ok(d.getElementById('overlay').hidden, 'modal closes');
    // diff against base for a changed function
    d.querySelector('#nodes .node[data-id="clean_data"]').dispatchEvent(new w.MouseEvent('dblclick', { bubbles: true }));
    await wait(30);
    const adds = $$('#m-qa .qa-diff .d-add').map(x => x.textContent);
    ok(adds.some(t => t.includes('age >= 18')), `diff against base shows the added line: ${adds.join(' | ')}`);
    ok($$('#m-qa .qa-diff span').every(x => !x.querySelector('*')), 'diff lines are escaped text');
    key('Escape');
    await wait(10);
    d.querySelector('#nodes .node[data-id="channel_counts"]').dispatchEvent(new w.MouseEvent('dblclick', { bubbles: true }));
    await wait(30);
    ok(/New in this branch/.test(d.getElementById('m-qa').textContent), 'new item: "New in this branch"');
    key('Escape');
    await wait(10);
    click(d.getElementById('btn-qa'));
    ok(!d.getElementById('canvas').classList.contains('qa-on'), 'overlay toggles off');
    click(d.getElementById('btn-qa'));
    ok(d.getElementById('canvas').classList.contains('qa-on'), 'overlay toggles on');
  } else {
    ok(d.getElementById('qa-bar').hidden, 'no QA bar without qa_summary');
  }

  // modes on the static page: Review while items are open, the switch still works
  const isReview = () => d.getElementById('mode-review')?.getAttribute('aria-pressed') === 'true';
  ok(!model.qa_summary || !model.qa_summary.open || isReview(), 'static page with open items starts in Review mode');
  ok(!shown(d.getElementById('btn-add')) && !$$('#nodes .port').length, 'Review mode: no add button, no ports');
  click(d.querySelector('#nodes .node[data-id="clean_data"]'));
  ok(!shown(d.querySelector('#nodebar [data-act="remove"]')), 'Review mode: no Remove on the node toolbar');
  ok(!d.querySelector('#nodebar [data-verdict]:not([hidden])'), 'static page: no verdict buttons on the node toolbar');
  key('Delete');
  ok(d.querySelector('#nodes .node[data-id="clean_data"]'), 'Review mode: Delete does not remove');
  d.querySelector('#canvas').dispatchEvent(new w.MouseEvent('dblclick', { bubbles: true, clientX: 5, clientY: 5 }));
  await wait(30);
  ok(d.getElementById('overlay').hidden, 'Review mode: double-click on the canvas adds nothing');
  key('Escape');
  click(d.getElementById('mode-build'));
  ok(!isReview() && shown(d.getElementById('btn-add')) && $$('#nodes .port').length > 0, 'Build mode: add button and ports back');

  // modal of a folded card opens its first variant
  card = d.querySelector('#nodes .node[data-id="map:model_fit::model_fit"]');
  card.dispatchEvent(new w.MouseEvent('dblclick', { bubbles: true }));
  await wait(30);
  ok(/variant/.test(d.getElementById('modal').textContent), 'card modal explains the variant');
  ok(d.getElementById('m-locked'), 'folded card: "Unfold the map to change single variants"');
  ok(!d.querySelector('#modal [data-m="remove"]'), 'folded card: no Remove button');
  ok(d.getElementById('m-name').readOnly && d.getElementById('m-pattern').readOnly && d.getElementById('m-format').disabled && !d.getElementById('m-plug'), 'folded card: target fields read-only');
  ok(!d.getElementById('m-title').readOnly, 'folded card: function documentation stays editable');
  d.getElementById('m-name').value = 'renamed_variant';
  d.getElementById('m-name').dispatchEvent(new w.Event('input', { bubbles: true }));
  d.querySelector('#modal [data-m="save"]').click();
  await wait(10);
  click(d.querySelector('#nodes .mpill[data-map="map:model_fit"]'));
  await wait(30);
  ok(d.querySelector('#nodes .node[data-id="model_fit_base"] .n-name').textContent === 'model_fit_base', 'Apply on a folded card does not rename the variant');
  d.querySelector('#nodes .node[data-id="model_fit_base"]').dispatchEvent(new w.MouseEvent('dblclick', { bubbles: true }));
  await wait(30);
  ok(d.querySelector('#modal [data-m="remove"]') && !d.getElementById('m-name').readOnly, 'unfolded variant: editable again');
  key('Escape');
  await wait(10);
  click(d.querySelector('#nodes .mpill[data-map="map:model_fit"]'));
  await wait(30);

  // static page: today's wording; the preview indents tag continuation lines like R's rox_lines()
  await openModalOf0('raw_data');
  ok(/Writing to files comes with the live connection/.test(d.querySelector('#modal .m-foot').textContent), 'static dialog keeps "Writing to files comes with the live connection"');
  const pdesc = d.querySelector('#modal textarea[data-p="path"]');
  pdesc.value = 'Path to the survey CSV export as written by the survey tool, relative to the project root directory.';
  pdesc.dispatchEvent(new w.Event('input', { bubbles: true }));
  const prev = d.getElementById('m-preview').textContent.split('\n');
  const at = prev.findIndex(l => l.startsWith("#' @param path"));
  ok(at >= 0 && /^#'   \S/.test(prev[at + 1]) && prev[at].length <= 76, `preview: @param continuation indented "#'   ": ${JSON.stringify(prev.slice(at, at + 2))}`);
  key('Escape');
  await wait(10);

  // remove + undo still work
  const before = nodes();
  click(d.querySelector('#nodes .node[data-id="hist_raw"]'));
  key('Delete');
  await wait(10);
  ok(nodes() === before - 1, 'remove a target');
  key('z', { ctrlKey: true });
  await wait(10);
  ok(nodes() === before, 'undo restores it');
  click(d.querySelector('#nodes .node[data-id="map:model_fit::model_fit"]'));
  key('Delete');
  ok(nodes() === before && /Unfold/.test(d.getElementById('toast-msg').textContent), 'a folded card cannot be removed');

  // Hidden overlays must not render outside the artifact viewer (which adds its own [hidden] reset).
  for (const id of ['nodata', 'overlay']) {
    const el = d.getElementById(id);
    ok(el.hidden && w.getComputedStyle(el).display === 'none', `#${id} is not displayed while hidden`);
  }

  // sidebar toggle and theme switch
  const sb = d.querySelector('.sidebar'), sbBtn = d.getElementById('btn-sidebar');
  ok(sbBtn && sbBtn.getAttribute('aria-expanded') === 'true' && !sb.hidden, 'sidebar shown, toggle says expanded');
  if (sbBtn) click(sbBtn);
  ok(sb.hidden && sbBtn?.getAttribute('aria-expanded') === 'false', 'sidebar toggle hides the sidebar');
  if (sbBtn) click(sbBtn);
  ok(!sb.hidden && sbBtn?.getAttribute('aria-expanded') === 'true', 'sidebar toggle shows it again');
  const theme = () => d.documentElement.getAttribute('data-theme');
  const seen = [theme()];
  for (let i = 0; i < 3; i++) { const b = d.getElementById('btn-theme'); if (b) click(b); seen.push(theme()); }
  ok(JSON.stringify(seen) === JSON.stringify([null, 'light', 'dark', null]), `theme cycles System -> Light -> Dark -> System: ${seen.join(' -> ')}`);

  await wait(600);
  ok(errors.length === 0, `no console errors${errors.length ? ':\n' + errors.join('\n') : ''}`);
  w.close();

  // ---------- Live page: the same model served by pipeworks(), with a fake R server behind fetch ----------
  console.log('\n# live page');
  const TOKEN = 'tok123';
  const live0 = { version: 1, mode: 'review', base: 'main', can_record: true, blockers: [], blocked_reason: null, qa_error: null, watch_error: null, uncommitted: ['qa/reviews/a.json', 'qa/reviews/b.json'] };
  const server = {
    model: { ...JSON.parse(JSON.stringify(model)), live: live0, model_error: null },
    calls: [], badToken: 0, absolute: 0, down: false, refuse: null,
    open: { ok: false, error: 'No editor can be opened from this R session; open R/clean.R:3 yourself.' },
    bump() { this.model.live.version++; },
    setStatus(item, status) {
      const fix = q => { if (q && q.item === item) { q.status = status; q.passing = status === 'correct'; } };
      this.model.targets.forEach(t => { fix(t.qa); fix(t.qa_file); });
      this.model.functions.forEach(f => fix(f.qa));
    },
  };
  const reply = (status, body, type = 'application/json') => ({
    ok: status >= 200 && status < 300, status,
    headers: { get: k => (k.toLowerCase() === 'content-type' ? type : null) },
    json: async () => (typeof body === 'string' ? JSON.parse(body) : JSON.parse(JSON.stringify(body))),
    text: async () => (typeof body === 'string' ? body : JSON.stringify(body)),
  });
  const makeFetch = server => async (url, opts = {}) => {
    await wait(5);
    url = String(url);
    if (url.startsWith('/') || /^https?:/.test(url)) server.absolute++;
    const h = opts.headers || {}, tok = typeof h.get === 'function' ? h.get('X-Pipeworks-Token') : h['X-Pipeworks-Token'];
    if (tok !== TOKEN) server.badToken++;
    const method = (opts.method || 'GET').toUpperCase(), body = opts.body ? JSON.parse(opts.body) : null;
    server.calls.push({ url, method, body });
    if (server.down) throw new TypeError('Failed to fetch');
    if (server.refuse) return reply(403, server.refuse, 'text/plain; charset=utf-8');
    if (url === 'api/version') return reply(200, { version: server.model.live.version });
    if (url === 'api/model') return reply(200, server.model);
    if (url === 'api/open' && method === 'POST') return reply(200, server.open);
    if (url === 'api/verdict' && method === 'POST') {
      if (server.next409) { const msg = server.next409; server.next409 = null; return reply(409, { error: msg }); }
      server.setStatus(body.item, body.verdict); server.bump();
      if (server.commitFails) { const msg = server.commitFails; server.commitFails = null; return reply(200, { ok: true, committed: false, commit: null, error: msg, entry: {}, file: 'qa/reviews/x.json', version: server.model.live.version }); }
      return reply(200, { ok: true, committed: true, commit: 'abc1234def5678', error: null, entry: {}, file: 'qa/reviews/x.json', version: server.model.live.version });
    }
    if (url === 'api/retry' && method === 'POST') {
      await wait(30);
      server.model.live.uncommitted = [];
      server.bump();
      return reply(200, { ok: true, results: [{ file: 'qa/reviews/x.json', committed: true, error: null }], version: server.model.live.version });
    }
    if (url === 'api/edit' && method === 'POST') {
      if (server.delay) await wait(server.delay);
      if (server.editReply) { const r = server.editReply; server.editReply = null; return reply(r.status, r.body); }
      server.seq = (server.seq || 0) + 1; server.bump(); server.model.live.building = true;
      return reply(200, { ok: true, write_id: 'w' + server.seq, version: server.model.live.version, files: server.files || ['R/import.R'], notes: server.notes || [] });
    }
    if (url === 'api/undo' && method === 'POST') {
      server.bump(); server.model.live.building = true;
      return reply(200, { ok: true, version: server.model.live.version, files: ['R/import.R'] });
    }
    return reply(404, { error: 'Not found.' });
  };
  const fakeFetch = makeFetch(server);
  const liveHtml = html.replace(/(<script id="pipeworks-data" type="application\/json">)[\s\S]*?(<\/script>)/,
    (m0, a, b) => a + JSON.stringify(server.model).replace(/</g, '\\u003c') + b);
  const liveErrors = [];
  const ldom = makeDom(liveHtml, { url: `http://127.0.0.1:7777/?token=${TOKEN}`, fetch: fakeFetch }, liveErrors);
  w = ldom.window; d = w.document;
  await wait(100);
  const calls = (u, m = 'POST') => server.calls.filter(c => c.url === u && c.method === m);
  ok(w.location.search === '' && w.location.pathname === '/', `token removed from the address bar: ${w.location.href}`);
  ok(w.sessionStorage.getItem('pipeworks-token') === TOKEN, 'token kept in sessionStorage');
  await wait(2200);
  ok(calls('api/version', 'GET').length > 0, 'polls api/version');
  ok(server.badToken === 0 && server.calls.length > 0, `every request sends X-Pipeworks-Token (${server.calls.length} requests)`);
  ok(server.absolute === 0, 'every request uses a relative api/ URL');

  // Review mode (live.mode): structure read-only, verdict buttons shown
  const liveReview = () => d.getElementById('mode-review')?.getAttribute('aria-pressed') === 'true';
  // poll now: the page polls at once when the tab becomes visible again
  const nudge = async () => { d.dispatchEvent(new w.Event('visibilitychange')); await wait(120); };
  const banners = () => d.getElementById('banners').textContent;
  const XSS = '<img src=x onerror="window.__xss=1">';

  // verdicts left uncommitted show a banner from the first load, with a Retry that goes through api/retry
  const ub = () => d.getElementById('b-uncommitted');
  ok(ub() && /2 verdicts saved but not committed/.test(ub().textContent), `uncommitted banner on a fresh load: "${ub()?.textContent}"`);
  const nRetry = calls('api/retry').length;
  ub().querySelector('button').click();
  ub()?.querySelector('button')?.click();
  await wait(150);
  ok(calls('api/retry').length === nRetry + 1, 'Retry in the banner posts api/retry once (busy-guarded)');
  await nudge();
  ok(!ub(), 'banner gone once nothing is uncommitted');

  ok(liveReview(), 'live page starts in the mode of live.mode (review)');
  ok(!shown(d.getElementById('btn-add')) && !$$('#nodes .port').length, 'Review: no add button, no ports');
  const n0 = nodes();
  key('n'); key('z', { ctrlKey: true });
  await wait(30);
  ok(nodes() === n0 && d.getElementById('overlay').hidden, 'Review: N and Ctrl+Z do nothing');
  const cardEdge = $$('#edges .edge-hit').find(e => e.dataset.edge.split('>').every(x => x.includes('::')));
  click(cardEdge);
  key('Delete');
  ok(cardEdge && /Switch to Build mode/.test(d.getElementById('toast-msg').textContent), `Review: Delete on an edge between folded cards says Build only: "${d.getElementById('toast-msg').textContent}"`);
  key('Escape');
  const cleanNode = () => d.querySelector('#nodes .node[data-id="clean_data"]');
  ok(cleanNode().classList.contains('qa-todo'), 'clean_data needs review before the verdict');
  click(cleanNode());
  ok(!shown(d.querySelector('#nodebar [data-act="remove"]')), 'Review: no Remove on the node toolbar');
  ok($$('#nodebar [data-verdict]').filter(shown).length === 3, 'Review: Correct / Questionable / Wrong on the node toolbar');
  const openModalOf = async id => { d.querySelector(`#nodes .node[data-id="${id}"]`).dispatchEvent(new w.MouseEvent('dblclick', { bubbles: true })); await wait(30); };
  await openModalOf('clean_data');
  const panelOf = item => d.querySelector(`#m-qa [data-vitem="${item}"]`);
  const panel = () => panelOf('function:clean_survey');
  const resultOf = item => panelOf(item)?.querySelector('.v-result')?.textContent || '';
  ok(panel() && panel().querySelectorAll('[data-verdict]').length === 3, 'modal: verdict buttons for function:clean_survey');
  ok(!d.querySelector('#m-qa [data-copy]'), 'live modal: buttons instead of the qa_review() call');
  ok(!shown(d.querySelector('#modal [data-m="save"]')) && !d.querySelector('#modal [data-m="remove"]'), 'Review: no Apply, no Remove in the modal');
  ok(d.getElementById('m-name').readOnly && d.getElementById('m-format').disabled && d.getElementById('m-pattern').readOnly && d.getElementById('m-body').readOnly && !d.getElementById('m-plug'), 'Review: name, body, format, pattern and wiring read-only');

  // questionable without a comment is not sent
  panel().querySelector('[data-verdict="questionable"]').click();
  await wait(50);
  ok(calls('api/verdict').length === 0, 'questionable without a comment is not sent');
  ok(/comment/i.test(resultOf('function:clean_survey')), `asks for a comment: "${resultOf('function:clean_survey')}"`);

  // a correct verdict, pressed twice, is recorded and committed once
  panel().querySelector('[data-verdict="correct"]').click();
  panel().querySelector('[data-verdict="correct"]').click();
  await wait(150);
  const posted = calls('api/verdict');
  ok(posted.length === 1 && posted[0].body.item === 'function:clean_survey' && posted[0].body.verdict === 'correct', `double-click Correct: exactly one POST api/verdict ${JSON.stringify(posted.map(p => p.body))}`);
  ok(/committed abc1234\b/.test(panel()?.textContent || ''), `result shown: "${resultOf('function:clean_survey')}"`);
  ok(calls('api/model', 'GET').length >= 1, 'the new version is fetched after the verdict');
  ok(!cleanNode().classList.contains('qa-todo') && cleanNode().classList.contains('qa-again'), `after the verdict the node's review class changes: ${cleanNode().className}`);

  // R refuses the verdict (409): its message is shown as an error
  server.next409 = 'Cannot record a verdict: the author of target:clean_data is unknown.';
  panelOf('target:clean_data').querySelector('[data-verdict="correct"]').click();
  await wait(100);
  ok(/author of target:clean_data is unknown/.test(resultOf('target:clean_data')) && panelOf('target:clean_data').querySelector('.v-result.err'), `409 shown as an error: "${resultOf('target:clean_data')}"`);

  // saved but not committed: Retry commits (one POST however often it is pressed)
  server.commitFails = 'pre-commit hook failed';
  panelOf('target:clean_data').querySelector('[data-verdict="correct"]').click();
  await wait(120);
  ok(/saved, not committed: pre-commit hook failed/.test(resultOf('target:clean_data')), `not committed: "${resultOf('target:clean_data')}"`);
  const retryBtn = panelOf('target:clean_data')?.querySelector('[data-vretry]');
  ok(retryBtn, 'Retry commit button offered');
  if (retryBtn) { retryBtn.click(); panelOf('target:clean_data')?.querySelector('[data-vretry]')?.click(); }
  await wait(150);
  ok(calls('api/retry').length === nRetry + 2, `Retry: exactly one more POST api/retry (${calls('api/retry').length})`);
  ok(/committed 1 entry/.test(resultOf('target:clean_data')), `retry result: "${resultOf('target:clean_data')}"`);

  // Build mode: the reverse
  click(d.getElementById('mode-build'));
  await wait(30);
  ok(!liveReview() && shown(d.getElementById('btn-add')) && $$('#nodes .port').length > 0, 'Build: add button and ports');
  ok(!$$('[data-verdict]').filter(shown).length, 'Build: no verdict buttons (modal and toolbar)');
  click(d.getElementById('mode-review'));
  await wait(30);
  ok(liveReview() && panel(), 'back to Review: verdict panel again');

  // a comment being typed with markup in it
  const cmt = panel().querySelector('[data-vcmt]');
  cmt.value = XSS; cmt.dispatchEvent(new w.Event('input', { bubbles: true }));

  // can_record false + model_error, picked up by polling; selection, fold state, viewport and modal survive
  click(d.querySelector('#nodes .mpill[data-map="map:model_fit"]'));
  await wait(30);
  click(cleanNode());
  const k0 = d.getElementById('z-val').value;
  Object.assign(server.model.live, { can_record: false, blockers: ['R/import.R', XSS], blocked_reason: 'Commit your changes first.' });
  server.model.model_error = `Error in tar_target(): object x not found ${XSS}`;
  server.model.project = 'survey-refreshed';
  server.model.functions.find(f => f.name === 'clean_survey').qa.history = [{ verdict: 'wrong', reviewer: 'S. Senior', date: '2026-11-20', comment: XSS, current: false }];
  server.bump();
  const nModel = calls('api/model', 'GET').length;
  await wait(2300);
  ok(calls('api/model', 'GET').length === nModel + 1, 'version bump fetches the model once (by polling)');
  ok(/survey-refreshed/.test(d.getElementById('session').textContent), 'the page shows the new model');
  ok(d.querySelector('#nodes .node.sel[data-id="clean_data"]'), 'selection kept after the refresh');
  ok(d.querySelector('#nodes .node[data-id="model_fit_full"]'), 'fold state kept after the refresh (model_fit still unfolded)');
  ok(d.getElementById('z-val').value === k0, 'viewport kept after the refresh');
  const btns = panel() ? [...panel().querySelectorAll('[data-verdict]')] : [];
  ok(btns.length === 3 && btns.every(b => b.disabled), 'can_record false: verdict buttons disabled');
  ok(/Commit your changes first/.test(panel()?.textContent || '') && /R\/import\.R/.test(panel()?.textContent || ''), 'can_record false: reason and blockers listed');
  ok(/object x not found/.test(banners()), 'model_error shown in a banner');
  ok(!d.querySelector('#banners img, #modal img') && !w.__xss, 'markup in model_error, a blocker, a comment and the draft stays text (no img element)');
  ok(panel()?.querySelector('[data-vcmt]')?.value === XSS && /onerror/.test(panel()?.querySelector('.v-block')?.textContent || '') && $$('#m-qa .qa-hist').some(h => /onerror/.test(h.textContent)), 'the markup is shown as text (draft, blocker, history)');
  key('Escape');
  await wait(20);

  // self-review: only from the server's flag; the toolbar ✓ then opens the dialog instead of recording
  ok(!d.querySelector('.v-warn'), 'no self-review warning without the flag');
  Object.assign(server.model.live, { can_record: true, blockers: [], blocked_reason: null });
  server.model.model_error = null;
  server.model.functions.find(f => f.name === 'summarise_region').qa.self_review_if_you_record = true;
  server.bump();
  await nudge();
  ok(!/object x not found/.test(banners()), 'model_error banner gone once R reads the pipeline again');
  click(d.querySelector('#nodes .node[data-id="region_summary"]'));
  const nPost = calls('api/verdict').length;
  d.querySelector('#nodebar [data-verdict="correct"]').click();
  await wait(80);
  ok(calls('api/verdict').length === nPost && !d.getElementById('overlay').hidden, 'toolbar ✓ on a self-review opens the dialog, records nothing');
  const rsPanel = panelOf('function:summarise_region');
  ok(rsPanel && /self-review/.test(rsPanel.querySelector('.v-warn')?.textContent || ''), 'self-review warning from self_review_if_you_record');
  key('Escape');
  await wait(20);

  // Open in RStudio goes through the server; its error is shown
  click(cleanNode());
  d.querySelector('#nodebar [data-act="rstudio"]').click();
  await wait(60);
  const op = calls('api/open');
  ok(op.length === 1 && op[0].body.item === 'function:clean_survey', `POST api/open ${JSON.stringify(op[0] && op[0].body)}`);
  ok(/open R\/clean\.R:3 yourself/.test(d.getElementById('toast-msg').textContent), 'open error shown as a toast');

  // Build: a new model is always applied (writes go to the files, the view has no changes of its own)
  key('Escape');
  click(d.getElementById('mode-build'));
  await wait(20);
  const histRaw = () => d.querySelector('#nodes .node[data-id="hist_raw"]');
  server.model.project = 'survey-v3'; server.bump();
  await nudge();
  ok(/survey-v3/.test(d.getElementById('session').textContent) && !d.querySelector('#banners [data-reload]'), 'Build: the new model is applied, no hold-back banner');
  // Build, dialog open: the refresh is applied, the dialog stays
  server.model.project = 'survey-v3b'; server.bump();
  await openModalOf('hist_raw');
  ok(/Apply writes to your files/.test(d.querySelector('#modal .m-foot').textContent) && !/live connection/.test(d.getElementById('modal').textContent), 'live Build dialog: "Apply writes to your files"');
  await nudge();
  ok(/survey-v3b/.test(d.getElementById('session').textContent) && !d.getElementById('overlay').hidden, 'Build, open dialog: refresh applied, dialog stays');
  key('Escape');
  await wait(20);
  // Build -> Review switches at once (no confirmation panel)
  click(d.getElementById('mode-review'));
  await wait(20);
  ok(liveReview() && !d.getElementById('confirm') && histRaw(), 'Build -> Review switches without a confirmation');

  // R refuses (text/plain 403), then R is gone
  server.refuse = 'Host 127.0.0.1:9999 is not allowed.';
  await nudge();
  ok(/Connection refused by R: Host 127\.0\.0\.1:9999 is not allowed\./.test(banners()), `refused banner: "${banners().trim()}"`);
  server.refuse = null; server.down = true;
  await nudge();
  ok(/Connection to R lost: run pipeworks\(\) again/.test(banners()), 'unreachable server shows the banner');
  server.down = false;
  ok(cleanNode(), 'last good view kept while R is gone');
  await nudge();
  ok(!/Connection/.test(banners()), 'banner gone when R answers again');

  await wait(100);
  ok(liveErrors.length === 0, `live page: no console errors${liveErrors.length ? ':\n' + liveErrors.join('\n') : ''}`);
  w.close();

  // ---------- Live page, Build mode: actions write through api/edit ----------
  console.log('\n# live page: writes');
  const W = {
    model: { ...JSON.parse(JSON.stringify(model)), live: { ...live0, mode: 'build', version: 1, building: false, uncommitted: [] }, model_error: null },
    calls: [], badToken: 0, absolute: 0, down: false, refuse: null, open: { ok: true },
    bump() { this.model.live.version++; },
  };
  const htmlOf = m => html.replace(/(<script id="pipeworks-data" type="application\/json">)[\s\S]*?(<\/script>)/,
    (m0, a, b) => a + JSON.stringify(m).replace(/</g, '\\u003c') + b);
  const wErrors = [];
  const wdom = makeDom(htmlOf(W.model), { url: `http://127.0.0.1:7777/?token=${TOKEN}`, fetch: makeFetch(W) }, wErrors);
  w = wdom.window; d = w.document;
  await wait(100);
  const edits = () => W.calls.filter(c => c.url === 'api/edit' && c.method === 'POST');
  const lastChanges = () => (edits().slice(-1)[0] || { body: { changes: [] } }).body.changes;
  const fnBase = n => model.functions.find(f => f.name === n).base;
  const tBase = n => model.targets.find(t => t.name === n).base;
  const node = id => d.querySelector(`#nodes .node[data-id="${id}"]`);
  const nodeTitle = id => node(id)?.querySelector('.n-title')?.textContent;
  const setField = (sel, v) => { const el = d.querySelector(sel); el.value = v; el.dispatchEvent(new w.Event('input', { bubbles: true })); };
  const apply = async () => { d.querySelector('#modal [data-m="save"]').click(); await wait(60); };
  const toastText = () => d.getElementById('toast-msg').textContent;
  // R finishes the background rebuild: building off, a newer version
  const rebuilt = async mut => { if (mut) mut(W.model); W.model.live.building = false; W.bump(); await nudge(); };
  ok(!liveReview(), 'live page in Build mode (live.mode)');

  // a new title on raw_data's dialog: exactly one set_doc with the model's base, shown at once
  await openModalOf('raw_data');
  setField('#m-title', 'Read the survey export file');
  d.querySelector('#modal [data-m="save"]').click();
  await wait(1);
  ok(nodeTitle('raw_data') === 'Read the survey export file' && node('raw_data').classList.contains('wr'), `optimistic: new title shown at once, box marked .wr (${node('raw_data')?.className})`);
  await wait(60);
  const c1 = lastChanges();
  ok(edits().length === 1 && c1.length === 1 && JSON.stringify(c1[0]) === JSON.stringify({ kind: 'set_doc', item: 'function:read_survey', base: fnBase('read_survey'), fn: 'read_survey', field: 'title', value: 'Read the survey export file' }), `title: one set_doc ${JSON.stringify(c1)}`);
  ok(/^Written to R\/import\.R\./.test(toastText()) && shown(d.getElementById('toast-act')), `toast "${toastText()}" with Undo`);
  ok(!$$('.inp.wr, .txt.wr, .select.wr').length, '.wr only on canvas boxes');
  // the same function again before the rebuilt model: its base is out of date, so nothing is sent
  await openModalOf('raw_data');
  setField('#m-desc', 'Second edit too soon');
  await apply();
  ok(edits().length === 1 && /Still writing the last change/.test(toastText()) && d.getElementById('m-desc')?.value === 'Second edit too soon' && nodeTitle('raw_data') === 'Read the survey export file', `same item before the rebuild: refused, dialog keeps the text ("${toastText()}")`);
  key('Escape');
  await wait(20);
  // the model of the write itself (building) is not applied; the rebuilt one is
  await nudge();
  ok(nodeTitle('raw_data') === 'Read the survey export file', 'a model with building: true keeps the optimistic edit');
  await rebuilt(m => { m.functions.find(f => f.name === 'read_survey').title = 'Read the survey export file'; m.project = 'survey-w3'; });
  ok(/survey-w3/.test(d.getElementById('session').textContent) && W.model.live.version === 3 && nodeTitle('raw_data') === 'Read the survey export file' && !node('raw_data').classList.contains('wr'), 'building: false, version 3: the rebuilt model is applied, mark cleared');

  // Undo posts api/undo with the write id
  click(d.getElementById('btn-undo'));
  await wait(60);
  const un = W.calls.filter(c => c.url === 'api/undo');
  ok(un.length === 1 && JSON.stringify(un[0].body) === JSON.stringify({ write_id: 'w1' }), `undo: POST api/undo ${JSON.stringify(un.map(u => u.body))}`);
  ok(/^Undone: /.test(toastText()), `undo toast: "${toastText()}"`);
  await rebuilt(m => { m.functions.find(f => f.name === 'read_survey').title = model.functions.find(f => f.name === 'read_survey').title; });

  // plugging regions into features (drag): set_call, set_formals, set_doc(param regions), in that order
  const port = d.querySelector('#nodes .port-out[data-port="regions"]'), canvasEl = d.getElementById('canvas');
  const Ev = w.PointerEvent || w.MouseEvent, pev = { bubbles: true, button: 0, clientX: 1, clientY: 1, pointerId: 1 };
  d.elementFromPoint = () => node('features');
  port.dispatchEvent(new Ev('pointerdown', pev));
  canvasEl.dispatchEvent(new Ev('pointerup', pev));
  await wait(60);
  const c2 = lastChanges();
  ok(edits().length === 2 && c2.map(c => c.kind).join() === 'set_call,set_formals,set_doc', `plug: kinds ${c2.map(c => c.kind).join()}`);
  ok(c2[0] && c2[0].target === 'features' && c2[0].item === 'target:features' && c2[0].base === tBase('features') && JSON.stringify(c2[0].args) === JSON.stringify([{ name: 'clean_data', value: 'clean_data', named: false }, { name: 'regions', value: 'regions', named: false }]), `plug: set_call ${JSON.stringify(c2[0])}`);
  ok(c2[1] && c2[1].fn === 'build_features' && c2[1].base === fnBase('build_features') && JSON.stringify(c2[1].formals) === JSON.stringify([{ name: 'clean_data', default: null }, { name: 'regions', default: null }]), `plug: set_formals ${JSON.stringify(c2[1])}`);
  ok(c2[2] && c2[2].field === 'param' && c2[2].param === 'regions' && c2[2].value === 'Regions present after cleaning.' && c2[2].item === 'function:build_features', `plug: set_doc ${JSON.stringify(c2[2])}`);
  await rebuilt();

  // renaming target clean_data: rename_target only, no set_call for its users
  await openModalOf('clean_data');
  setField('#m-name', 'clean_responses');
  await apply();
  const c3 = lastChanges();
  ok(c3.length === 1 && JSON.stringify(c3[0]) === JSON.stringify({ kind: 'rename_target', item: 'target:clean_data', base: tBase('clean_data'), target: 'clean_data', to: 'clean_responses' }), `rename target: ${JSON.stringify(c3)}`);
  await rebuilt();

  // a map variant's function title: one change for function fit_score_model
  click(d.querySelector('#nodes .mpill[data-map="map:model_fit"]'));
  await wait(30);
  await openModalOf('model_fit_full');
  setField('#m-title', 'Fit the score model');
  await apply();
  const c4 = lastChanges();
  ok(c4.length === 1 && c4[0].kind === 'set_doc' && c4[0].fn === 'fit_score_model' && c4[0].item === 'function:fit_score_model' && c4[0].base === fnBase('fit_score_model'), `variant function title: ${JSON.stringify(c4)}`);
  await rebuilt();

  // a variant's target argument goes to its template
  await openModalOf('model_fit_full');
  setField('#m-pattern', 'map(features)');
  await apply();
  const c5 = lastChanges();
  ok(c5.length === 1 && JSON.stringify(c5[0]) === JSON.stringify({ kind: 'set_target_arg', item: 'target:model_fit', base: tBase('model_fit_full'), target: 'model_fit', arg: 'pattern', value: 'map(features)' }), `variant pattern -> template: ${JSON.stringify(c5)}`);
  await rebuilt();

  // R refuses (409): the last model comes back, the message is shown, the dialog keeps the user's text
  const oldTitle = nodeTitle('clean_data');
  W.editReply = { status: 409, body: { error: 'function:clean_survey in R/import.R changed since the page loaded it. The view is refreshed; try again.', item: 'function:clean_survey', file: 'R/import.R' } };
  await openModalOf('clean_data');
  setField('#m-title', 'My unsaved title');
  await apply();
  ok(nodeTitle('clean_data') === oldTitle && !node('clean_data').classList.contains('wr'), `409: previous title back on the canvas ("${nodeTitle('clean_data')}")`);
  ok(/changed since the page loaded it/.test(toastText()), `409: message shown: "${toastText()}"`);
  ok(!d.getElementById('overlay').hidden && d.getElementById('m-title')?.value === 'My unsaved title', '409: dialog stays open with the user\'s text');
  key('Escape');
  await wait(20);

  // one write at a time
  W.delay = 150;
  click(node('hist_raw')); key('Delete');
  await wait(20);
  ok(!node('hist_raw'), 'remove: hist_raw gone at once');
  click(node('hist_clean')); key('Delete');
  await wait(20);
  ok(node('hist_clean') && /Still writing the last change/.test(toastText()), `a second action while writing is refused: "${toastText()}"`);
  await wait(200);
  W.delay = 0;
  const c6 = lastChanges();
  ok(c6.length === 1 && JSON.stringify(c6[0]) === JSON.stringify({ kind: 'remove_target', item: 'target:hist_raw', base: tBase('hist_raw'), target: 'hist_raw' }), `remove: ${JSON.stringify(c6)}`);
  ok(!/unused/.test(toastText()), `shared function still used: no hint ("${toastText()}")`);
  await rebuilt();

  // removing the last target of a function: hint that it is unused
  click(node('channel_counts')); key('Delete');
  await wait(60);
  ok(/count_by_channel\(\) is now unused\./.test(toastText()), `unused hint: "${toastText()}"`);
  await rebuilt();

  // removing a target used downstream: set_call for its users first, then remove_target
  click(node('raw_file')); key('Delete');
  await wait(60);
  const c7 = lastChanges();
  ok(c7.map(c => c.kind).join() === 'set_call,remove_target' && c7[0].target === 'raw_data' && JSON.stringify(c7[0].args) === '[]', `remove used target: ${JSON.stringify(c7)}`);
  await rebuilt();

  // a new target: add_target without item/base
  d.getElementById('btn-add').click();
  await wait(40);
  setField('#m-name', 'extra_step');
  await apply();
  const c8 = lastChanges();
  ok(c8.length === 1 && c8[0].kind === 'add_target' && c8[0].target === 'extra_step' && c8[0].block === 'R/new_target.R' && c8[0].fn && c8[0].fn.name === 'make_extra_step' && c8[0].format === null && c8[0].pattern === null && !('item' in c8[0]) && !('base' in c8[0]), `add target: ${JSON.stringify(c8)}`);
  await rebuilt();

  // a new target's file must stay a plain R/<name>.R: refused in the dialog, nothing sent
  const nEdF = edits().length;
  d.getElementById('btn-add').click();
  await wait(40);
  setField('#m-name', 'outside_step');
  for (const bad of ['R/../outside.R', '_targets.R', 'R/./a.R', 'R\\a.R', 'R//a.R']) {
    setField('#m-file', bad);
    await apply();
    const errBox = d.getElementById('m-err');
    ok(edits().length === nEdF && errBox && !errBox.hidden && /R\/<name>\.R/.test(errBox.textContent) && !d.getElementById('overlay').hidden, `new target file "${bad}": refused in the dialog ("${errBox?.textContent}")`);
    if (!errBox) break;
  }
  key('Escape');
  await wait(20);

  // an item without a base (R could not locate it in the files): refused locally, nothing sent
  await rebuilt(m => { m.functions.find(x => x.name === 'clean_survey').base = null; });
  const nEdB = edits().length, titleB = nodeTitle('clean_data');
  await openModalOf('clean_data');
  setField('#m-title', 'No base here');
  await apply();
  ok(edits().length === nEdB && /function:clean_survey/.test(toastText()) && /RStudio/.test(toastText()) && nodeTitle('clean_data') === titleB, `base null: refused locally ("${toastText()}")`);
  key('Escape');
  await wait(20);
  await rebuilt(m => { m.functions.find(x => x.name === 'clean_survey').base = fnBase('clean_survey'); });

  // ---- review round: variants, numeric maps, open dialog follows the files, hold path ----
  // removing one unfolded variant removes its template: every variant goes, and the toast says so
  click(d.querySelector('#nodes .mpill[data-map="map:area_data+area_hist"]'));
  await wait(30);
  click(node('area_hist_urban')); key('Delete');
  await wait(1);
  ok(!node('area_hist_urban') && !node('area_hist_rural') && node('area_data_urban'), 'remove a variant: all variants of its template go at once');
  await wait(60);
  const c9 = lastChanges();
  ok(c9.length === 1 && JSON.stringify(c9[0]) === JSON.stringify({ kind: 'remove_target', item: 'target:area_hist', base: tBase('area_hist_urban'), target: 'area_hist' }), `remove variant -> template: ${JSON.stringify(c9)}`);
  ok(/Removed area_hist \(2 variants\)\./.test(toastText()) && /area_histogram\(\) is now unused\./.test(toastText()), `variant removal toast: "${toastText()}"`);
  await rebuilt();

  // a variant argument that cannot be mapped back to the template (numeric map values): refused, nothing sent
  await rebuilt(m => { m.targets.find(t => t.name === 'model_fit_base').args[1].value = '1'; m.targets.find(t => t.name === 'model_fit_full').args[1].value = '2'; });
  const nEd = edits().length;
  await openModalOf('model_fit_full');
  const plugSel = d.getElementById('m-plug');
  plugSel.value = 'raw_file'; plugSel.dispatchEvent(new w.Event('change', { bubbles: true }));
  await apply();
  ok(edits().length === nEd && /model_fit_full is a variant of model_fit; change its arguments in RStudio\./.test(toastText()), `numeric map value: refused locally ("${toastText()}")`);
  key('Escape');
  await wait(20);
  await rebuilt(m => { m.targets.find(t => t.name === 'model_fit_base').args[1].value = '"base"'; m.targets.find(t => t.name === 'model_fit_full').args[1].value = '"full"'; });

  // the open dialog follows a file change: untouched fields update, typed text stays, a notice, Apply sends only the edit
  await openModalOf('clean_data');
  setField('#m-desc', 'Typed while RStudio saved');
  await rebuilt(m => { const f = m.functions.find(x => x.name === 'clean_survey'); f.title = 'Clean responses (edited in RStudio)'; f.base = 'base-after-rstudio'; });
  ok(d.getElementById('m-title')?.value === 'Clean responses (edited in RStudio)' && d.getElementById('m-desc')?.value === 'Typed while RStudio saved', `dialog: new title taken, typed description kept ("${d.getElementById('m-title')?.value}")`);
  ok(/function:clean_survey changed in your files since you opened this dialog\. Your edits are kept; untouched fields were updated\./.test(d.getElementById('m-notice')?.textContent || ''), `dialog notice: "${d.getElementById('m-notice')?.textContent}"`);
  await apply();
  const c10 = lastChanges();
  ok(c10.length === 1 && JSON.stringify(c10[0]) === JSON.stringify({ kind: 'set_doc', item: 'function:clean_survey', base: 'base-after-rstudio', fn: 'clean_survey', field: 'description', value: 'Typed while RStudio saved' }), `Apply after the merge: only set_doc(description), new base ${JSON.stringify(c10)}`);
  await rebuilt(m => { m.functions.find(x => x.name === 'clean_survey').description = 'Typed while RStudio saved'; });

  // two params: the user touches one, the files change the other -> Apply sends only the touched one
  await openModalOf('region_summary');
  setField('#modal textarea[data-p="data"]', 'Clean responses, one row per respondent.');
  await rebuilt(m => { const f = m.functions.find(x => x.name === 'summarise_region'); f.params.region = 'A region code (edited in RStudio).'; f.base = 'sr-base-2'; });
  ok(d.querySelector('#modal textarea[data-p="region"]')?.value === 'A region code (edited in RStudio).' && d.querySelector('#modal textarea[data-p="data"]')?.value === 'Clean responses, one row per respondent.', 'dialog: the untouched param takes the file value, the touched one keeps the text');
  await apply();
  const c11 = lastChanges();
  ok(c11.length === 1 && c11[0].kind === 'set_doc' && c11[0].field === 'param' && c11[0].param === 'data' && c11[0].base === 'sr-base-2', `two params: only the touched one is sent ${JSON.stringify(c11)}`);
  await rebuilt();

  // held model (building): its model_error still shows
  await openModalOf('hist_clean');
  setField('#m-title', 'Histogram of clean scores');
  await apply();
  W.model.model_error = 'Error in tar_target(): broken on purpose';
  await nudge();
  ok(nodeTitle('hist_clean') === 'Histogram of clean scores' && /broken on purpose/.test(banners()), 'held model (building): optimistic edit kept, its model_error shown');
  W.model.model_error = null;
  await rebuilt();

  // a variant's target argument: a different variant of the same map is refused, nothing sent
  const drag = (fromId, toId) => {
    d.elementFromPoint = () => node(toId);
    d.querySelector(`#nodes .port-out[data-port="${fromId}"]`).dispatchEvent(new Ev('pointerdown', pev));
    canvasEl.dispatchEvent(new Ev('pointerup', pev));
  };
  const edgeShown = (a, b) => !!d.querySelector(`#edges [data-edge="${a}>${b}"]`);
  const nEd2 = edits().length;
  drag('area_data_urban', 'area_hist_rural');
  await wait(60);
  ok(edits().length === nEd2 && /area_hist_rural is a variant of area_hist; change its arguments in RStudio\./.test(toastText()) && !edgeShown('area_data_urban', 'area_hist_rural') && edgeShown('area_data_urban', 'area_hist_urban'), `other variant into a variant: refused locally ("${toastText()}")`);
  // a plain target into one variant: one set_call for the template, the edge on every variant
  drag('regions', 'area_hist_urban');
  await wait(1);
  ok(edgeShown('regions', 'area_hist_urban') && edgeShown('regions', 'area_hist_rural'), 'plain target into a variant: the edge shown on every variant');
  await wait(60);
  const c12 = lastChanges(), calls12 = c12.filter(c => c.kind === 'set_call');
  ok(calls12.length === 1 && calls12[0].target === 'area_hist' && JSON.stringify(calls12[0].args) === JSON.stringify([{ name: 'data', value: 'area_data', named: false }, { name: 'area', value: 'area', named: false }, { name: 'regions', value: 'regions', named: false }]), `plain target into a variant: one set_call for the template ${JSON.stringify(calls12)}`);
  ok(/Plugged regions into area_hist \(2 variants\)\./.test(toastText()), `plug toast: "${toastText()}"`);
  await rebuilt();

  // a param the user edited but the files deleted is kept, with the notice
  await openModalOf('region_summary');
  setField('#modal textarea[data-p="region"]', 'My region text');
  await rebuilt(m => { const f = m.functions.find(x => x.name === 'summarise_region'); delete f.params.region; f.base = 'sr-base-3'; });
  ok(d.querySelector('#modal textarea[data-p="region"]')?.value === 'My region text' && /function:summarise_region changed in your files/.test(d.getElementById('m-notice')?.textContent || ''), 'dialog: an edited param deleted in the files is kept, notice shown');
  key('Escape');
  await wait(20);
  await rebuilt(m => { m.functions.find(x => x.name === 'summarise_region').params.region = 'A single region code.'; });

  // a factory target's description is never written: read-only on the live page
  await openModalOf('report');
  ok(d.getElementById('m-desc')?.readOnly, 'live: factory description read-only');
  key('Escape');
  await wait(20);

  await wait(100);
  ok(wErrors.length === 0, `write page: no console errors${wErrors.length ? ':\n' + wErrors.join('\n') : ''}`);
  console.log(failed ? `\n${failed} check(s) failed` : '\nall checks passed');
  w.close();
  process.exit(failed ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
