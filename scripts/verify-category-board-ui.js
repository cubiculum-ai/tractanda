async (page) => {
  const token='__TOKEN__', mapping=__MAPPING__;
  const errors=[],checks=[];
  page.on('pageerror',error=>errors.push(error.message));
  await page.unroute('**/api');await page.unroute('**/auth/login');
  await page.goto('about:blank');
  await page.goto('__URL__#token='+token);
  await page.locator('.card-title').first().waitFor();
  const origin=await page.evaluate(()=>location.origin);
  async function rpc(method,args) {
    const response=await page.request.post(origin+'/api',{headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',Origin:origin},data:{using:['https://tractanda.ai/ns/local-prototype/4'],methodCalls:[[method,args,'ui']]}});
    const data=await response.json();const result=data.methodResponses[0];if(result[0]!==method)throw new Error(JSON.stringify(result));return result[1];
  }
  async function item(id){return (await rpc('TractandaItem/get',{ids:[id]})).list[0];}
  async function history(id){return (await rpc('TractandaItem/history',{itemID:id})).total;}
  async function waitSaved(){await page.locator('#task-dialog').waitFor({state:'hidden'});await page.waitForFunction(()=>document.querySelector('#save-indicator').textContent.includes('Saved to Tractanda'));}
  function check(value,text){if(!value)throw new Error(text);checks.push(text);}
  const firstID=mapping.itemIDs['TEST-1'], c=mapping.columns;
  const firstCard=()=>page.locator('article[data-task-id="'+firstID+'"]').first();
  check(await page.evaluate(()=>!!navigator.brave),'Brave is used for the category board');
  check((await firstCard().locator('.card-id').innerText())==='TEST-1','The view displays the label from its category scope');
  check(await page.locator('.lane').count()===5,'Five ordinary category sections define the initial lanes');
  await firstCard().locator('.card-title').click();
  await page.locator('[data-column-choice="'+c.doing+'"]').check();
  await page.locator('#task-form [type=submit]').click();await waitSaved();
  check(await page.locator('article[data-task-id="'+firstID+'"]').count()===2,'One item can appear in multiple category columns');
  const shared=await item(firstID);
  check(shared.fields.classID.value==='EmailMessageItem'&&!shared.fields.status&&!shared.fields.kanbanBoardID,'Email identity/type is retained without status or board-owner fields');
  const source=page.locator('.lane[data-category-id="'+c.ready+'"] article[data-task-id="'+firstID+'"]');
  await source.dragTo(page.locator('.lane[data-category-id="'+c.review+'"] .lane-cards'));
  await page.waitForFunction(({id,source,target})=>!document.querySelector('.lane[data-category-id="'+source+'"] article[data-task-id="'+id+'"]')&&!!document.querySelector('.lane[data-category-id="'+target+'"] article[data-task-id="'+id+'"]'),{id:firstID,source:c.ready,target:c.review});
  const moved=await item(firstID), assignments=moved.fields.categoryOverrides.value;
  check(assignments[c.ready].value==='exclude'&&assignments[c.review].value==='include'&&assignments[c.doing].value==='include','Dragging reassigns source/target while retaining other column memberships');
  check(assignments[mapping.projectID].value==='include'&&assignments[mapping.groupID].value==='include'&&moved.fields.foreignMetadata.value.retain.value,'Project, other dimensions and unknown metadata survive a card move');
  const count=await history(firstID);
  await firstCard().locator('.card-title').click();
  await page.locator('[data-column-choice="'+c.done+'"]').check();
  await page.locator('#task-form [type=submit]').click();
  await page.getByText('Complete the checklist before moving this task to Done.',{exact:true}).waitFor();
  check(await history(firstID)===count,'Configured completion category honors the checklist without submitting a failed edit');
  await page.locator('input[data-step-id]').check();
  await page.locator('#task-form [type=submit]').click();await waitSaved();
  check((await item(firstID)).fields.categoryOverrides.value[c.done].value==='include','Completion is stored as category membership');
  const category=await item(c.doing);
  await rpc('TractandaItem/commit',{action:'revise',itemID:c.doing,expectedRevisionID:category.fields.revisionID.value,operationID:'ui-rename-category',changes:{subject:{type:'text',value:'Working now'}},unset:[]});
  await page.locator('#refresh-board').click();
  await page.getByRole('heading',{name:'Working now',exact:true}).waitFor();
  check(await page.locator('.lane[data-category-id="'+c.doing+'"] article[data-task-id="'+firstID+'"]').count()===1,'Category renaming changes labels while retaining identity and membership');
  await page.locator('#new-task').click();
  await page.locator('#edit-title').fill('Plain note from category view');
  await page.locator('#task-form [type=submit]').click();await waitSaved();
  const createdIDs=(await rpc('TractandaItem/query',{expression:'subject == "Plain note from category view"'})).ids;
  check(createdIDs.length===1,'Web capture creates exactly one ordinary item');
  const created=await item(createdIDs[0]);
  check(created.fields.classID.value==='Item'&&createdIDs[0][14]==='1'&&!created.fields.status&&!created.fields.externalItemID&&!created.fields.kanbanBoardID,'New items use UUIDv1 and no bootstrap identity or special task class');
  check(created.fields.categoryOverrides.value[mapping.projectID].value==='include'&&created.fields.categoryOverrides.value[c.planned].value==='include','View capture uses its configured project and default category');
  await page.locator('#track-filter').selectOption(mapping.groupID);
  check(await page.locator('article[data-task-id="'+createdIDs[0]+'"]').count()===0,'Additional category filters apply independently');
  await page.locator('#track-filter').selectOption('all');
  await page.setViewportSize({width:1440,height:1000});
  await page.screenshot({path:'output/playwright/category-board-desktop.png',fullPage:true});
  await page.setViewportSize({width:390,height:844});
  await page.screenshot({path:'output/playwright/category-board-mobile.png',fullPage:true});
  check(errors.length===0,'No browser JavaScript errors');
  return {status:'passed',checks};
}
