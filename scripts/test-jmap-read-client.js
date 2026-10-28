#!/usr/bin/env node
'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync('Sources/TractandaWeb/Resources/LiveClient.js','utf8');
const text=value=>({type:'text',value});
const context=vm.createContext({fieldText:(fields,key)=>fields[key]?.value||'',categoryReferences:field=>(field?.value||[]).map(value=>value.value.itemID)});
vm.runInContext(source.slice(source.indexOf('  function categoryOrder('),source.indexOf('  async function queryIDGroups(')),context);
const query=context.queryArguments({expression:'subject == *',position:-1,limit:0,sort:[{categoryRootID:'axis',isAscending:false}]});
assert.equal(query.filter.expression,'subject == *');assert.equal(query.expression,undefined);
assert.equal(query.calculateTotal,true);assert.equal(query.position,-1);assert.equal(query.limit,0);
assert.deepEqual(JSON.parse(JSON.stringify(query.sort)),[{property:'categoryMembership',categoryRootId:'axis',isAscending:false}]);
const diagnostic={id:'unresolved',revisionId:null,fields:null,resolution:{itemID:'unresolved',status:'reviewRequired',representativeRevisionID:'diagnostic-head'}};
const ready={id:'ready',revisionId:'real-head',fields:{subject:text('visible')},resolution:{itemID:'ready',status:'ready'}};
assert.deepEqual(Array.from(context.readyReadItems({list:[diagnostic,ready]}),record=>record.id),['ready']);
assert.deepEqual(Array.from(context.unresolvedReadItems({list:[diagnostic,ready]}),state=>state.itemID),['unresolved']);
assert.equal(diagnostic.fields,null);assert.equal(diagnostic.resolution.representativeRevisionID,'diagnostic-head');
const category=(id,subject,order,parent)=>({id,fields:{itemID:text(id),subject:text(subject),selection:text(''),
 ...(order===undefined?{}:{categoryOrder:{type:'integer',value:order}}),
 categoryParents:{type:'list',value:parent?[{type:'reference',value:{itemID:parent}}]:[]}}});
const graph=context.categoryGraph([category('root','Root'),category('lower','Z lower','9223372036854775806','root'),category('upper','A upper','9223372036854775807','root')]);
assert.deepEqual(Array.from(graph.children.get('root')),['lower','upper'],'Adjacent Int64 orders must not round into a subject tie.');
console.log('PASS:6 browser read DTO/query/Int64 comparison contracts');
