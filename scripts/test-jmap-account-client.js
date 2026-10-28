#!/usr/bin/env node
'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync('Sources/TractandaWeb/Resources/LiveClient.js','utf8');
const snippet=source.slice(source.indexOf('  async function nativeCalls('),source.indexOf('  function plain('));
const capability='https://tractanda.ai/ns/jmap/1';
(async()=>{
 const requests=[];let state='metadata-1',active=0,maximum=0;
 const context={accessToken:'alice',nativeCapability:capability,AbortSignal:{timeout(){}},showServerVersion(){},
  apiError:(code,message,isDefinitive)=>Object.assign(Error(message),{code,isDefinitive}),
  async fetch(_url,options){
   const body=JSON.parse(options.body);requests.push({token:options.headers.Authorization,body});
   const calls=body.methodCalls;
   if(calls[0][0]==='TractandaSession/get') {
    maximum=Math.max(maximum,++active);await new Promise(resolve=>setTimeout(resolve,10));active--;
    const document={profile:'tractanda.local-session.v1',state,primaryAccounts:{[capability]:'store-account'},
     accounts:{'store-account':{accountCapabilities:{[capability]:{}}}}};
    return {ok:true,json:async()=>({sessionState:state,methodResponses:[['TractandaSession/get',document,calls[0][2]]]})};
   }
   return {ok:true,json:async()=>({sessionState:state,methodResponses:calls.map(([method,args,id])=>[method,args,id])})};
  }};
 vm.createContext(context);vm.runInContext(snippet,context);
 await Promise.all(Array.from({length:6},()=>context.nativeCall('TractandaStore/info',{})));
 assert.equal(requests.filter(r=>r.body.methodCalls[0][0]==='TractandaSession/get').length,1);
 assert.equal(maximum,1);
 assert.ok(requests.slice(1).every(r=>r.body.methodCalls[0][1].accountId==='store-account'));
 await context.nativeCall('TractandaStore/info',{accountId:'explicit-foreign'});
 assert.equal(requests.at(-1).body.methodCalls[0][1].accountId,'explicit-foreign');
 await context.nativeCall('TractandaStore/info',{'#accountId':{resultOf:'prior',name:'Core/echo',path:'/id'}});
 assert.ok(!Object.hasOwn(requests.at(-1).body.methodCalls[0][1],'accountId'));
 await context.nativeCall('Core/echo',{number:9007199254740991});
 assert.ok(!Object.hasOwn(requests.at(-1).body.methodCalls[0][1],'accountId'));
 state='metadata-2';
 await context.nativeCall('TractandaItem/commit',{operationID:'frozen'});
 assert.equal(requests.filter(r=>r.body.methodCalls[0][0]==='TractandaSession/get').length,1);
 await context.nativeCall('TractandaStore/info',{});
 assert.equal(requests.filter(r=>r.body.methodCalls[0][0]==='TractandaSession/get').length,2);
 assert.equal(requests.filter(r=>r.body.methodCalls[0][0]==='TractandaItem/commit').length,1);
 context.accessToken='bob';await context.nativeCall('TractandaStore/info',{});
 assert.equal(requests.filter(r=>r.body.methodCalls[0][0]==='TractandaSession/get').length,3);
 assert.equal(requests.at(-1).token,'Bearer bob');
 assert.ok(requests.every(r=>r.body.using.includes(capability)));
 console.log('PASS:8 browser account/discovery transcript contracts');
})().catch(error=>{console.error(error);process.exitCode=1;});
