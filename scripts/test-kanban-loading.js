#!/usr/bin/env node
// Exercise the shipped board loader against a deterministic native API fixture.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const live=fs.readFileSync('Sources/TractandaWeb/Resources/LiveClient.js','utf8');
const text=value=>({type:'text',value}), ref=itemID=>({type:'reference',value:{itemID}});
const refs=ids=>({type:'list',value:ids.map(ref)});
function category(id,parents=[],extras={}) {return {id,revisionId:id+'-revision',resolution:{itemID:id,status:'ready'},fields:{itemID:text(id),revisionID:text(id+'-revision'),subject:text(id),selection:text('TRUEPREDICATE'),categoryParents:refs(parents),requestIdentity:text('large replay receipt'),...extras}};}
const categories=[category('projects'),category('project',['projects'],{filterCategories:refs(['filter'])}),category('status'),category('ready',['status']),category('done',['status']),category('filter')];
const task={id:'task',revisionId:'task-revision',resolution:{itemID:'task',status:'ready'},fields:{itemID:text('task'),revisionID:text('task-revision'),subject:text('Task'),modifiedAt:{type:'date',value:'2026-09-26T00:00:00Z'},body:text('Complete body'),workingNotes:text('Keep these notes'),requestIdentity:text('large replay receipt'),foreign:{type:'integer',value:'42'},categoryOverrides:{type:'object',value:{unrelated:text('exclude')}}}};
const taskB={id:'taskB',revisionId:'taskB-revision',resolution:{itemID:'taskB',status:'ready'},fields:{...structuredClone(task.fields),itemID:text('taskB'),revisionID:text('taskB-revision'),subject:text('Task B')}};
const records=new Map([...categories,task].map(r=>[r.fields.itemID.value,r]));
function fixture(options={}) {
 if(options.multipleTasks)records.set('taskB',taskB);
 let state='one';const calls=[],batches=[];
 const nativeCall=async(method,args={})=>{
  calls.push({method,args});
  if(method==='TractandaStore/info')return {state};
  if(method==='TractandaItem/query') {
   const ids=args.filter.expression?categories.map(c=>c.fields.itemID.value):args.filter.categoryPath.at(-1)==='done'?[]:options.conflictsAvailable?[]:options.multipleTasks?['task','taskB']:['task'];
   return {ids:ids.slice(args.position,args.position+args.limit),position:args.position,total:ids.length,queryState:state,conflictsAvailable:!!options.conflictsAvailable};
  }
  assert.ok(['TractandaItem/get','TractandaItem/getBounded'].includes(method));
  const list=args.ids.filter(id=>!(options.unresolvedTask&&id==='task')&&!(options.remaining||[]).includes(id)&&!(options.oversized||[]).includes(id)).map(id=>{
   const original=records.get(id);assert.ok(original);
   const r=structuredClone(original);
   if(args.fieldProperties)r.fields=Object.fromEntries(Object.entries(r.fields).filter(([k])=>args.fieldProperties.includes(k)||['itemID','revisionID','classID','schemaVersion','createdAt','modifiedAt'].includes(k)));
   if(args.projection==='content')delete r.fields.requestIdentity;
   return r;
  });
  if(options.unresolvedTask&&args.ids.includes('task'))list.push({id:'task',revisionId:null,formatVersion:null,fields:null,resolution:{itemID:'task',status:'conflicted',stateToken:'token'}});
  return {list,notFound:[],remainingIDs:(options.remaining||[]).filter(id=>args.ids.includes(id)),oversizedIDs:(options.oversized||[]).filter(id=>args.ids.includes(id)),state};
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
function savedFixture(options={}) {
 const calls=[],batches=[],view={id:'view',resolution:{itemID:'view',status:'ready'},fields:{itemID:text('view'),revisionID:text('view-revision'),subject:text('Saved board'),
  viewDefinition:{type:'object',value:{presentation:{type:'object',value:{sections:refs(['ready','done'])}}}},
  filterCategories:refs(['filter'])}};
 const records=new Map([...categories,task,view].map(record=>[record.fields.itemID.value,record]));
 const nativeCall=async(method,args={})=>{
  calls.push({method,args});
  if(method==='TractandaStore/info')return {state:'one'};
  if(method==='TractandaItem/query') {
   const ids=args.filter.sectionID==='done'?[]:['task'];
   return {ids:ids.slice(args.position,args.position+args.limit),position:args.position,total:ids.length,queryState:'one'};
  }
  assert.ok(['TractandaItem/get','TractandaItem/getBounded'].includes(method));
  const list=args.ids.filter(id=>!(options.unresolved||[]).includes(id)&&!(options.remaining||[]).includes(id)&&!(options.oversized||[]).includes(id)&&!(options.missing||[]).includes(id)).map(id=>structuredClone(records.get(id)));
  for(const itemID of options.unresolved||[])if(args.ids.includes(itemID))list.push({id:itemID,revisionId:null,formatVersion:null,fields:null,resolution:{itemID,status:'conflicted',stateToken:'token'}});
  return {list,notFound:(options.missing||[]).filter(id=>args.ids.includes(id)),remainingIDs:(options.remaining||[]).filter(id=>args.ids.includes(id)),oversizedIDs:(options.oversized||[]).filter(id=>args.ids.includes(id)),state:'one'};
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
   const body=JSON.parse(options.body);
   if(body.methodCalls[0][0]==='TractandaSession/get')return {ok:true,json:async()=>({methodResponses:[['TractandaSession/get',{profile:'tractanda.local-session.v1',state:'metadata',primaryAccounts:{'test-capability':'account'},accounts:{account:{accountCapabilities:{'test-capability':{}}}}},'web-0']]})};
   protocolCalls.push(body.methodCalls);
   return {ok:true,json:async()=>({methodResponses:body.methodCalls.map(([method,_args,id])=>[method,{id,accountId:_args.accountId},id])})};
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
   const total=args.filter.categoryPath[0]==='long'?70:1;
   return {ids:Array.from({length:Math.min(64,total-args.position)},(_,index)=>args.filter.categoryPath[0]+'-'+(args.position+index)),total,queryState:'one'};
  });
 }});
 vm.runInContext(live.slice(live.indexOf('  function queryArguments('),live.indexOf('  async function queryRevisions(')),grouped);
 const groups=await grouped.queryIDGroups(['long',...Array.from({length:9},(_,index)=>'short-'+index)].map(id=>({categoryPath:[id]})),'one');
 assert.equal(groups[0].length,70);
 assert.deepEqual(groupedBatches,[8,3],'Large membership sets page in a later bounded envelope.');
 const pageLimits=[];
 const paged=vm.createContext({nativeCalls:async entries=>{
  const limit=entries[0][1].limit;pageLimits.push(limit);
  if(limit>32)throw Object.assign(new Error('large'),{code:'responseTooLarge'});
 return [{ids:['item'],position:0,total:1,queryState:'one'},{list:[task],notFound:[],state:'one'}];
 }});
