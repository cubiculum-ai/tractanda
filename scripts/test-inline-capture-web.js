#!/usr/bin/env node
// Exercise the shipped web capture workflow using a mocked authenticated nativeCall.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const live = fs.readFileSync('Sources/TractandaWeb/Resources/LiveClient.js', 'utf8');
const html = fs.readFileSync('Sources/TractandaWeb/Resources/Kanban.html', 'utf8');
const scriptStart = html.indexOf('"use strict";');
const scriptEnd = html.indexOf('</script>', scriptStart);
assert.ok(scriptStart >= 0 && scriptEnd > scriptStart, 'the shipped Kanban script should exist');
new vm.Script(html.slice(scriptStart, scriptEnd).replace('@@LIVE_CLIENT@@', live).replace('@@LEARNING_CLIENT@@', ''));
const start = live.indexOf('  function makeLiveFields(');
const end = live.indexOf('  function appendRevisionHistory(', start);
assert.ok(start >= 0 && end > start, 'capture and save workflow functions should remain together');

function node() {
  return {
    hidden: false, disabled: false, checked: false, open: true, textContent: '', dataset: {}, children: [],
    replaceChildren(...children) { this.children = children; this.textContent = ''; },
    append(child) { this.children.push(child); },
    close() { this.open = false; }, scrollIntoView() {},
  };
}

function fixture() {
  const ids = ['interpret-hashtags', 'capture-preview', 'preview-capture', 'task-dialog', 'dialog-error', 'connection-message'];
  const elements = Object.fromEntries(ids.map(id => [id, node()]));
  elements['interpret-hashtags'].checked = true;
  const calls = [], retained = [], storage = new Map();
  let planResponse;
  let failNextCommit = false;
  const ctx = vm.createContext({
    configuration: {}, data: {columns: [{id: 'cat-1', name: 'Research'}], filters: [], categoryAxes: []},
    columns: () => [{id: 'cat-1', name: 'Research'}], filters: () => [],
    $: id => elements[id] || (elements[id] = node()),
    element: (tag, attrs = {}, children = []) => ({tag, attrs, children, text: attrs.text || ''}),
    clone: value => JSON.parse(JSON.stringify(value)),
    crypto: {randomUUID: () => 'fixed-operation-id'},
    fieldText: (fields, key) => fields?.[key]?.type === 'text' ? fields[key].value : '',
    typedText: value => ({type: 'text', value}),
    isLive: true, isSaving: false, isRefreshing: false, isConnected: true,
    pendingWrite: null, revisionsByID: new Map(), selectedViewID: 'view-1', viewGeneration: 1,
    editingBase: null, isNew: true, capturePlan: null, capturePreviewGeneration: 0,
    capturePreparing: false, dirty: false, learningCategoryID: '', learningNotice: '',
    sessionStorage: {setItem: (k, v) => storage.set(k, v), removeItem: k => storage.delete(k)},
    pendingStorageKey: id => 'pending.' + id,
    currentDate: () => '2026-10-13T09:00:00Z', selectionIsCurrent: () => true,
    makeLiveEdit: candidate => ({changes: {subject: {type: 'text', value: candidate.title}, body: {type: 'text', value: candidate.summary}}, unset: []}),
    readLiveDraftFromForm: () => ({id: 'new-id', title: 'Test', summary: '#Tomorrow', notes: '', checklist: [], categoryIDs: [], filterCategoryIDs: [], axisCategoryIDs: {}}),
    completionError: () => null, updateConnectionState: () => {}, refreshLiveBoard: async () => false,
    toast: () => {},
    nativeCall: async (method, args) => {
      calls.push({method, args});
      if (method === 'TractandaItem/prepareCapture') return planResponse;
      if (method === 'TractandaItem/commitCapture' && failNextCommit) {
        failNextCommit = false;
        throw Object.assign(new Error('response interrupted'), {code: 'connectionLost'});
      }
      return {revision: {fields: {revisionID: 'rev-1'}}, indexReady: true};
    },
    setPlan: value => { planResponse = value; },
    failNextCommit: () => { failNextCommit = true; },
    calls, retained, storage, elements,
  });
  vm.runInContext(live.slice(start, end), ctx);
  return ctx;
}

