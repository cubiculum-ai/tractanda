  let learningCategoryID = '', learningNotice = '', learningIsLoading = false;
  let learningItemPosition = 0, learningSuggestionPosition = 0, learningQueryState = null;

  function updateLearningControls() {
    $('learning-button').disabled = !isConnected || isSaving;
    $('close-learning').disabled = isSaving;
    document.querySelectorAll('[data-learning-action]').forEach(control => {
      control.disabled = !isConnected || isSaving || !!pendingWrite || learningIsLoading;
    });
    const retry = $('learning-retry');
    if (retry) {retry.hidden = !pendingWrite;retry.disabled = isSaving;}
    const notice = $('learning-notice');
    if (notice) notice.textContent = pendingWrite
      ? 'An edit needs confirmation. Retry the same edit before making another decision.' : learningNotice;
  }

  function learningButton(label, handler) {
    return element('button',{type:'button',text:label,'data-learning-action':'',onclick:handler});
  }

  async function saveLearningEdit(method, request, categoryID = learningCategoryID) {
    if (isSaving || pendingWrite || learningIsLoading) return;
    request.operationID = 'web:'+crypto.randomUUID();
    try {retainPendingWrite({viewItemID:selectedViewID,method,request,context:'learning',categoryID});}
    catch {learningNotice='The browser could not retain this edit for retry. It has not been sent.';updateLearningControls();return;}
    await sendPendingWrite();
  }

  async function runLearningOperation(method) {
    if (!learningCategoryID || isSaving || pendingWrite || learningIsLoading) return;
    isSaving=true;updateConnectionState();
    try {
      const result=await nativeCall('TractandaLearning/'+method,{categoryID:learningCategoryID});
      learningNotice=method==='reset' ? 'Model reset. Assignments, exclusions and feedback are preserved.'
        : result.status==='ready' ? 'Training complete. Suggestions are ready to review.'
        : 'Training needs more usable examples. Review the category status below.';
      learningSuggestionPosition=0;learningQueryState=null;
    } catch(error) {learningNotice=error.message;}
    finally {isSaving=false;updateConnectionState();}
    await refreshLearningPanel();
  }

  function learningItem(revision, suggestion = null) {
    const fields=revision.fields, itemID=fieldText(fields,'itemID');
    const override=fields.categoryOverrides?.value?.[learningCategoryID]?.value;
    const feedback=fields.learningFeedback?.value?.[learningCategoryID]?.value?.action?.value;
    const section=element('article',{class:'learning-item','data-item-id':itemID});
    section.append(element('h4',{text:fieldText(fields,'subject')||'Untitled item'}));
    const body=fieldText(fields,'body');
    if (body) section.append(element('p',{text:body.length>240?body.slice(0,240)+'…':body}));
    const decision=override==='include'?'Manually assigned':override==='exclude'?'Manually excluded'
      :feedback?'Last feedback: '+feedback:'No manual decision';
    section.append(element('p',{class:'helper',text:decision+(suggestion?' · Suggestion score '+suggestion.score.toFixed(3):'')}));
    function respond(action) {
      const request={itemID,categoryID:learningCategoryID,expectedRevisionID:fieldText(fields,'revisionID'),action};
      if (suggestion) request.modelID=suggestion.modelID;
      void saveLearningEdit('TractandaLearning/feedback',request);
    }
    const actions=element('div',{class:'learning-actions'});
    if (override!=='include') actions.append(learningButton(suggestion?'Accept':'Assign',()=>respond('accept')));
    if (override!=='exclude') actions.append(learningButton('Exclude',()=>respond('exclude')));
    if (!override) actions.append(learningButton('Reject',()=>respond('negative')),learningButton('Dismiss',()=>respond('dismiss')));
    if (override || feedback) actions.append(learningButton('Clear decision',()=>{
      const overrides=clone(fields.categoryOverrides?.value||{}), feedbacks=clone(fields.learningFeedback?.value||{});
      delete overrides[learningCategoryID];delete feedbacks[learningCategoryID];
      void saveLearningEdit('TractandaItem/commit',{action:'revise',itemID,
        expectedRevisionID:fieldText(fields,'revisionID'),unset:[],changes:{
          categoryOverrides:{type:'object',value:overrides},learningFeedback:{type:'object',value:feedbacks}}});
    }));
    section.append(actions);return section;
  }

  function renderLearningSettings(category, state) {
    const details=element('details',{},[element('summary',{text:'Category settings'})]);
    const mode=element('select',{'aria-label':'Learning mode','data-learning-action':''},[
      element('option',{value:'suggestions',text:'Suggest assignments'}),element('option',{value:'off',text:'Off'})]);
    mode.value=state.settings.mode;
    const threshold=element('input',{type:'number',min:'-2',max:'2',step:'0.05',value:state.settings.threshold,
      'aria-label':'Suggestion threshold','data-learning-action':''});
    const rule=element('input',{type:'checkbox','aria-label':'Train from selection-rule matches','data-learning-action':''});
    rule.checked=state.settings.usesRuleMatches;
    details.append(element('div',{class:'learning-settings'},[
      element('label',{class:'field'},[element('span',{text:'Learning mode'}),mode]),
      element('label',{class:'field'},[element('span',{text:'Suggestion threshold (−2 to 2)'}),threshold])
    ]),element('label',{class:'check-row'},[rule,element('span',{text:'Also train positive examples from the category’s selection rule'})]),
      element('p',{class:'helper',text:'Scores rank similarity; they are not probabilities. Unassigned items never count as negative examples.'}),
      learningButton('Save learning settings',()=>{
        const value=Number(threshold.value);
        if (!threshold.value || !Number.isFinite(value) || value < -2 || value > 2) {
          learningNotice='Enter a threshold between −2 and 2.';updateLearningControls();return;
        }
        const settings=clone(category.fields.learningSettings?.value || {profile:typedText('tractanda.category-learning.v1')});
        settings.mode=typedText(mode.value);settings.threshold={type:'real',value};settings.usesRuleMatches={type:'boolean',value:rule.checked};
        void saveLearningEdit('TractandaLearning/settings',{categoryID:learningCategoryID,
          expectedRevisionID:fieldText(category.fields,'revisionID'),settings:{type:'object',value:settings}});
      }));
    return details;
  }

  function learningPagination(position, total, onPage) {
    const actions=element('div',{class:'learning-actions'});
    if (position>0) actions.append(learningButton('Previous page',()=>onPage(Math.max(0,position-20))));
    actions.append(element('span',{class:'helper',text:total?`${position+1}–${Math.min(position+20,total)} of ${total}`:'No items'}));
    if (position+20<total) actions.append(learningButton('Next page',()=>onPage(position+20)));
    return actions;
  }

  async function refreshLearningPanel() {
    if (!$('learning-dialog').open || learningIsLoading) return;
    learningIsLoading=true;updateLearningControls();
    const body=$('learning-body');
    try {
      const query=await nativeCall('TractandaItem/query',{expression:'selection == *',limit:256});
      const categories=query.ids.length?(await nativeCall('TractandaItem/get',{ids:query.ids})).list:[];
      if (!categories.some(item=>fieldText(item.fields,'itemID')===learningCategoryID)) {
        learningCategoryID=categories.length?fieldText(categories[0].fields,'itemID'):'';
        learningItemPosition=0;learningSuggestionPosition=0;learningQueryState=null;
      }
      const category=categories.find(item=>fieldText(item.fields,'itemID')===learningCategoryID);
      const select=element('select',{'aria-label':'Category','data-learning-action':''});
      for (const item of categories) select.append(element('option',{value:fieldText(item.fields,'itemID'),text:fieldText(item.fields,'subject')||'Untitled category'}));
      select.value=learningCategoryID;
      select.addEventListener('change',()=>{
        learningCategoryID=select.value;learningItemPosition=0;learningSuggestionPosition=0;learningQueryState=null;learningNotice='';void refreshLearningPanel();
      });
      const notice=element('p',{id:'learning-notice',class:'learning-notice',role:'status'});
      const retry=element('button',{type:'button',id:'learning-retry',text:'Retry same edit',onclick:()=>void sendPendingWrite()});
      const categoryName=element('input',{type:'text',placeholder:'New category name','aria-label':'New category name','data-learning-action':''});
      body.replaceChildren(notice,retry,element('p',{class:'helper',text:'Assign examples to teach this category. Exclude prevents membership. Reject teaches a negative example; dismiss only hides a suggestion.'}),
        element('label',{class:'field'},[element('span',{text:'Category'}),select]),
        element('details',{},[element('summary',{text:'Create a category'}),element('div',{class:'learning-actions'},[categoryName,
          learningButton('Create category',()=>{
            const name=categoryName.value.trim();if(!name){categoryName.focus();return;}
            void saveLearningEdit('TractandaItem/commit',{action:'create',classID:'Item',unset:[],changes:{subject:typedText(name),
              selection:{type:'object',value:{language:typedText('tractanda.spotlight.v0'),expression:typedText('itemID == ""')}}}},'');
          })])]),
        learningButton('Refresh learning',()=>void refreshLearningPanel()));
      if (query.total>256) body.append(element('p',{class:'helper',text:'Showing the first 256 categories. The CLI can page through the complete collection.'}));
      if (!category) {body.append(element('p',{text:'Create a category to start teaching it from your items.'}));return;}
      const argumentsObject={categoryID:learningCategoryID,position:learningSuggestionPosition,limit:20};
      if (learningSuggestionPosition>0 && learningQueryState) argumentsObject.ifInState=learningQueryState;
      const suggestions=await nativeCall('TractandaLearning/suggest',argumentsObject);
      const state=suggestions.learning;learningQueryState=state.queryState;
      const descriptions={off:'Learning is switched off.',untrained:'Train the model to get suggestions.',
        insufficientEvidence:`Training needs at least ${state.settings.minimumExamplesPerLabel} usable positive and negative examples.`,
        staleModel:'Examples or settings changed. Train again to refresh suggestions.',invalidCache:'The model cache cannot be used. Train again to rebuild it.',
        noSignal:'These examples do not yet separate this category. Add more varied positive and negative examples.',ready:'Suggestions are ready to review.'};
      body.append(element('p',{class:'learning-status',text:`${descriptions[state.status]||state.status} ${state.positiveExamples} positive · ${state.negativeExamples} negative · ${state.unknownItems} without a training label.`}),
        element('div',{class:'learning-actions'},[learningButton('Train model',()=>void runLearningOperation('train')),
          learningButton('Reset model',()=>void runLearningOperation('reset'))]),renderLearningSettings(category,state));
      if (state.emptyExamples || state.omittedExamples) body.append(element('p',{class:'helper',text:`${state.emptyExamples} empty examples ignored; ${state.omittedExamples} exceed this category’s training limit.`}));
      body.append(element('h3',{class:'section-label',text:'Suggestions'}));
      if (suggestions.list.length) {
        const result=await nativeCall('TractandaItem/get',{ids:suggestions.list.map(item=>item.itemID)});
        for (const suggestion of suggestions.list) {
          const item=result.list.find(item=>fieldText(item.fields,'itemID')===suggestion.itemID);
          if (item && fieldText(item.fields,'revisionID')===suggestion.revisionID) body.append(learningItem(item,suggestion));
        }
      } else body.append(element('p',{class:'helper',text:state.status==='ready'?'No suggestions above this category’s threshold.':'Train a usable model before reviewing suggestions.'}));
      body.append(learningPagination(learningSuggestionPosition,suggestions.total,position=>{learningSuggestionPosition=position;void refreshLearningPanel();}));
      const itemQuery=await nativeCall('TractandaItem/query',{expression:'itemID != "'+learningCategoryID+'"',position:learningItemPosition,limit:20});
      const items=itemQuery.ids.length?(await nativeCall('TractandaItem/get',{ids:itemQuery.ids})).list:[];
      body.append(element('h3',{class:'section-label',text:'Teach from your items'}),element('p',{class:'helper',text:'These are items in this server account. Decisions apply to the selected category.'}));
      for (const item of items) body.append(learningItem(item));
      body.append(learningPagination(learningItemPosition,itemQuery.total,position=>{learningItemPosition=position;void refreshLearningPanel();}));
    } catch(error) {
      if(error.code==='stateMismatch'){learningSuggestionPosition=0;learningQueryState=null;}
      learningNotice=error.message;
      body.append(element('p',{role:'alert',text:error.message}));
    } finally {learningIsLoading=false;updateLearningControls();}
  }

  function startLearningClient() {
    $('learning-button').hidden=false;
    $('learning-button').addEventListener('click',()=>{
      $('learning-dialog').showModal();void refreshLearningPanel();
    });
    $('close-learning').addEventListener('click',()=>{if(!isSaving)$('learning-dialog').close();});
    $('learning-dialog').addEventListener('cancel',event=>{if(isSaving)event.preventDefault();});
  }
