#!/usr/bin/env node
// Exercise the actual browser functions, including native-order and edit boundaries.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const html=fs.readFileSync(path.join(__dirname,'../Sources/TractandaWeb/Resources/Kanban.html'),'utf8');
const live=fs.readFileSync(path.join(__dirname,'../Sources/TractandaWeb/Resources/LiveClient.js'),'utf8');
const text=value=>({type:'text',value}),clone=value=>JSON.parse(JSON.stringify(value));
const context=vm.createContext({data:{columns:[{id:'ready'},{id:'done'}],filters:[],categoryAxes:[{id:'axis',children:[{id:'high'},{id:'low'}]}]},clone,typedText:text,fieldText:(f,k)=>f[k]?.value||'',byId:()=>null});
vm.runInContext(html.slice(html.indexOf('  function orderedBoardTasks('),html.indexOf('  function render()')),context);
const tasks=[{id:'high',priority:'P9'},{id:'low',priority:'P0'},{id:'unset',order:-100}];
assert.deepEqual(Array.from(context.orderedBoardTasks(tasks),t=>t.id),tasks.map(t=>t.id),'Native category/view order must survive contradictory obsolete fields.');
vm.runInContext(live.slice(live.indexOf('  function makeLiveFields('),live.indexOf('  function retainPendingWrite(')),context);
const base={fields:{itemID:text('item'),subject:text('Keep'),foreign:{type:'integer',value:9}}};
const draft={title:'Keep',summary:'',notes:'',checklist:[],categoryIDs:[],filterCategoryIDs:[],axisCategoryIDs:{axis:[]}};
assert.deepEqual(clone(context.makeLiveFields(draft,base)),{},'No-op must retain absent fields.');
assert.deepEqual(clone(context.makeLiveFields({...draft,title:'Edit'},base)),{subject:text('Edit')});
assert.deepEqual(clone(context.makeLiveFields({...draft,categoryIDs:['ready']},base)),{categoryOverrides:{type:'object',value:{ready:text('include')}}});
const assigned={fields:{...base.fields,body:text('Original'),categoryOverrides:{type:'object',value:{secret:text('exclude'),low:text('include')}}}};
const change={...draft,summary:'Original',axisCategoryIDs:{axis:['high']},originalAxisCategoryIDs:{axis:['low']}};
assert.deepEqual(clone(context.makeLiveFields(change,assigned)),{categoryOverrides:{type:'object',value:{secret:text('exclude'),low:text('exclude'),high:text('include')}}});
assert.deepEqual(clone(context.makeLiveEdit(draft,{fields:{...base.fields,body:text('Original'),workingNotes:text('Notes')}})),{changes:{},unset:['body','workingNotes']},'Clearing displayed text removes its keys.');
assert.deepEqual(clone(context.makeLiveEdit(draft,base)),{changes:{},unset:[]},'Untouched absence is a no-op.');
assert.deepEqual(clone(context.makeLiveEdit(draft,{fields:{...base.fields,body:text(''),workingNotes:{type:'object',value:{unknown:text('keep')}}}})),{changes:{},unset:[]},'Untouched explicit-empty and undisplayed typed values are preserved.');
assert.deepEqual(clone(context.makeLiveEdit({...draft,summary:'New'},base)),{changes:{body:text('New')},unset:[]});
context.data.captureCategoryIDs=['project'];
const created=clone(context.makeLiveFields({...draft,title:'New'},null));
assert.deepEqual(Object.keys(created).sort(),['categoryOverrides','subject']);
for(const key of ['priority','urgency','assignee','taskKind','optional','sortOrder','dependencies'])assert(!(key in created));
// Parse the entire rendered inline script as JavaScript, not just extracted helpers.
const script=html.slice(html.indexOf('"use strict";'),html.indexOf('</script>',html.indexOf('"use strict";'))).replace('@@LIVE_CLIENT@@',live).replace('@@LEARNING_CLIENT@@','');
new vm.Script(script);
console.log('Kanban native order, category edits, absent values, no-op, unknown overrides, and script syntax passed.');

// Use only controls that actually exist in the shipped page. Removed controls
// must not break clearing the old board before an asynchronous project switch.
(async()=>{
  // An unset-only edit must be journaled and sent, not mistaken for no changes.
  let journal=null,sends=0;
  Object.assign(context,{isSaving:false,pendingWrite:null,selectedViewID:'project',crypto:{randomUUID:()=> 'fixture'},
    $:()=>({close:()=>{}}),toast:()=>{},retainPendingWrite:write=>{journal=clone(write);},sendPendingWrite:async()=>{sends++;}});
  vm.runInContext(live.slice(live.indexOf('  async function saveLiveTask('),live.indexOf('  async function sendPendingWrite(')),context);
  await context.saveLiveTask(draft,{fields:{...base.fields,revisionID:text('base-revision'),body:text('Original')}});
  assert.equal(sends,1);
  assert.deepEqual(journal.request.changes,{});
  assert.deepEqual(journal.request.unset,['body']);
  assert.equal(journal.request.expectedRevisionID,'base-revision');
  assert.equal(journal.request.operationID,'web:fixture');
  const controls=new Map(Array.from(html.matchAll(/\bid="([^"]+)"/g),m=>[m[1],{value:'stale',open:false}]));
  const events=[],load=[];
  let navigation;
  const reset=()=>({tasks:[{id:'old'}],title:'Old project',categoryAxes:[{id:'old-axis'}]});
  navigation=vm.createContext({data:reset(),projectBoard:{},selectedViewID:'alpha',viewGeneration:0,
    revisionsByID:new Map([['old',{}]]),dirty:true,pendingWrite:null,isSaving:false,isConnected:true,
    undoStack:[{}],changes:2,$:id=>controls.get(id)||null,currentDate:()=>new Date(0).toISOString(),
    render:()=>events.push(clone(navigation.data)),replaceViewURL:id=>load.push(['url',id]),
    restorePendingWrite:()=>{},updateConnectionState:()=>{},toast:()=>{},
    refreshLiveBoard:async force=>{load.push(['load',navigation.selectedViewID,force]);navigation.data={projectID:navigation.selectedViewID,tasks:[{id:navigation.selectedViewID+'-item'}],columns:[{id:navigation.selectedViewID+'-column'}]};}
  });
  vm.runInContext(live.slice(live.indexOf('  function clearViewData('),live.indexOf('  function restorePendingWrite(')),navigation);
  vm.runInContext(live.slice(live.indexOf('  async function selectProjectView('),live.indexOf('  function makeLiveFields(')),navigation);
  for(const id of ['beta','alpha']) {
    await navigation.selectProjectView(id);
    assert.equal(navigation.data.projectID,id);
    assert.equal(navigation.data.tasks[0].id,id+'-item');
    assert.equal(navigation.data.columns[0].id,id+'-column');
    assert.equal(controls.get('search').value,'');
    assert.equal(controls.get('track-filter').value,'all');
    assert.equal(events.at(-1).tasks.length,0);
    assert.equal(events.at(-1).categoryAxes,undefined);
  }
  assert.equal(navigation.viewGeneration,2);
  assert.deepEqual(load,[['url','beta'],['load','beta',true],['url','alpha'],['load','alpha',true]]);
  assert.equal(navigation.revisionsByID.size,0);
  controls.get('task-dialog').open=true;
  await navigation.selectProjectView('beta');
  assert.equal(navigation.selectedViewID,'alpha','An open draft still blocks switching.');
  console.log('Project switching in both directions clears old board state and loads the new selection.');
})().catch(error=>{console.error(error);process.exitCode=1;});