(async () => {
  const ctx = fixture();
  const validPlan = {
    request: {action: 'create', changes: {body: {type: 'text', value: '#Tomorrow'}}, unset: [], operationID: 'fixed-operation-id', classID: 'Item'},
    evaluatedAt: '2026-10-13T09:00:00Z',
    commitRequest: {action: 'create', changes: {body: {type: 'text', value: '#Tomorrow'}, when: {type: 'text', value: '2026-10-14'}}, unset: [], operationID: 'fixed-operation-id', classID: 'Item'},
    categoryRevisionIDs: {'cat-1': 'cat-rev'},
    mentions: [{token: '#Tomorrow', categoryID: 'cat-1', dateProperty: 'when', dateValue: '2026-10-14'}], issues: [],
  };
  ctx.setPlan(validPlan);
  await ctx.previewLiveCapture();
  assert.equal(ctx.calls[0].method, 'TractandaItem/prepareCapture');
  assert.equal('at' in ctx.calls[0].args, false, 'the server supplies the capture instant');
  assert.equal(ctx.calls[0].args.request.changes.body.value, '#Tomorrow', 'hashtags remain in the body');
  assert.equal(ctx.elements['capture-preview'].children[0].text, '#Tomorrow → Research · when = 2026-10-14');
  assert.equal(ctx.captureCanCommit(validPlan), true);

  const reusedPlan = {...validPlan, mentions: [{token: '#Tomorrow', categoryID: 'cat-1', reusedBinding: true, dateProperty: 'when', dateValue: '2026-10-12'}]};
  ctx.renderCapturePreview(reusedPlan);
  assert.equal(ctx.elements['capture-preview'].children[0].text, '#Tomorrow → Research · Already captured; date unchanged', 'historical date provenance must not appear as a proposed edit');

  const rejectedPlan = {...validPlan, issues: [{token: '#Tomorrow', code: 'excluded', message: 'An explicit exclusion is authoritative.'}]};
  assert.equal(ctx.captureCanCommit(rejectedPlan), false, 'server capture issues block the atomic save');

  // An edit during an in-flight preview invalidates its eventual result.
  let release;
  ctx.nativeCall = async (method, args) => method === 'TractandaItem/prepareCapture'
    ? await new Promise(resolve => { release = () => resolve(validPlan); }) : null;
  const pendingPreview = ctx.previewLiveCapture();
  ctx.invalidateCapturePreview();
  release();
  await pendingPreview;
  assert.equal(ctx.capturePlan, null, 'cancel/edit cannot restore a stale prepared preview');

  // The exact plan survives an uncertain commit and is retried unchanged.
  ctx.nativeCall = async (method, args) => {
    ctx.calls.push({method, args});
    if (method === 'TractandaItem/commitCapture' && ctx._failOnce) { ctx._failOnce = false; throw Object.assign(new Error('uncertain'), {code: 'connectionLost'}); }
    return {revision: {fields: {revisionID: 'rev-1'}}, indexReady: true};
  };
  ctx._failOnce = true;
  const candidate = ctx.readLiveDraftFromForm();
  await ctx.saveLiveTask(candidate, null, validPlan);
  const retainedPlan = ctx.pendingWrite.request;
  assert.equal(ctx.pendingWrite.method, 'TractandaItem/commitCapture');
  assert.deepEqual(JSON.parse(JSON.stringify(retainedPlan)), validPlan);
  await ctx.sendPendingWrite();
  const captureCalls = ctx.calls.filter(call => call.method === 'TractandaItem/commitCapture');
  assert.equal(captureCalls.length, 2);
  assert.equal(captureCalls[0].args, captureCalls[1].args, 'retry reuses the identical frozen plan object');

  // The non-opt-in save path remains the existing ordinary commit.
  ctx.pendingWrite = null;
  ctx.calls.length = 0;
  await ctx.saveLiveTask(candidate, null, null);
  assert.equal(ctx.calls[0].method, 'TractandaItem/commit');
  assert.equal(ctx.calls[0].args.changes.body.value, '#Tomorrow');
  assert.equal('when' in ctx.calls[0].args.changes, false, 'ordinary save does not create configured dates');
  assert.match(html, /if\(useCapture&&!captureCanCommit\(capturePlan\)\)/, 'the form requires a valid explicit preview');
  assert.match(live, /\['TractandaItem\/commit','TractandaItem\/commitCapture'/, 'the retry journal recognizes frozen capture plans');
  console.log('Web capture preview, ambiguity/exclusion blocking, invalidation, frozen-plan retry, and ordinary-save path passed.');
})().catch(error => { console.error(error); process.exitCode = 1; });
