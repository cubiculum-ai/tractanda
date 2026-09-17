// Playwright CLI run-code fixture. Substitute only a disposable adapter URL/token
// and the example helper's alpha/beta mapping. No real password or live store.
async (page) => {
  const token='__TOKEN__', mapping=__MAPPING__, url='__URL__';
  const checks=[], errors=[], alpha=mapping.alpha, beta=mapping.beta;
  const check=(value,label)=>{if(!value)throw new Error(label);checks.push(label);};
  page.on('pageerror',error=>errors.push(error.message));
  page.on('dialog',dialog=>dialog.accept());
  await page.addInitScript(()=>{
    const original=window.addEventListener.bind(window);
    window.addEventListener=(type,...args)=>{if(type!=='beforeunload')original(type,...args);};
  });
  await page.goto('about:blank');
  await page.goto(url+'#token='+token);
  const origin=await page.evaluate(()=>location.origin);
  const picker=page.getByLabel('Project',{exact:true});
  const text=value=>({type:'text',value}), ref=id=>({type:'reference',value:{itemID:id}});
  async function rpc(method,args) {
    const response=await page.request.post(origin+'/api',{headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',Origin:origin},data:{using:['https://tractanda.ai/ns/local-prototype/4'],methodCalls:[[method,args,'acceptance']]}});
    const call=(await response.json()).methodResponses?.[0];
    if(!call||call[0]!==method)throw new Error('Native method failed: '+JSON.stringify(call));
    return call[1];
  }
  async function item(id){return (await rpc('TractandaItem/get',{ids:[id]})).list[0];}
  const id=revision=>revision.fields.itemID.value;
  async function commit(changes,existing=null,action=null) {
    const request={action:action||(existing?'revise':'create'),changes,unset:[],operationID:'ui-fixture:'+(Date.now().toString(36)+'-'+Math.random().toString(36).slice(2))};
    if(existing){request.itemID=id(existing);request.expectedRevisionID=existing.fields.revisionID.value;}
    else request.classID='Item';
    return (await rpc('TractandaItem/commit',request)).revision;
  }
  async function choose(project) {
    await picker.selectOption(project);
    await page.waitForFunction(()=>!document.querySelector('#project-picker').disabled);
  }
  check(await page.evaluate(async()=>!!navigator.brave&&await navigator.brave.isBrave()),'Runs in isolated Brave');
  await page.getByRole('button',{name:'Try Alpha',exact:true}).waitFor();
  check((await picker.locator('option').allTextContents()).includes('Projects / Beta'),'Ordinary projects without saved views appear');
  check((await rpc('TractandaItem/query',{expression:'viewDefinition == *'})).total===0,'No saved view is needed or created');
  const noStatus=await commit({subject:text('Alpha knowledge without status'),categoryOverrides:{type:'object',value:{[alpha.projectID]:text('include')}}});
  const shared=await commit({subject:text('Shared action'),categoryOverrides:{type:'object',value:{[alpha.projectID]:text('include'),[beta.projectID]:text('include'),[alpha.columnIDs[0]]:text('include')}}});
  await page.locator('#refresh-board').click();
  await page.getByRole('button',{name:'Shared action',exact:true}).waitFor();
  check(await page.getByRole('button',{name:'Alpha knowledge without status',exact:true}).count()===0,'No-status project knowledge stays outside the Kanban');
  await choose(beta.projectID);
  check(await page.getByRole('button',{name:'Shared action',exact:true}).count()===1,'An overlapping item appears in each selected project without copying');
  check(await page.locator('#page-title').innerText()==='Beta'&&(await page.title()).startsWith('Beta'),'Heading and browser title follow the selected project');
  check(await page.evaluate(()=>new URL(location.href).searchParams.get('project'))===beta.projectID,'Selection is bookmarkable');
  await page.reload();await page.getByRole('button',{name:'Try Beta',exact:true}).waitFor();
  check(await picker.inputValue()===beta.projectID,'Direct project URL survives reload');

  await commit({defaultCategory:ref(beta.columnIDs[1])},await item(beta.projectID));
  await page.locator('#refresh-board').click();await page.waitForFunction(()=>!document.querySelector('#refresh-board').disabled);
  await page.locator('#new-task').click();
  check(await picker.isDisabled(),'An open draft blocks project switching');
  check(await page.locator('[data-column-choice="'+beta.columnIDs[1]+'"]').isChecked(),'Project-specific default status is applied');
  await page.locator('#edit-title').fill('Captured in Beta');
  await page.locator('#task-form [type=submit]').click();
  await page.getByRole('button',{name:'Captured in Beta',exact:true}).waitFor();
  const captured=await item((await rpc('TractandaItem/query',{expression:'subject == "Captured in Beta"'})).ids[0]);
  const overrides=captured.fields.categoryOverrides.value;
  check(overrides[beta.projectID].value==='include'&&overrides[beta.columnIDs[1]].value==='include'&&!overrides[alpha.projectID],'Capture uses selected project and status only');
  const gamma=await commit({subject:text('Gamma'),selection:{type:'object',value:{language:text('tractanda.spotlight.v0'),expression:text('itemID == ""')}},categoryParents:{type:'list',value:[ref(alpha.projectRootID)]}});
  await page.locator('#refresh-projects').click();
  await picker.locator('option[value="'+id(gamma)+'"]').waitFor({state:'attached'});
  check(true,'Refresh discovers a new empty project without a saved view');

  await choose(alpha.projectID);
  const alphaItem=await item((await rpc('TractandaItem/query',{expression:'subject == "Try Alpha"'})).ids[0]);
  const historyBefore=(await rpc('TractandaItem/history',{itemID:id(alphaItem)})).total;
  const operations=[];let replayed=false;
  const lossRoute=async route=>{
    const call=route.request().postDataJSON().methodCalls[0];
    if(call[0]!=='TractandaItem/commit'||call[1].itemID!==id(alphaItem)){await route.continue();return;}
    operations.push(JSON.stringify(call[1]));
    const response=await route.fetch();const result=(await response.json()).methodResponses[0];
    if(operations.length===1)await route.fulfill({status:503,contentType:'application/json',body:JSON.stringify({code:'fixtureResponseLoss',message:'Committed response deliberately withheld.'})});
    else{replayed=result[1].replayed;await route.fulfill({response});}
  };
  await page.route('**/api',lossRoute);
  await page.getByRole('button',{name:'Try Alpha',exact:true}).click();
  await page.locator('#edit-title').fill('Alpha response recovered');
  await page.locator('#task-form [type=submit]').click();
  await page.waitForFunction(()=>document.querySelector('#retry-write').hidden===false);
  check(await picker.isDisabled(),'Unconfirmed writes block project switching');
  await page.reload();await page.locator('#retry-write').waitFor({state:'visible'});
  await page.waitForFunction(()=>!document.querySelector('#refresh-board').disabled);
  check(await picker.isDisabled(),'Unconfirmed write and selection guard survive reload');
  await page.locator('#retry-write').click();
  await page.getByRole('button',{name:'Alpha response recovered',exact:true}).waitFor();
  await page.waitForFunction(project=>!sessionStorage.getItem('tractanda.pending.v4.project.'+project),alpha.projectID);
  await page.waitForFunction(()=>!document.querySelector('#refresh-board').disabled);
  await page.locator('#retry-write').waitFor({state:'hidden'});
  check(operations.length===2&&operations[0]===operations[1]&&replayed,'Retry sends the exact original request and gets the committed result');
  check((await rpc('TractandaItem/history',{itemID:id(alphaItem)})).total===historyBefore+1,'Lost-response recovery creates exactly one revision');
  await page.unroute('**/api',lossRoute);

  const base=await item(id(alphaItem));
  const legacy={request:{action:'revise',itemID:id(base),expectedRevisionID:base.fields.revisionID.value,changes:{subject:text('Alpha legacy recovered')},unset:[],operationID:'legacy-fixture:'+(Date.now().toString(36)+'-'+Math.random().toString(36).slice(2))},candidate:{id:id(base)}};
  await page.evaluate(({project,legacy})=>sessionStorage.setItem('tractanda.pending.v2.'+project,JSON.stringify(legacy)),{project:alpha.projectID,legacy});
  await page.reload();await page.locator('#retry-write').waitFor({state:'visible'});
  await page.waitForFunction(()=>!document.querySelector('#refresh-board').disabled);
  const migrated=await page.evaluate(project=>({old:sessionStorage.getItem('tractanda.pending.v2.'+project),current:JSON.parse(sessionStorage.getItem('tractanda.pending.v4.project.'+project))}),alpha.projectID);
  check(!migrated.old&&migrated.current.viewItemID===alpha.projectID&&JSON.stringify(migrated.current.request)===JSON.stringify(legacy.request),'Upgrade migrates v2 ownership while preserving the exact request');
  await page.goto(origin+'/?project='+beta.projectID);await page.getByRole('button',{name:'Try Beta',exact:true}).waitFor();
  check(!await page.locator('#retry-write').isVisible(),'Another project does not replay an old project’s journal');
  await picker.selectOption(alpha.projectID);
  await page.locator('#retry-write').waitFor({state:'visible'});
  await page.waitForFunction(()=>!document.querySelector('#refresh-board').disabled);
  check(await picker.isDisabled(),'Returning to the original project restores its retained journal');
  await page.locator('#retry-write').click();await page.getByRole('button',{name:'Alpha legacy recovered',exact:true}).waitFor();
  check((await rpc('TractandaItem/history',{itemID:id(base)})).total===historyBefore+2,'Legacy journal retry publishes its one intended revision');

  let release,held;const gate=new Promise(resolve=>{release=resolve;}),waiting=new Promise(resolve=>{held=resolve;});let delayed=false;
  const delayRoute=async route=>{
    const call=route.request().postDataJSON().methodCalls[0];
    if(!delayed&&call[0]==='TractandaItem/query'&&call[1].categoryPath?.includes(alpha.projectID)){
      delayed=true;const response=await route.fetch();held();await gate;await route.fulfill({response});
    }else await route.continue();
  };
  await page.route('**/api',delayRoute);
  await page.locator('#refresh-board').click();await waiting;
  // Model a selection event already queued when refresh disabled the control.
  await page.evaluate(project=>{const p=document.querySelector('#project-picker');p.value=project;p.dispatchEvent(new Event('change',{bubbles:true}));},beta.projectID);
  await page.getByRole('button',{name:'Try Beta',exact:true}).waitFor();release();
  await page.waitForTimeout(350);
  check(await page.locator('#page-title').innerText()==='Beta'&&!await picker.isDisabled()&&await page.getByRole('button',{name:'Alpha legacy recovered',exact:true}).count()===0,'Delayed old reads neither replace the selected project nor leave refresh stuck');
  await page.unroute('**/api',delayRoute);

  await choose(id(gamma));await commit({isDeleted:{type:'boolean',value:true}},await item(id(gamma)));
  await page.reload();await page.waitForFunction(()=>document.querySelector('#connection-message').textContent.includes('no longer available'));
  check(await page.locator('.card-title').count()===0&&!await picker.isDisabled(),'Deleted initial project clears old cards and keeps alternative choices available');
  await choose(beta.projectID);await page.getByRole('button',{name:'Captured in Beta',exact:true}).waitFor();
  // Attached-CDP browsers can write downloads without forwarding Playwright's
  // Download event. Restrict the actual browser write to the disposable artifact
  // directory and verify the resulting file through the browser itself.
  const cdp=await page.context().newCDPSession(page);
  await cdp.send('Browser.setDownloadBehavior',{behavior:'allow',downloadPath:'__EXPORT_DIRECTORY__',eventsEnabled:true});
  await page.locator('#save-html').click();
  const offline=await page.context().newPage();
  let exportLoaded=false;
  for(let attempt=0;attempt<50;attempt++) {
    try {
      const response=await offline.goto('__EXPORT_URL__');
      if(response?.ok()){exportLoaded=true;break;}
    } catch(error){if(attempt===49)throw error;}
    await page.waitForTimeout(100);
  }
  check(exportLoaded,'Actual export writes the selected project filename Beta.html');
  await offline.getByRole('button',{name:'Captured in Beta',exact:true}).waitFor();
  const snapshot=JSON.parse(await offline.locator('#board-data').textContent());
  const html=await offline.content();
  check(snapshot.projectID===beta.projectID&&snapshot.tasks.some(t=>t.title==='Shared action')&&!snapshot.tasks.some(t=>t.title.startsWith('Alpha')),'Offline export contains the selected project and its overlapping item');
  check(!html.includes(token)&&!html.includes(alpha.projectID)&&!await offline.locator('#project-picker-label').isVisible(),'Offline export contains no token or other project catalog');
  await offline.close();
  await page.goto(origin+'/manual');await page.getByRole('heading',{name:'Items, categories and views'}).waitFor();
  await page.setViewportSize({width:390,height:844});
  check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Manual fits a mobile viewport');
  check(errors.length===0,'No uncaught browser JavaScript errors');
  return {status:'passed',checks,count:checks.length,authentication:'Disposable launch token; all records/history/commits use the real native server. Response loss and delay are intentional network fixtures.'};
}
