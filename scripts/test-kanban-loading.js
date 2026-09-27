#!/usr/bin/env node
// Exercise the shipped board loader against a deterministic native API fixture.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const live=fs.readFileSync('Sources/TractandaWeb/Resources/LiveClient.js','utf8');
const text=value=>({type:'text',value}), ref=itemID=>({type:'reference',value:{itemID}});
const refs=ids=>({type:'list',value:ids.map(ref)});
function category(id,parents=[],extras={}) {return {fields:{itemID:text(id),revisionID:text(id+'-revision'),subject:text(id),selection:text('TRUEPREDICATE'),categoryParents:refs(parents),requestIdentity:text('large replay receipt'),...extras}};}
const categories=[category('projects'),category('project',['projects'],{filterCategories:refs(['filter'])}),category('status'),category('ready',['status']),category('done',['status']),category('filter')];
const task={fields:{itemID:text('task'),revisionID:text('task-revision'),subject:text('Task'),modifiedAt:{type:'date',value:'2026-09-26T00:00:00Z'},body:text('Complete body'),workingNotes:text('Keep these notes'),requestIdentity:text('large replay receipt'),foreign:{type:'integer',value:42},categoryOverrides:{type:'object',value:{unrelated:text('exclude')}}}};
const records=new Map([...categories,task].map(r=>[r.fields.itemID.value,r]));
function fixture() {
 let state='one';const calls=[],batches=[];
 const nativeCall=async(method,args={})=>{
  calls.push({method,args});
  if(method==='TractandaStore/info')return {state};
  if(method==='TractandaItem/query') {
   const ids=args.expression?categories.map(c=>c.fields.itemID.value):args.categoryPath.at(-1)==='done'?[]:['task'];
   return {ids:ids.slice(args.position,args.position+args.limit),position:args.position,total:ids.length,queryState:state};
  }
  assert.equal(method,'TractandaItem/get');
  const list=args.ids.map(id=>{
   const original=records.get(id);assert.ok(original);
   const r=structuredClone(original);
   if(args.properties)r.fields=Object.fromEntries(Object.entries(r.fields).filter(([k])=>args.properties.includes(k)||['itemID','revisionID','classID','schemaVersion','createdAt','modifiedAt'].includes(k)));
   if(args.projection==='content')delete r.fields.requestIdentity;
   return r;
  });
  return {list,notFound:[],state};
 };
 const context=vm.createContext({projectBoard:{projectRootID:'projects',statusRootID:'status'},selectedViewID:'project',currentDate:()=> '2026-09-26T12:00:00Z',selectionIsCurrent:()=>true,fieldText:(f,k)=>f[k]?.type==='text'?f[k].value:'',apiError:(code,message)=>Object.assign(new Error(message),{code}),nativeCall,nativeCalls:async entries=>{
  assert.ok(entries.length<=8);
  batches.push(entries.length);
  const results=[];
  for(const [method,args] of entries) {
   const resolved=args['#ids']?{...args,ids:results[0].ids}:args;
   delete resolved['#ids'];
   results.push(await nativeCall(method,resolved));
  }
  return results;
 }});
 vm.runInContext(live.slice(live.indexOf('  function plain('),live.indexOf('  async function refreshProjectViews(')),context);
 return {context,calls,batches,changeState:()=>{state='two';}};
}
function savedFixture() {
 const calls=[],batches=[],view={fields:{itemID:text('view'),revisionID:text('view-revision'),subject:text('Saved board'),
  viewDefinition:{type:'object',value:{presentation:{type:'object',value:{sections:refs(['ready','done'])}}}},
  filterCategories:refs(['filter'])}};
 const records=new Map([...categories,task,view].map(record=>[record.fields.itemID.value,record]));
 const nativeCall=async(method,args={})=>{
  calls.push({method,args});
  if(method==='TractandaStore/info')return {state:'one'};
  if(method==='TractandaItem/query') {
   const ids=args.sectionID==='done'?[]:['task'];
   return {ids:ids.slice(args.position,args.position+args.limit),position:args.position,total:ids.length,queryState:'one'};
  }
  assert.equal(method,'TractandaItem/get');
  return {list:args.ids.map(id=>structuredClone(records.get(id))),notFound:[],state:'one'};
 };
 const context=vm.createContext({projectBoard:null,selectedViewID:'view',currentDate:()=> '2026-09-26T12:00:00Z',selectionIsCurrent:()=>true,fieldText:(f,k)=>f[k]?.type==='text'?f[k].value:'',apiError:(code,message)=>Object.assign(new Error(message),{code}),nativeCall,nativeCalls:async entries=>{
  batches.push(entries.length);
  const results=[];
  for(const [method,args] of entries) {
   const resolved=args['#ids']?{...args,ids:results[0].ids}:args;
   delete resolved['#ids'];
   results.push(await nativeCall(method,resolved));
  }
  return results;
 }});
 vm.runInContext(live.slice(live.indexOf('  function plain('),live.indexOf('  async function refreshProjectViews(')),context);
 return {context,calls,batches};
}
(async()=>{
 const protocolCalls=[];
 const protocol=vm.createContext({nativeCapability:'test-capability',accessToken:'token',AbortSignal,apiError:(code,message)=>Object.assign(new Error(message),{code}),showServerVersion:()=>{},forgetAccessToken:()=>{},showSignIn:()=>{},pendingWrite:null,
  fetch:async(_url,options)=>{
   const body=JSON.parse(options.body);protocolCalls.push(body.methodCalls);
   return {ok:true,json:async()=>({methodResponses:body.methodCalls.map(([method,_args,id])=>[method,{id},id])})};
  }});
 vm.runInContext(live.slice(live.indexOf('  async function nativeCalls('),live.indexOf('  function plain(')),protocol);
 const paired=await protocol.nativeCalls([['TractandaStore/info',{}],['TractandaItem/query',{position:0}]]);
 assert.equal(paired.length,2);
 assert.deepEqual(protocolCalls[0].map(call=>call[2]),['web-0','web-1'],'Each call has a unique matching ID.');
 await assert.rejects(protocol.nativeCalls(Array.from({length:9},()=>['TractandaStore/info',{}])),error=>error.code==='invalidRequest');
 const groupedBatches=[];
 const grouped=vm.createContext({currentDate:()=> '2026-09-26T12:00:00Z',apiError:(code,message)=>Object.assign(new Error(message),{code}),nativeCalls:async entries=>{
  groupedBatches.push(entries.length);
  return entries.map(([_method,args])=>{
   const total=args.categoryPath[0]==='long'?70:1;
   return {ids:Array.from({length:Math.min(64,total-args.position)},(_,index)=>args.categoryPath[0]+'-'+(args.position+index)),total,queryState:'one'};
  });
 }});
 vm.runInContext(live.slice(live.indexOf('  async function queryIDGroups('),live.indexOf('  async function queryRevisions(')),grouped);
 const groups=await grouped.queryIDGroups(['long',...Array.from({length:9},(_,index)=>'short-'+index)].map(id=>({categoryPath:[id]})),'one');
 assert.equal(groups[0].length,70);
 assert.deepEqual(groupedBatches,[8,3],'Large membership sets page in a later bounded envelope.');
 const pageLimits=[];
 const paged=vm.createContext({nativeCalls:async entries=>{
  const limit=entries[0][1].limit;pageLimits.push(limit);
  if(limit>32)throw Object.assign(new Error('large'),{code:'responseTooLarge'});
 return [{ids:['item'],total:1,queryState:'one'},{list:[task],notFound:[],state:'one'}];
 }});
vm.runInContext(live.slice(live.indexOf('  async function queryPageWithRevisions('),live.indexOf('  async function queryRevisions(')),paged);
await paged.queryPageWithRevisions({viewID:'view'},0,{projection:'content'});
assert.deepEqual(pageLimits,[64,32],'An oversized combined response retries a smaller read-only page.');
const cursorArguments=[];
let cursorAttempt=0;
const cursorPaged=vm.createContext({nativeCalls:async entries=>{
  const args=entries[0][1];cursorArguments.push(args);cursorAttempt++;
  if(cursorAttempt===1)throw Object.assign(new Error('large'),{code:'responseTooLarge'});
  return [{ids:['item'],position:8,total:20,queryState:'one',nextCursor:'next-token'},{list:[task],notFound:[],state:'one'}];
}});
vm.runInContext(live.slice(live.indexOf('  async function queryPageWithRevisions('),live.indexOf('  async function queryRevisions(')),cursorPaged);
const cursorPage=await cursorPaged.queryPageWithRevisions({expression:'classID == "Item"'},8,{projection:'content'},'opaque-token');
assert.equal(cursorPage[0].nextCursor,'next-token');
assert.deepEqual(cursorArguments.map(args=>args.limit),[64,32]);
assert.ok(cursorArguments.every(args=>args.cursor==='opaque-token'&&args.position===undefined),
  'An adaptive retry preserves the opaque cursor and omits random-access position.');
const continuationCalls=[];
const safeContinuation=vm.createContext({
 currentDate:()=> '2026-09-26T12:00:00Z',
 apiError:(code,message)=>Object.assign(new Error(message),{code}),
 queryPageWithRevisions:async(_args,position,_projection,cursor)=>{
  continuationCalls.push({position,cursor});
  if(cursor)throw Object.assign(new Error('expired'),{code:'invalidCursor'});
  const ids=[position===0?'first':'second'];
  return [{ids,position,total:2,queryState:'same-state',nextCursor:position===0?'next':null},
    {list:ids.map(itemID=>({itemID})),state:'same-state',notFound:[]}];
 }
});
vm.runInContext(live.slice(live.indexOf('  async function queryRevisions('),live.indexOf('  async function projectGraph(')),safeContinuation);
const safelyLoaded=await safeContinuation.queryRevisions({expression:'classID == "Item"'},'same-state',null);
assert.equal(safelyLoaded.length,2);
assert.deepEqual(continuationCalls,[
 {position:0,cursor:null},{position:1,cursor:'next'},{position:1,cursor:null}
],'An invalid cursor retries at the same absolute position and still uses the caller state guard.');
const f=fixture(),snapshot={};
 const projects=await f.context.discoverProjectViews('project',0,snapshot);
 assert.deepEqual(Array.from(projects,p=>p.id),['projects','project']);
 const loaded=await f.context.readLiveBoard('project',snapshot);
 assert.equal(loaded.data.tasks.length,1);
 assert.deepEqual(Array.from(loaded.data.tasks[0].categoryIDs),['ready']);
 assert.deepEqual(Array.from(loaded.data.tasks[0].filterCategoryIDs),['filter']);
 assert.equal(loaded.data.tasks[0].summary,'Complete body');
 assert.equal(loaded.revisions.get('task').fields.foreign.value,42,'Content projection preserves unknown fields for the guarded editor.');
 assert.equal(loaded.revisions.get('task').fields.categoryOverrides.value.unrelated.value,'exclude');
 assert.equal(loaded.revisions.get('task').fields.requestIdentity,undefined);
 assert.equal(f.calls.filter(c=>c.args.expression).length,1,'Reuse the checked category graph within one refresh.');
 assert.deepEqual(f.batches,[2,2,3],'Query and get share a request; membership and filter lookups share another.');
 const gets=f.calls.filter(c=>c.method==='TractandaItem/get');
 assert.equal(gets.length,2,'Fetch categories and card content once; membership lookups need IDs only.');
 assert.ok(gets[0].args.properties.includes('viewDefinition'));
 assert.equal(gets[1].args.projection,'content');
 const changed=fixture(),oldSnapshot={};
 await changed.context.discoverProjectViews('project',0,oldSnapshot);
 changed.changeState();
 const refreshed=await changed.context.readLiveBoard('project',oldSnapshot);
 assert.equal(refreshed.data.serverState,'two');
 assert.equal(changed.calls.filter(c=>c.args.expression).length,2,'A changed generation discards the earlier category graph.');
 const separate={};
 await changed.context.discoverProjectViews('project',1,separate);
 assert.equal(changed.calls.filter(c=>c.args.expression).length,3,'A later refresh/login does not reuse a global category cache.');
 const saved=savedFixture(),savedBoard=await saved.context.readLiveBoard('view');
 assert.equal(savedBoard.data.tasks.length,1);
 assert.deepEqual(Array.from(savedBoard.data.tasks[0].categoryIDs),['ready']);
 assert.deepEqual(saved.batches,[2,3],'Saved view query/get and section/filter membership calls are batched.');
 console.log('Board loading: content preserved, ID-only memberships, one scoped graph, and generation invalidation passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
