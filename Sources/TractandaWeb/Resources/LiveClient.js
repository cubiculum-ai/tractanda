  // This source is embedded in Kanban.html's existing closure for live and snapshot modes.
  var accessToken = '', isSaving = false, isRefreshing = false, isConnected = false;
  var pendingWrite = null, revisionsByID = new Map(), selectedViewID = configuration.viewItemID;
  var projectViews = [], viewGeneration = 0, refreshGeneration = 0;
  const projectBoard = configuration.projectBoard || null;
  const pendingStorageKey = viewID => 'tractanda.pending.v4.' + (projectBoard ? 'project.' : 'view.') + viewID;
  const sessionStorageKey = 'tractanda.web-session';
  const browserStorageKey = 'tractanda.browser-session';
  var isSigningIn = false, resumeEditorAfterSignIn = false;
  const nativeCapability = 'https://tractanda.ai/ns/local-prototype/3';
  const typedText = value => ({type:'text',value});
  const fieldText = (fields, key) => fields[key]?.type === 'text' ? fields[key].value : '';

  function referenceElement(link) {
    const address = String(link.href || '');
    if (/^(javascript|data|vbscript):/i.test(address)) return element('span',{text:link.label});
    if (isLive && !/^https?:\/\//i.test(address)) {
      return element('span',{text:link.label + ' · project file: ' + address});
    }
    return element('a',{href:address,text:link.label,rel:'noreferrer'});
  }

  function updateConnectionState(message) {
    $('save-indicator').textContent = message || (isSaving ? 'Saving…' : pendingWrite ? 'Edit needs a retry' : isConnected ? 'Saved to Tractanda' : 'Not connected');
    $('save-indicator').classList.toggle('dirty',!!pendingWrite);
    $('retry-write').hidden = !pendingWrite || isSaving;
    $('refresh-board').disabled = isSaving || isRefreshing;
    $('refresh-projects').disabled = isSaving || isRefreshing;
    $('project-picker').disabled = isSaving || isRefreshing || !!pendingWrite || $('task-dialog').open;
    $('new-task').disabled = !isConnected || isSaving || !!pendingWrite;
    $('save-html').disabled = !isConnected || isSaving || !!pendingWrite;
    $('export-json').disabled = !isConnected || isSaving || !!pendingWrite;
    $('task-form').querySelector('[type=submit]').disabled = isSaving || !!pendingWrite;
    $('cancel-dialog').disabled = isSaving;
    $('close-dialog').disabled = isSaving;
    if (isLive) updateLearningControls();
  }

  function selectionIsCurrent(viewID, generation) {
    return selectedViewID === viewID && viewGeneration === generation;
  }

  function clearViewData(viewID) {
    data={tasks:[],originalSequence:[],recommendedSequence:[],revision:0,updatedAt:currentDate(),viewItemID:viewID,columns:[],filters:[]};
    revisionsByID.clear();dirty=!!pendingWrite;undoStack=[];changes=0;isConnected=false;
    learningCategoryID='';learningNotice='';learningItemPosition=0;learningSuggestionPosition=0;learningQueryState=null;
    if ($('learning-dialog').open) $('learning-dialog').close();
    $('search').value='';$('track-filter').value='all';$('scope-filter').value='all';render();
  }

  function restorePendingWrite(viewID) {
    if (pendingWrite || isSaving) return;
    try {
      const key=pendingStorageKey(viewID), legacyKey='tractanda.pending.v2.'+viewID;
      let encoded=sessionStorage.getItem(key);
      if (!encoded) {
        const legacy=sessionStorage.getItem(legacyKey);
        if (legacy) {
          const original=JSON.parse(legacy);
          // v2 journals predate a selection field.  Preserve the original request object and
          // operationID exactly; only annotate its ownership before atomically retiring v2.
          encoded=JSON.stringify({...original,viewItemID:viewID});
          sessionStorage.setItem(key,encoded);
          sessionStorage.removeItem(legacyKey);
        }
      }
      const write=JSON.parse(encoded||'null');
      if (write?.viewItemID===viewID && write.request?.operationID && (!write.method || ['TractandaItem/commit','TractandaLearning/feedback','TractandaLearning/settings'].includes(write.method))) {pendingWrite=write;dirty=true;}
    } catch {}
  }

  function replaceViewURL(viewID) {
    const url=new URL(location.href);url.searchParams.set(projectBoard?'project':'view',viewID);
    history.replaceState(null,'',url.pathname+url.search+url.hash);
  }

  function renderProjectViews() {
    if(!projectBoard)return;
    const picker=$('project-picker');picker.replaceChildren(...projectViews.map(view=>element('option',{value:view.id,text:view.name})));
    picker.value=selectedViewID;$('project-picker-label').hidden=false;$('refresh-projects').hidden=false;
    $('project-picker-label').firstChild.textContent=projectBoard?'Project ':'Project / view ';
    picker.setAttribute('aria-label',projectBoard?'Project':'Project or saved view');
  }

  function apiError(code, message, isDefinitive = false) {
    return Object.assign(new Error(message), {code,isDefinitive});
  }

  function keepAccessToken(token, remember = false) {
    accessToken=token;
    try {sessionStorage.setItem(sessionStorageKey,token);} catch {}
    if (remember) {try {localStorage.setItem(browserStorageKey,token);} catch {}}
  }

  function storedAccessToken() {
    try {const value=localStorage.getItem(browserStorageKey);if(value)return value;} catch {}
    try {return sessionStorage.getItem(sessionStorageKey)||'';} catch {return '';}
  }

  function forgetAccessToken(token = accessToken) {
    if (accessToken===token) accessToken='';
    for (const [storage,key] of [[()=>sessionStorage,sessionStorageKey],[()=>localStorage,browserStorageKey]]) {
      try {if(storage().getItem(key)===token)storage().removeItem(key);} catch {}
    }
  }

  function showSignIn(message = '') {
    isConnected=false;
    if ($('task-dialog').open && !pendingWrite) resumeEditorAfterSignIn=true;
    for (const dialog of document.querySelectorAll('dialog[open]')) dialog.close();
    document.body.classList.add('needs-login');
    document.title='Sign in · Tractanda';
    $('login-message').textContent=message;
    $('login-message').classList.remove('error');
    updateConnectionState();
  }

  function showWorkspace() {
    document.body.classList.remove('needs-login');
    document.title=(data.title||'Project board')+' · Tractanda';
    $('sign-out').hidden=false;
  }

  async function authenticationRequest(path, values = null) {
    const response=await fetch(path,{
      method:values===null?'GET':'POST',headers:{'Content-Type':'application/json',...(accessToken?{'Authorization':'Bearer '+accessToken}:{})},
      ...(values===null?{}:{body:JSON.stringify(values)}),credentials:'omit',cache:'no-store',signal:AbortSignal.timeout(18000)
    });
    const result=await response.json();
    if (!response.ok) throw apiError(result.code||'signInFailed',result.message||'Could not sign in. Try again.');
    return result;
  }

  async function signIn(event) {
    event.preventDefault();
    if(isSigningIn)return;
    isSigningIn=true;$('sign-in').disabled=true;$('sign-in').textContent='Signing in…';
    $('login-message').textContent='';$('login-message').classList.remove('error');
    try {
      const result=await authenticationRequest('/auth/login',{username:$('login-username').value.trim(),password:$('login-password').value});
      keepAccessToken(result.token,$('remember-browser').checked);
      $('login-password').value='';showWorkspace();
      await refreshLiveBoard();
    } catch(error) {
      $('login-password').value='';
      $('login-message').textContent=error.message||'The server could not be reached. Try again.';
      $('login-message').classList.add('error');$('login-password').focus();
    } finally {
      isSigningIn=false;$('sign-in').disabled=false;$('sign-in').textContent='Sign in';
      $('login-password').type='password';$('show-password').textContent='Show';
      $('show-password').setAttribute('aria-pressed','false');$('show-password').setAttribute('aria-label','Show password');
    }
  }

  async function signOut() {
    if (isSaving || pendingWrite) {toast('Resolve the pending edit before signing out. Retry same edit will confirm its outcome.',true);return;}
    $('sign-out').disabled=true;
    try {
      await authenticationRequest('/auth/logout',{});
      forgetAccessToken();revisionsByID.clear();data.tasks=[];render();
      showSignIn('You have signed out.');
    } catch(error) {
      if(error.code==='unauthorized'){forgetAccessToken();showSignIn('Your session has ended.');}
      else toast('Could not confirm sign-out. Try again when the server is available.',true);
    } finally {$('sign-out').disabled=false;}
  }

  async function nativeCall(method, argumentsObject = {}) {
    let response, envelope;
    const requestToken=accessToken;
    try {
      response = await fetch('/api', {
        method:'POST', headers:{'Content-Type':'application/json','Authorization':'Bearer '+requestToken},
        body:JSON.stringify({using:[nativeCapability],methodCalls:[[method,argumentsObject,'web']]}),
        signal:AbortSignal.timeout(18000), cache:'no-store', credentials:'omit'
      });
      envelope = await response.json();
    } catch {
      throw apiError('connectionLost','No confirmed response from the server. The edit may have committed; retry the same edit.');
    }
    if (!response.ok) {
      if (response.status===401 && accessToken===requestToken) {
        forgetAccessToken(requestToken);showSignIn(pendingWrite?'Sign in again to retry your retained edit.':'Your session has expired. Sign in again.');
      }
      throw apiError(envelope.code || 'httpError', envelope.message || 'The web connection failed.');
    }
    if (envelope.code) throw apiError(envelope.code,envelope.message,envelope.code !== 'responseTooLarge');
    const call = envelope.methodResponses?.[0];
    if (!call || call[2] !== 'web') throw apiError('invalidResponse','The server response could not be matched to this request.');
    if (call[0] === 'error') throw apiError(call[1].type,call[1].description,true);
    if (call[0] !== method) throw apiError('invalidResponse','The server returned an unexpected method.');
    return call[1];
  }

  function plain(value) {
    if (!value) return undefined;
    if (value.type==='list') return value.value.map(plain);
    if (value.type==='object') return Object.fromEntries(Object.entries(value.value).map(([k,v])=>[k,plain(v)]));
    if (value.type==='reference') return value.value.itemID;
    return value.value;
  }
  function categoryReferences(value) {
    if (!value) return [];
    if (value.type!=='list' || value.value.length>32 || value.value.some(v=>v.type!=='reference'||v.value.revisionID)) throw apiError('invalidView','Use current category references.');
    return [...new Set(value.value.map(v=>v.value.itemID))];
  }
  function projectTask(revision, categoryIDs, filterCategoryIDs, preferredScopes=[]) {
    const f=revision.fields, task=Object.fromEntries(Object.entries(f).filter(([k])=>['optional','rationale','originalPosition','requestedTitle','acceptance','evidence','activityNotes'].includes(k)).map(([k,v])=>[k,plain(v)]));
    Object.assign(task,{id:fieldText(f,'itemID'),revisionID:fieldText(f,'revisionID'),
      reference:(preferredScopes.slice().reverse().map(scope=>(plain(f.referenceLabels)||[]).find(l=>l.scope===scope)).find(Boolean)||(plain(f.referenceLabels)||[])[0])?.label||fieldText(f,'itemID').slice(0,8),title:fieldText(f,'subject'),summary:fieldText(f,'body'),updatedAt:f.modifiedAt.value,
      order:f.sortOrder?.value||0,categoryIDs,filterCategoryIDs,priority:fieldText(f,'priority'),owner:fieldText(f,'assignee'),kind:fieldText(f,'taskKind'),notes:fieldText(f,'workingNotes')});
    task.dependsOn=categoryReferences(f.dependencies);
    task.checklist=(plain(f.checklist)||[]).map(step=>{const result={...step,done:step.isComplete===true};delete result.isComplete;return result;});
    task.history=task.activityNotes||[];task.acceptance??=[];task.evidence??=[];
    return task;
  }
  function categoryOrder(revision) {
    const value=revision?.fields?.categoryOrder;
    return value?.type==='integer' ? value.value : 0;
  }
  function categoryGraph(revisions) {
    const categories=new Map(revisions.filter(r=>!r.fields.isDeleted?.value&&r.fields.selection).map(r=>[fieldText(r.fields,'itemID'),r]));
    const children=new Map();
    for(const [id,category] of categories) for(const parent of categoryReferences(category.fields.categoryParents)) {
      if(categories.has(parent)) children.set(parent,[...(children.get(parent)||[]),id]);
    }
    const compare=(left,right)=>categoryOrder(categories.get(left))-categoryOrder(categories.get(right))||fieldText(categories.get(left).fields,'subject').localeCompare(fieldText(categories.get(right).fields,'subject'))||left.localeCompare(right);
    for(const [id,values] of children) children.set(id,[...new Set(values)].sort(compare));
    return {categories,children};
  }
  function categoryDescendants(rootID, graph) {
    if(!graph.categories.has(rootID)) return [];
    const result=[],seen=new Set();
    function visit(id,path) {
      if(seen.has(id))return;seen.add(id);result.push({id,path});
      for(const child of graph.children.get(id)||[]) visit(child,[...path,fieldText(graph.categories.get(child).fields,'subject')||'Category']);
    }
    visit(rootID,[fieldText(graph.categories.get(rootID).fields,'subject')||'Category']);
    return result;
  }
  async function queryRevisions(argumentsObject, state) {
    const ids=[];
    for(let position=0;;) {
      const page=await nativeCall('TractandaItem/query',{...argumentsObject,position,limit:64});
      if(page.queryState!==state)return null;
      ids.push(...page.ids);position+=page.ids.length;
      if(position>=page.total)break;
      if(!page.ids.length)throw apiError('invalidResponse','An incomplete query page was empty.');
    }
    const revisions=[];
    for(let index=0;index<ids.length;index+=64) {
      const page=await nativeCall('TractandaItem/get',{ids:ids.slice(index,index+64)});
      if(page.state!==state||page.notFound.length)return null;
      revisions.push(...page.list);
    }
    return revisions;
  }
  async function projectGraph(state) {
    const revisions=await queryRevisions({expression:'selection == *'},state);
    return revisions===null?null:categoryGraph(revisions);
  }
  async function discoverProjects(viewID,generation) {
    const state=(await nativeCall('TractandaStore/info')).state;
    const graph=await projectGraph(state);
    if(!graph||!selectionIsCurrent(viewID,generation))return null;
    const root=projectBoard.projectRootID;
    if(!graph.categories.has(root))throw apiError('projectRootUnavailable','The project root category is unavailable.');
    const projects=categoryDescendants(root,graph).map(entry=>({id:entry.id,name:entry.id===root?'All projects':entry.path.join(' / '),path:entry.path}));
    if((await nativeCall('TractandaStore/info')).state!==state||!selectionIsCurrent(viewID,generation))return null;
    return projects;
  }
  async function readProjectBoard(projectID) {
    for(let attempt=0;attempt<3;attempt++) {
      const info=await nativeCall('TractandaStore/info');
      const graph=await projectGraph(info.state);
      if(!graph)continue;
      const projectRootID=projectBoard.projectRootID,statusRootID=projectBoard.statusRootID;
      const project=graph.categories.get(projectID),statusRoot=graph.categories.get(statusRootID);
      if(!project||!statusRoot||!categoryDescendants(projectRootID,graph).some(entry=>entry.id===projectID)) throw apiError('projectUnavailable','The selected project category is unavailable.');
      let statusEntries=categoryDescendants(statusRootID,graph).filter(entry=>entry.id!==statusRootID&&(graph.children.get(entry.id)||[]).length===0);
      if(!statusEntries.length)throw apiError('invalidStatusRoot','The status root needs at least one readable leaf category.');
      try {
        const preferred=categoryReferences(project.fields.viewDefinition?.value?.presentation?.value?.sections), available=new Map(statusEntries.map(entry=>[entry.id,entry]));
        const ordered=preferred.map(id=>available.get(id)).filter(Boolean), seen=new Set(ordered.map(entry=>entry.id));
        statusEntries=[...ordered,...statusEntries.filter(entry=>!seen.has(entry.id))];
      } catch { /* An unrelated/invalid optional view cannot make a category board unavailable. */ }
      const revisions=await queryRevisions({categoryPath:[projectID,statusRootID]},info.state);
      if(revisions===null)continue;
      const memberships=new Map();let changed=false;
      for(const status of statusEntries) {
        const matches=await queryRevisions({categoryPath:[projectID,status.id]},info.state);
        if(matches===null){changed=true;break;}
        for(const item of matches) {const id=fieldText(item.fields,'itemID');memberships.set(id,[...(memberships.get(id)||[]),status.id]);}
      }
      const filterIDs=categoryReferences(project.fields.filterCategories).filter(id=>graph.categories.has(id));
      const filters=new Map();
      for(const filterID of filterIDs) {
        const matches=await queryRevisions({categoryPath:[projectID,filterID]},info.state);
        if(matches===null){changed=true;break;}
        for(const item of matches) {const id=fieldText(item.fields,'itemID');filters.set(id,[...(filters.get(id)||[]),filterID]);}
      }
      if(changed||(await nativeCall('TractandaStore/info')).state!==info.state)continue;
      const statusIDs=new Set(statusEntries.map(entry=>entry.id));
      const reference=(category,key)=>{const id=category.fields[key]?.value?.itemID;return statusIDs.has(id)?id:undefined;};
      const defaultID=reference(project,'defaultCategory')||reference(statusRoot,'defaultCategory');
      const completionID=reference(project,'completionCategory')||reference(statusRoot,'completionCategory');
      const duplicateNames=new Set(statusEntries.map(entry=>entry.path.at(-1)).filter((name,index,names)=>names.indexOf(name)!==index));
      const retained=Object.fromEntries(Object.entries(project.fields).filter(([key])=>['maintenance','sequenceStatus','originalSequence','recommendedSequence','activity'].includes(key)).map(([key,value])=>[key,plain(value)]));
      const next={...retained,schemaVersion:3,projectID,projectRootID,statusRootID,serverState:info.state,title:fieldText(project.fields,'subject')||'Project',updatedAt:currentDate(),
        columns:statusEntries.map(entry=>({id:entry.id,name:duplicateNames.has(entry.path.at(-1))?entry.path.join(' / '):entry.path.at(-1)})),
        filters:filterIDs.map(id=>({id,name:fieldText(graph.categories.get(id).fields,'subject')||'Category'})),captureCategoryIDs:[projectID],
        defaultCategoryID:defaultID,completionCategoryID:completionID,originalSequence:[],recommendedSequence:[],
        tasks:revisions.map(revision=>projectTask(revision,memberships.get(fieldText(revision.fields,'itemID'))||[],filters.get(fieldText(revision.fields,'itemID'))||[],[projectID]))};
      return {data:next,revisions:new Map(revisions.map(r=>[fieldText(r.fields,'itemID'),r]))};
    }
    throw apiError('stateChanged','The project board changed during refresh. Try again; an open draft is kept.');
  }
  async function discoverProjectViews(viewID, generation) {
    return projectBoard ? discoverProjects(viewID,generation) : null;
  }

  async function readLiveBoard(viewID=selectedViewID) {
    if(projectBoard)return readProjectBoard(viewID);
    for (let attempt=0;attempt<3;attempt++) {
      const info=await nativeCall('TractandaStore/info');
      const result=await nativeCall('TractandaItem/get',{ids:[viewID]});
      const view=result.list[0], fields=view?.fields;
      if (!fields || fields.isDeleted?.value || !fields.viewDefinition) throw apiError('viewUnavailable','This saved view is unavailable.');
      if (result.state!==info.state) continue;
      const definition=fields.viewDefinition.value;
      const columnIDs=categoryReferences(definition.presentation?.value.sections);
      if (!columnIDs.length) throw apiError('invalidView','Choose category sections for this view first.');
      const filterIDs=categoryReferences(fields.filterCategories);
      const categoryResult=await nativeCall('TractandaItem/get',{ids:[...new Set([...columnIDs,...filterIDs])]});
      if (categoryResult.state!==info.state) continue;
      const categories=new Map(categoryResult.list.filter(r=>!r.fields.isDeleted?.value && r.fields.selection).map(r=>[fieldText(r.fields,'itemID'),r]));
      let hasChanged=false;
      async function idsFor(argumentsObject) {
        const ids=[];let position=0;
        while(true) {
          const page=await nativeCall('TractandaItem/query',{...argumentsObject,position,limit:64});
          if(page.queryState!==info.state){hasChanged=true;return [];}
          ids.push(...page.ids);position+=page.ids.length;
          if(position>=page.total)return ids;
          if(!page.ids.length)throw apiError('invalidResponse','An incomplete query page was empty.');
        }
      }
      const ids=await idsFor({viewID}), revisions=[];
      for(let index=0;index<ids.length;index+=64){
        const page=await nativeCall('TractandaItem/get',{ids:ids.slice(index,index+64)});
        if(page.state!==info.state||page.notFound.length){hasChanged=true;break;}
        revisions.push(...page.list);
      }
      const memberships=new Map(), filters=new Map();
      for(const id of columnIDs.filter(id=>categories.has(id)))for(const itemID of await idsFor({viewID,sectionID:id})) memberships.set(itemID,[...(memberships.get(itemID)||[]),id]);
      for(const id of filterIDs.filter(id=>categories.has(id))) {
        const args={categoryPath:[...new Set([...categoryReferences(definition.categoryPath),id])]};
        if(definition.expression)args.expression=plain(definition.expression);
        if(definition.text)args.text=plain(definition.text);
        if(definition.excludedCategoryIDs)args.excludedCategoryIDs=categoryReferences(definition.excludedCategoryIDs);
        for(const itemID of await idsFor(args))filters.set(itemID,[...(filters.get(itemID)||[]),id]);
      }
      if(hasChanged||(await nativeCall('TractandaStore/info')).state!==info.state)continue;
      const descriptors=ids=>ids.filter(id=>categories.has(id)).map(id=>({id,name:fieldText(categories.get(id).fields,'subject')}));
      const next=Object.fromEntries(Object.entries(fields).filter(([k])=>['maintenance','sequenceStatus','originalSequence','recommendedSequence','activity'].includes(k)).map(([k,v])=>[k,plain(v)]));
      Object.assign(next,{schemaVersion:2,viewItemID:viewID,viewRevisionID:fieldText(fields,'revisionID'),serverState:info.state,title:fieldText(fields,'subject'),
        updatedAt:currentDate(),columns:descriptors(columnIDs),filters:descriptors(filterIDs),captureCategoryIDs:categoryReferences(fields.captureCategories||definition.categoryPath),
        completionCategoryID:fields.completionCategory?.value.itemID,defaultCategoryID:fields.defaultCategory?.value.itemID,
        originalSequence:plain(fields.originalSequence)||[],recommendedSequence:plain(fields.recommendedSequence)||[],
        tasks:revisions.map(r=>projectTask(r,memberships.get(fieldText(r.fields,'itemID'))||[],filters.get(fieldText(r.fields,'itemID'))||[],categoryReferences(definition.categoryPath)))});
      return {data:next,revisions:new Map(revisions.map(r=>[fieldText(r.fields,'itemID'),r]))};
    }
    throw apiError('stateChanged','The view changed during refresh. Try again; an open draft is kept.');
  }

  async function refreshProjectViews() {
    if(!projectBoard)return false;
    const refreshID=++refreshGeneration;
    isRefreshing=true;updateConnectionState();
    const viewID=selectedViewID,generation=viewGeneration;
    try {
      const views=await discoverProjectViews(viewID,generation);
      if (!selectionIsCurrent(viewID,generation)) return false;
      if (!views || !selectionIsCurrent(viewID,generation)) return false;
      projectViews=views;renderProjectViews();
      if (!views.some(view=>view.id===viewID)) {
        clearViewData(viewID);isConnected=false;$('connection-message').textContent='This project / view is no longer available.';
        return false;
      }
      return true;
    } catch(error) {
      if (selectionIsCurrent(viewID,generation)) {$('connection-message').textContent=error.message;}
      return false;
    } finally {if(refreshID===refreshGeneration){isRefreshing=false;updateConnectionState();}}
  }

  async function refreshLiveBoard(force=false) {
    if (isRefreshing&&!force) return false;
    const refreshID=++refreshGeneration;
    isRefreshing=true;updateConnectionState();
    const viewID=selectedViewID,generation=viewGeneration;
    try {
      if(projectBoard) {
        // Discovery precedes the selected-board read.  A deleted bookmark can therefore clear
        // stale cards while still offering every readable replacement project.
        const views=await discoverProjectViews(viewID,generation);
        if(!selectionIsCurrent(viewID,generation))return false;
        if(views){projectViews=views;renderProjectViews();}
        if(!views||!views.some(view=>view.id===viewID)) {
          clearViewData(viewID);$('connection-message').textContent='This project is no longer available. Choose an available project.';
          return false;
        }
      }
      const refreshed=await readLiveBoard(viewID);
      if (!selectionIsCurrent(viewID,generation)) return false;
      data=refreshed.data;revisionsByID=refreshed.revisions;isConnected=true;
      render();showWorkspace();
      if(resumeEditorAfterSignIn && !pendingWrite){resumeEditorAfterSignIn=false;$('task-dialog').showModal();}
      $('connection-message').textContent=pendingWrite?'An edit needs a retry. Its original request is retained.':'Connected · changes are saved as item revisions';
      return true;
    } catch(error) {
      if (!selectionIsCurrent(viewID,generation)) return false;
      isConnected=false;clearViewData(viewID);$('connection-message').textContent=error.message;
      return false;
    } finally {if(refreshID===refreshGeneration){isRefreshing=false;updateConnectionState();}}
  }

  async function selectProjectView(viewID) {
    if(!projectBoard)return;
    if (viewID===selectedViewID) return;
    if (isSaving || pendingWrite || $('task-dialog').open) {
      $('project-picker').value=selectedViewID;
      toast('Resolve or cancel the current draft before changing projects.',true);return;
    }
    selectedViewID=viewID;viewGeneration++;clearViewData(viewID);replaceViewURL(viewID);
    restorePendingWrite(viewID);updateConnectionState();
    await refreshLiveBoard(true);
  }

  function makeLiveFields(candidate, baseRevision) {
    const base=baseRevision?.fields||{}, previous=baseRevision?byId(fieldText(base,'itemID')):null;
    const fields={subject:typedText(candidate.title),body:typedText(candidate.summary),priority:typedText(candidate.priority),assignee:typedText(candidate.owner),
      taskKind:typedText(candidate.kind),workingNotes:typedText(candidate.notes),sortOrder:{type:'integer',value:candidate.order}};
    fields.checklist={type:'list',value:candidate.checklist.map(step=>{
      const prior=(base.checklist?.value||[]).find(entry=>entry.value.id?.value===step.id)?.value||{};
      const value={...clone(prior),id:typedText(step.id),title:typedText(step.title),isComplete:{type:'boolean',value:step.done}};
      if(typeof step.source==='string')value.source=typedText(step.source);else delete value.source;
      return {type:'object',value};
    })};
    const overrides=clone(base.categoryOverrides?.value||{});
    if(!baseRevision)for(const id of data.captureCategoryIDs||[])overrides[id]=typedText('include');
    for(const [choices,before,after] of [[data.columns,baseRevision?(candidate.originalCategoryIDs||previous?.categoryIDs||[]):[],candidate.categoryIDs],[data.filters,baseRevision?(candidate.originalFilterCategoryIDs||previous?.filterCategoryIDs||[]):[],candidate.filterCategoryIDs]]) {
      for(const category of choices||[])if(after.includes(category.id)!==before.includes(category.id))overrides[category.id]=typedText(after.includes(category.id)?'include':'exclude');
    }
    fields.categoryOverrides={type:'object',value:overrides};
    if(!baseRevision)fields.dependencies={type:'list',value:[]};
    return Object.fromEntries(Object.entries(fields).filter(([key,value])=>JSON.stringify(base[key])!==JSON.stringify(value)));
  }

  function retainPendingWrite(write) {
    // This is a retry journal for one unconfirmed request, not an authoritative task database.
    sessionStorage.setItem(pendingStorageKey(write.viewItemID),JSON.stringify(write));
    pendingWrite=write;dirty=true;
  }
  function clearPendingWrite() {
    if (pendingWrite) sessionStorage.removeItem(pendingStorageKey(pendingWrite.viewItemID));pendingWrite=null;dirty=false;
  }

  async function saveLiveTask(candidate, baseRevision) {
    if (isSaving || pendingWrite) {toast('Resolve the pending edit before starting another.',true);return;}
    const changes=makeLiveFields(candidate,baseRevision);
    if (!Object.keys(changes).length) {$('task-dialog').close();toast('No changes to save.');return;}
    const request={action:baseRevision?'revise':'create',changes,unset:[],operationID:'web:'+crypto.randomUUID()};
    if (baseRevision) {request.itemID=fieldText(baseRevision.fields,'itemID');request.expectedRevisionID=fieldText(baseRevision.fields,'revisionID');}
    else request.classID='Item';
    try {retainPendingWrite({viewItemID:selectedViewID,request,candidate});}
    catch {toast('This browser could not retain the retry record. The edit has not been sent.',true);return;}
    await sendPendingWrite();
  }

  async function sendPendingWrite() {
    if (!pendingWrite || isSaving) return;
    const write=pendingWrite;
    if (write.viewItemID!==selectedViewID) {toast('Return to the project / view that owns this pending edit.',true);return;}
    const writeGeneration=viewGeneration;isSaving=true;updateConnectionState();
    $('connection-message').textContent='Saving to Tractanda…';
    try {
      const result=await nativeCall(write.method || 'TractandaItem/commit',write.request);
      if (!result.revision?.fields?.revisionID) throw apiError('invalidResponse','The commit response is incomplete; retry the same edit.');
      clearPendingWrite();$('task-dialog').close();
      const refreshed=await refreshLiveBoard();
      if (!refreshed) $('connection-message').textContent='The edit was saved. '+$('connection-message').textContent;
      toast(result.indexReady===false?'Saved; the index needs rebuilding before further queries.':result.replayed?'Original edit confirmed; no duplicate revision.':'Saved as a new item revision.');
      if (write.context==='learning') {
        learningCategoryID=write.categoryID || fieldText(result.revision.fields,'itemID');
        learningNotice='Saved. Train again when you are ready to use the updated examples.';
        await refreshLearningPanel();
      }
    } catch(error) {
      if (write.context==='learning') learningNotice=error.message;
      if (error.isDefinitive) {
        clearPendingWrite();
        if (error.code==='revisionConflict') {
          await refreshLiveBoard();
          if ($('task-dialog').open && write.candidate) {
            $('dialog-error').replaceChildren(element('p',{text:'This item changed while you were editing. Your draft is kept; review it before loading the latest version.'}));
            const current=byId(write.candidate.id);
            if (current) $('dialog-error').append(element('p',{text:'Current title: '+current.title+' · categories: '+current.categoryIDs.map(id=>data.columns.find(c=>c.id===id)?.name||'').join(', ')}),
              element('button',{type:'button',text:'Load latest and discard this draft',onclick:()=>openTask(write.candidate.id)}));
            $('dialog-error').scrollIntoView({block:'nearest'});
          }
          $('connection-message').textContent='The item changed; your stale edit was not applied.';
          toast('Revision conflict. Review the current item before making a new edit.',true);
          if (write.context==='learning') {
            learningNotice='The item changed. Your feedback was not applied. Review the latest item before trying again.';
            await refreshLearningPanel();
          }
        } else {
          $('connection-message').textContent=error.message;toast(error.message,true);
          if ($('task-dialog').open) {$('dialog-error').textContent=error.message;$('dialog-error').scrollIntoView({block:'nearest'});}
        }
      } else {
        $('connection-message').textContent=error.code==='unauthorized'?'Connect this session, then retry the retained edit.':'Edit outcome unconfirmed. Retry same edit will reuse its original operation ID.';
        toast(error.message,true);
      }
    } finally {if(selectionIsCurrent(write.viewItemID,writeGeneration)){isSaving=false;updateConnectionState();}}
  }

  function appendRevisionHistory(container,itemID) {
    if (!itemID) return;
    const section=element('section'),list=element('div',{class:'history-list'});
    const button=element('button',{type:'button',text:'Load revision history',onclick:async()=>{
      button.disabled=true;
      try {
        const response=await nativeCall('TractandaItem/history',{itemID,position:0,limit:30});
        list.replaceChildren(element('p',{text:'Showing '+response.list.length+' of '+response.total+' native revisions. Recorded activity notes above are separate.'}));
        for (const revision of response.list) {
          const fields=revision.fields;
          const detail=element('details',{},[element('summary',{text:fields.modifiedAt.value+' · '+fieldText(fields,'actor')+' · '+fieldText(fields,'subject')})]);
          const pre=element('pre',{text:JSON.stringify({revisionID:fieldText(fields,'revisionID'),categoryOverrides:plain(fields.categoryOverrides),subject:fieldText(fields,'subject'),body:fieldText(fields,'body'),workingNotes:fieldText(fields,'workingNotes'),checklist:fields.checklist?.value},null,2)});
          pre.style.whiteSpace='pre-wrap';pre.style.overflowWrap='anywhere';detail.append(pre);list.append(detail);
        }
      } catch(error) {list.textContent=error.message;}
      finally {button.disabled=false;}
    }});
    section.append(element('p',{class:'section-label',text:'Canonical item history'}),button,list);container.append(section);
  }

  async function startLiveClient() {
    $('connection-panel').hidden=false;$('undo-button').hidden=true;$('save-html').textContent='Export HTML';
    if(!projectBoard){$('project-picker-label').hidden=true;$('refresh-projects').hidden=true;}
    document.querySelector('.reference-nav').hidden=true;
    document.querySelector('.board-footer').lastElementChild.textContent='Changes are saved to Tractanda. Exports are offline snapshots.';
    document.querySelector('.dialog-actions .helper').textContent='One save creates one item revision.';
    document.querySelector('#task-form [type=submit]').textContent='Save to Tractanda';
    $('help-dialog').querySelector('.dialog-body').replaceChildren(
      element('p',{text:'This board reads and writes ordinary Tractanda items through the native API. Drag a card or open it to make one guarded edit. CLI edits appear after Refresh.'}),
      element('p',{text:'If a connection fails, Retry same edit reuses the retained request. A revision conflict keeps your draft for review. Refresh does not replace an open draft.'}),
      element('p',{text:'Sign in with the OS account running this web session. Keep this browser signed in also connects new tabs. Sign out ends that browser session; inactivity, session expiry or a server restart requires sign-in again. Passwords are not saved by Tractanda.'}),
      element('p',{},['Export HTML and Export JSON save snapshots. Editing a downloaded snapshot does not update the live server. ',element('a',{href:'/manual',text:'Open the Manual',target:'_blank',rel:'noreferrer'}),'.'])
    );
    $('task-dialog').addEventListener('cancel',event=>{if(isSaving)event.preventDefault();});
    $('refresh-board').addEventListener('click',()=>void refreshLiveBoard());
    $('refresh-projects').addEventListener('click',()=>void refreshProjectViews());
    $('project-picker').addEventListener('change',event=>void selectProjectView(event.target.value));
    $('retry-write').addEventListener('click',()=>void sendPendingWrite());
    startLearningClient();
    $('login-form').addEventListener('submit',event=>void signIn(event));
    $('sign-out').addEventListener('click',()=>void signOut());
    $('show-password').addEventListener('click',()=>{
      const showsPassword=$('login-password').type==='password';
      $('login-password').type=showsPassword?'text':'password';$('show-password').textContent=showsPassword?'Hide':'Show';
      $('show-password').setAttribute('aria-pressed',String(showsPassword));$('show-password').setAttribute('aria-label',showsPassword?'Hide password':'Show password');
    });
    $('token-form').addEventListener('submit',async event=>{
      event.preventDefault();keepAccessToken($('session-token').value.trim());$('session-token').value='';
      if(!await refreshLiveBoard()){$('login-message').textContent=$('connection-message').textContent;$('login-message').classList.add('error');}
    });
    window.addEventListener('storage',event=>{
      if(event.key!==browserStorageKey)return;
      if(event.newValue){keepAccessToken(event.newValue);if(!isSaving)void refreshLiveBoard();}
      else if(accessToken===event.oldValue){forgetAccessToken();showSignIn('This browser session has ended. Sign in again.');}
    });
    try {
      const supplied=new URLSearchParams(location.hash.slice(1)).get('token');
      const requestedView=new URLSearchParams(location.search).get(projectBoard?'project':'view');
      if (requestedView) selectedViewID=requestedView;
      accessToken=supplied||storedAccessToken();
      if (supplied) {keepAccessToken(supplied);history.replaceState(null,'',location.pathname+location.search);}
      restorePendingWrite(selectedViewID);
    } catch { $('connection-message').textContent='Session storage is unavailable. A save must retain its retry request before it is sent.'; }
    try {
      const profile=await authenticationRequest('/auth/session');
      $('login-username').value=profile.username||'';
      $('sign-in').disabled=!profile.isPasswordSignInAvailable;
      if(profile.isAuthenticated){showWorkspace();await refreshLiveBoard();}
      else {
        const hadSession=!!accessToken;forgetAccessToken();
        showSignIn(profile.isPasswordSignInAvailable?(hadSession?'Your session has expired. Sign in again.':''):'Password sign-in needs a named OS account. Use a launch link for this session.');
        if(profile.isPasswordSignInAvailable)$('login-password').focus();
      }
    } catch {showSignIn('The local server could not be reached. Reload this page to try again.');}
  }
