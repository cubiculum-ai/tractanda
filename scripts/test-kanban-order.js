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
assert.deepEqual(clone(context.makeLiveFields({...draft,summary:''},{fields:{...base.fields,body:text('Original')}})),{body:text('')},'Explicit clearing remains distinct from absence.');
context.data.captureCategoryIDs=['project'];
const created=clone(context.makeLiveFields({...draft,title:'New'},null));
assert.deepEqual(Object.keys(created).sort(),['categoryOverrides','subject']);
for(const key of ['priority','urgency','assignee','taskKind','optional','sortOrder','dependencies'])assert(!(key in created));
// Parse the entire rendered inline script as JavaScript, not just extracted helpers.
const script=html.slice(html.indexOf('"use strict";'),html.indexOf('</script>',html.indexOf('"use strict";'))).replace('@@LIVE_CLIENT@@',live).replace('@@LEARNING_CLIENT@@','');
new vm.Script(script);
console.log('Kanban native order, category edits, absent values, no-op, unknown overrides, and script syntax passed.');
