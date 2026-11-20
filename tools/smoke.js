// jsdom smoke test of the built editor (logic only: jsdom has no layout).
//   NODE_PATH=<dir with jsdom> node tools/smoke.js mockup/pipeline-editor.html
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

const file = process.argv[2] || 'mockup/pipeline-editor.html';
const html = fs.readFileSync(file, 'utf8');
const errors = [];
const vc = new VirtualConsole();
vc.on('error', (...a) => errors.push(a.join(' ')));
vc.on('jsdomError', e => errors.push(String(e && (e.stack || e.message) || e)));

const dom = new JSDOM(html, {
  runScripts: 'dangerously', pretendToBeVisual: true, virtualConsole: vc,
  beforeParse(w) {
    w.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
    w.addEventListener('error', e => errors.push(String(e.error && e.error.stack || e.message)));
  },
});
const w = dom.window, d = w.document;
let failed = 0;
const ok = (cond, msg) => { console.log(`${cond ? 'ok  ' : 'FAIL'} ${msg}`); if (!cond) failed++; };
const $$ = s => [...d.querySelectorAll(s)];
const click = el => {
  const opts = { bubbles: true, button: 0, clientX: 1, clientY: 1, pointerId: 1 };
  const Ev = w.PointerEvent || w.MouseEvent;
  el.dispatchEvent(new Ev('pointerdown', opts));
  el.dispatchEvent(new Ev('pointerup', opts));
  el.dispatchEvent(new w.MouseEvent('click', opts));
};
const key = (k, extra = {}) => d.body.dispatchEvent(new w.KeyboardEvent('keydown', { key: k, bubbles: true, ...extra }));
const wait = ms => new Promise(r => setTimeout(r, ms));
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

  await wait(600);
  ok(errors.length === 0, `no console errors${errors.length ? ':\n' + errors.join('\n') : ''}`);
  console.log(failed ? `\n${failed} check(s) failed` : '\nall checks passed');
  w.close();
  process.exit(failed ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