vm.runInContext(live.slice(live.indexOf('  function queryArguments('),live.indexOf('  async function queryRevisions(')),paged);
await paged.queryPageWithRevisions({viewID:'view'},0,{projection:'content'});
assert.deepEqual(pageLimits,[64,32],'An oversized combined response retries a smaller read-only page.');
const cursorArguments=[];
let cursorAttempt=0;
const cursorPaged=vm.createContext({nativeCalls:async entries=>{
  const args=entries[0][1];cursorArguments.push(args);cursorAttempt++;
  if(cursorAttempt===1)throw Object.assign(new Error('large'),{code:'responseTooLarge'});
  return [{ids:['item'],position:8,total:20,queryState:'one',nextCursor:'next-token'},{list:[task],notFound:[],state:'one'}];
}});
vm.runInContext(live.slice(live.indexOf('  function queryArguments('),live.indexOf('  async function queryRevisions(')),cursorPaged);
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
    {list:ids.map(itemID=>({id:itemID,resolution:{status:'ready'}})),state:'same-state',notFound:[]}];
 }
});
vm.runInContext(live.slice(live.indexOf('  function queryArguments('),live.indexOf('  async function queryIDGroups('))+live.slice(live.indexOf('  async function queryRevisions('),live.indexOf('  async function projectGraph(')),safeContinuation);
const safelyLoaded=await safeContinuation.queryRevisions({expression:'classID == "Item"'},'same-state',null);
assert.equal(safelyLoaded.revisions.length,2);
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
 assert.equal(loaded.revisions.get('task').fields.foreign.value,'42','Content projection preserves unknown fields for the guarded editor.');
 assert.equal(loaded.revisions.get('task').fields.categoryOverrides.value.unrelated.value,'exclude');
 assert.equal(loaded.revisions.get('task').fields.requestIdentity,undefined);
 assert.equal(f.calls.filter(c=>c.args.filter?.expression).length,1,'Reuse the checked category graph within one refresh.');
 assert.deepEqual(f.batches,[2,2,3],'Query and get share a request; membership and filter lookups share another.');
 const gets=f.calls.filter(c=>c.method==='TractandaItem/getBounded');
 assert.equal(gets.length,2,'Fetch categories and card content once; membership lookups need IDs only.');
 assert.ok(gets[0].args.fieldProperties.includes('viewDefinition'));
 assert.equal(gets[1].args.projection,'content');
 const partial=fixture({unresolvedTask:true}),partialSnapshot={};
 await partial.context.discoverProjectViews('project',0,partialSnapshot);
 const partialBoard=await partial.context.readLiveBoard('project',partialSnapshot);
 assert.equal(partialBoard.data.tasks.length,0);
 assert.equal(partialBoard.projectionNotice,true,'An unresolved card is surfaced as incomplete projection state.');
 const mixed=fixture({multipleTasks:true,unresolvedTask:true}),mixedSnapshot={};
 await mixed.context.discoverProjectViews('project',0,mixedSnapshot);
 const mixedBoard=await mixed.context.readLiveBoard('project',mixedSnapshot);
 assert.deepEqual(Array.from(mixedBoard.data.tasks,t=>t.id),['taskB'],'Readable rows survive beside an unresolved ID.');
 assert.equal(mixedBoard.projectionNotice,true);
 const conflictedEmpty=fixture({conflictsAvailable:true}),conflictedSnapshot={};
 await conflictedEmpty.context.discoverProjectViews('project',0,conflictedSnapshot);
 const conflictedBoard=await conflictedEmpty.context.readLiveBoard('project',conflictedSnapshot);
 assert.equal(conflictedBoard.data.tasks.length,0);
 assert.equal(conflictedBoard.projectionNotice,true,'Global conflict availability remains visible for an empty page.');
 const unhydrated=fixture({multipleTasks:true,remaining:['taskB']}),unhydratedSnapshot={};
 await unhydrated.context.discoverProjectViews('project',0,unhydratedSnapshot);
 const unhydratedBoard=await unhydrated.context.readLiveBoard('project',unhydratedSnapshot);
 assert.deepEqual(Array.from(unhydratedBoard.data.tasks,t=>t.id),['task']);
 assert.deepEqual(Array.from(unhydratedBoard.unhydratedIDs),['taskB']);
 assert.equal(unhydratedBoard.projectionNotice,true);
 const oversized=fixture({multipleTasks:true,oversized:['taskB']}),oversizedSnapshot={};
 await oversized.context.discoverProjectViews('project',0,oversizedSnapshot);
 const oversizedBoard=await oversized.context.readLiveBoard('project',oversizedSnapshot);
 assert.deepEqual(Array.from(oversizedBoard.unhydratedIDs),['taskB']);
 assert.equal(oversizedBoard.projectionNotice,true);
 const changed=fixture(),oldSnapshot={};
 await changed.context.discoverProjectViews('project',0,oldSnapshot);
 changed.changeState();
 const refreshed=await changed.context.readLiveBoard('project',oldSnapshot);
 assert.equal(refreshed.data.serverState,'two');
 assert.equal(changed.calls.filter(c=>c.args.filter?.expression).length,2,'A changed generation discards the earlier category graph.');
 const separate={};
 await changed.context.discoverProjectViews('project',1,separate);
 assert.equal(changed.calls.filter(c=>c.args.filter?.expression).length,3,'A later refresh/login does not reuse a global category cache.');
 const saved=savedFixture(),savedBoard=await saved.context.readLiveBoard('view');
 assert.equal(savedBoard.data.tasks.length,1);
 assert.deepEqual(Array.from(savedBoard.data.tasks[0].categoryIDs),['ready']);
 assert.deepEqual(saved.batches,[2,3],'Saved view query/get and section/filter membership calls are batched.');
 for(const [options,code] of [[{unresolved:['done']},'itemUnresolved'],[{remaining:['done']},'categoryUnavailable'],[{oversized:['done']},'categoryUnavailable'],[{missing:['done']},'categoryUnavailable']]) {
  const invalid=savedFixture(options);
  await assert.rejects(invalid.context.readLiveBoard('view'),error=>error.code===code,'A two-section board must validate both categories before retaining rows.');
  const nodes=new Map(['board-load-error','project-counts','filter-count','connection-message','learning-dialog','search','track-filter'].map(id=>[id,{hidden:true,value:'',open:false,textContent:''}]));
  Object.assign(invalid.context,{isRefreshing:false,refreshGeneration:0,viewGeneration:0,pendingWrite:null,isSaving:false,isConnected:true,
   data:{tasks:[{id:'stale'}],columns:[{id:'ready'},{id:'done'}]},revisionsByID:new Map([['stale',{}]]),undoStack:[],changes:0,
   $:id=>nodes.get(id),updateConnectionState:()=>{},render:()=>{},renderProjectViews:()=>{},showWorkspace:()=>{},resumeEditorAfterSignIn:false});
  vm.runInContext(live.slice(live.indexOf('  function clearViewData('),live.indexOf('  function restorePendingWrite(')),invalid.context);
  vm.runInContext(live.slice(live.indexOf('  async function refreshLiveBoard('),live.indexOf('  async function selectProjectView(')),invalid.context);
  assert.equal(await invalid.context.refreshLiveBoard(),false);
  assert.equal(invalid.context.data.tasks.length,0);
  assert.equal(invalid.context.revisionsByID.size,0,'No stale editable record survives an unvalidated saved-view category.');
  assert.equal(nodes.get('board-load-error').hidden,false);
 }
 const failed=fixture(),controls=new Map(['board-load-error','project-counts','filter-count','connection-message','learning-dialog','search','track-filter'].map(id=>[id,{hidden:true,value:'',open:false,textContent:''}]));
 const validRead=failed.context.readLiveBoard;
 Object.assign(failed.context,{isRefreshing:false,refreshGeneration:0,viewGeneration:0,pendingWrite:null,
  isSaving:false,isConnected:true,data:{tasks:[{id:'stale'}],columns:[{id:'stale-column'}]},
  revisionsByID:new Map([['stale',{}]]),undoStack:[],changes:0,
  $:id=>controls.get(id),updateConnectionState:()=>{},render:()=>{},renderProjectViews:()=>{},
  showWorkspace:()=>{},resumeEditorAfterSignIn:false,
  readLiveBoard:async()=>{throw Object.assign(new Error('Exact query candidates exceed the bounded working set.'),{code:'resourceLimit'});}
 });
 vm.runInContext(live.slice(live.indexOf('  function clearViewData('),live.indexOf('  function restorePendingWrite(')),failed.context);
 vm.runInContext(live.slice(live.indexOf('  async function refreshLiveBoard('),live.indexOf('  async function selectProjectView(')),failed.context);
 assert.equal(await failed.context.refreshLiveBoard(),false);
 assert.equal(failed.context.data.tasks.length,0,'A failed authorized read clears stale cards.');
 assert.equal(failed.context.revisionsByID.size,0);
 assert.equal(controls.get('board-load-error').hidden,false,'Failure is explicit inside the board.');
 assert.match(controls.get('board-load-error').textContent,/Could not load this board: Exact query candidates/);
 assert.equal(controls.get('project-counts').hidden,true,'A failed read must not claim zero items or columns.');
 assert.equal(controls.get('filter-count').textContent,'Board unavailable');
 assert.equal(failed.context.isConnected,false);
 failed.context.readLiveBoard=async()=>({data:{tasks:[],columns:[]},revisions:new Map(),projectionNotice:true,unresolved:[{itemID:'oldA',status:'conflicted'}]});
 failed.context.isConnected=true;failed.context.data={tasks:[{id:'oldA'},{id:'oldB'}],columns:[{id:'existing'}]};
 assert.equal(await failed.context.refreshLiveBoard(),true);
 assert.deepEqual(failed.context.data.tasks,[],'An unresolved current A must not retain old A or unrelated old B.');
 assert.match(controls.get('connection-message').textContent,/item-state\/conflicts/);
 failed.context.readLiveBoard=async()=>({data:{tasks:[],columns:[]},revisions:new Map(),projectionNotice:true});
 assert.equal(await failed.context.refreshLiveBoard(),true);
 assert.equal(failed.context.data.tasks.length,0,'An empty current result replaces old rows while retaining the notice.');
 failed.context.data={tasks:[{id:'old-category-board'}],columns:[]};
 failed.context.readLiveBoard=async()=>{throw Object.assign(new Error('category unresolved'),{code:'itemUnresolved'});};
 assert.equal(await failed.context.refreshLiveBoard(),false);
 assert.equal(failed.context.data.tasks.length,0,'An unresolved category clears an unvalidated old board.');
 assert.equal(controls.get('board-load-error').hidden,false);
 failed.context.data={tasks:[{id:'selected-project-old'}],columns:[]};
 const validSelection=failed.context.selectionIsCurrent;
 failed.context.selectionIsCurrent=()=>false;
 failed.context.readLiveBoard=async()=>({data:{tasks:[{id:'late-project-row'}],columns:[]},revisions:new Map()});
 assert.equal(await failed.context.refreshLiveBoard(),false);
 assert.equal(failed.context.data.tasks[0].id,'selected-project-old','A stale project generation cannot replace the selected board.');
 failed.context.selectionIsCurrent=validSelection;
 failed.context.readLiveBoard=validRead;
 assert.equal(await failed.context.refreshLiveBoard(),true);
 assert.equal(failed.context.data.tasks.length,1);
 assert.equal(controls.get('board-load-error').hidden,true);
 assert.equal(controls.get('project-counts').hidden,false);
 console.log('Board failure: resourceLimit clears stale content, hides unconfirmed counts, and successful retry restores the board.');
 console.log('Projection state: mixed/empty results, global conflict flags, and unhydrated IDs remain explicit; stale rows are replaced.');
 console.log('Board loading: content preserved, ID-only memberships, one scoped graph, and generation invalidation passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
