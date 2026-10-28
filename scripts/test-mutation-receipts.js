#!/usr/bin/env node
'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync('Sources/TractandaWeb/Resources/LiveClient.js','utf8');
const sender=source.slice(source.indexOf('  async function sendPendingWrite()'),source.indexOf('  function appendRevisionHistory('));
const cleaner=source.slice(source.indexOf('  function clearPendingWrite()'),source.indexOf('  async function saveLiveTask('));
function setup(options={}) {
  const nodes=new Map(); const storage=new Map(); let calls=0,closed=0;
  const write={viewItemID:'view',method:'TractandaItem/commit',request:{action:'revise',itemID:'item',operationID:'frozen'}};
  const receipt={itemId:'item',revisionId:'revision',operationId:'frozen',replayed:false,indexReady:true,diagnostics:[]};
  const context={pendingWrite:write,dirty:true,isSaving:false,selectedViewID:'view',viewGeneration:1,
    updateConnectionState(){},selectionIsCurrent(){return options.current!==false;},
    $(id){if(!nodes.has(id))nodes.set(id,{textContent:'',open:true,close(){closed++;}});return nodes.get(id);},
    async nativeCall(){calls++;return options.receipt||receipt;},
    async refreshLiveBoard(){if(options.refreshFails)throw Error('read denied');return true;},
    pendingStorageKey(id){return id;},sessionStorage:{setItem(k,v){storage.set(k,v);},removeItem(k){if(options.cleanupFails)throw Error('storage denied');storage.delete(k);}},
    toast(){},apiError(code,message){return Object.assign(Error(message),{code});},
  };
  vm.createContext(context);vm.runInContext(cleaner+sender,context);
  return {context,nodes,options,storage,calls:()=>calls,closed:()=>closed};
}
(async()=>{
  let s=setup({refreshFails:true});await s.context.sendPendingWrite();
  assert.equal(s.context.pendingWrite,null);assert.match(s.nodes.get('connection-message').textContent,/Saved/);
  assert.equal(s.calls(),1);await s.context.sendPendingWrite();assert.equal(s.calls(),1);
  s=setup({receipt:{itemId:'item',revisionId:'revision',operationId:'unrelated',diagnostics:[]}});
  await s.context.sendPendingWrite();assert.ok(s.context.pendingWrite);assert.equal(s.closed(),0);
  s=setup({cleanupFails:true});await s.context.sendPendingWrite();
  assert.ok(s.context.pendingWrite.confirmation);assert.ok(JSON.parse(s.storage.get('view')).confirmation);
  s.options.cleanupFails=false;await s.context.sendPendingWrite();assert.equal(s.calls(),1);assert.equal(s.context.pendingWrite,null);
  s=setup({current:false});await s.context.sendPendingWrite();assert.equal(s.closed(),0);assert.equal(s.context.pendingWrite,null);
  const nativeSender=source.slice(source.indexOf('  async function nativeCalls('),source.indexOf('  function plain('));
  for(const code of ['notJSON','notRequest','unknownCapability','limit','serverPartialFail']) {
    let sent;
    const requestContext={accessToken:'token',nativeCapability:'vendor',AbortSignal:{timeout(){return null;}},
      apiError(c,message,isDefinitive=false){return Object.assign(Error(message),{code:c,isDefinitive});},
      async fetch(url,request){sent=JSON.parse(request.body);return {ok:code==='serverPartialFail',status:400,
        async json(){return code==='serverPartialFail'?{methodResponses:[['error',{type:code},'web-0']]}:
          {type:'urn:ietf:params:jmap:error:'+code,status:400};}};}};
    vm.createContext(requestContext);vm.runInContext(nativeSender,requestContext);
    requestContext.nativeCalls.context={token:'token',session:{accountID:'account',state:'metadata'},pending:null};
    await assert.rejects(requestContext.nativeCall('TractandaItem/commit',{}),error=>
      error.code===code && error.isDefinitive===(code!=='serverPartialFail'));
    assert.ok(sent.using.includes('urn:ietf:params:jmap:core'));
  }
  console.log('PASS:9 mutation receipt and request-problem consumer cases');
})().catch(error=>{console.error(error);process.exitCode=1;});
