  // This source is embedded in Kanban.html's existing closure for live and snapshot modes.
  var accessToken = '', isSaving = false, isRefreshing = false, isConnected = false;
  var pendingWrite = null, revisionsByID = new Map(), selectedViewID = configuration.viewItemID;
  var capturePlan = null, capturePreviewGeneration = 0, capturePreparing = false;
  var projectViews = [], viewGeneration = 0, refreshGeneration = 0;
  const projectBoard = configuration.projectBoard || null;
  const pendingStorageKey = viewID => 'tractanda.pending.v4.' + (projectBoard ? 'project.' : 'view.') + viewID;
  const sessionStorageKey = 'tractanda.web-session';
  const browserStorageKey = 'tractanda.browser-session';
  var isSigningIn = false, resumeEditorAfterSignIn = false;
  const nativeCapability = 'https://tractanda.ai/ns/jmap/1';
  const typedText = value => ({type:'text',value});
  const fieldText = (fields, key) => fields[key]?.type === 'text' ? fields[key].value : '';

  function showServerVersion(value) {
    const version=typeof value==='string'?value.trim():'';
    const label=$('server-version');
    label.textContent=version?'Server '+version:'';
    label.hidden=!version;
  }

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
    $('board-load-error').hidden=true;$('project-counts').hidden=false;
    $('search').value='';$('track-filter').value='all';render();
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
      const operationID=write?.request?.operationID||write?.request?.commitRequest?.operationID;
      if (write?.viewItemID===viewID && operationID && (!write.method || ['TractandaItem/commit','TractandaItem/commitCapture','TractandaLearning/feedback','TractandaLearning/settings'].includes(write.method))) {pendingWrite=write;dirty=true;}
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
    showServerVersion();
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

  async function nativeCalls(calls) {
    if(!calls.length||calls.length>8)throw apiError('invalidRequest','A native read batch must contain one to eight calls.');
    const requestToken=accessToken;
    let context=nativeCalls.context;
    if(!context || context.token!==requestToken) {
      context={token:requestToken,session:null,pending:null};nativeCalls.context=context;
    }
    const sessionScoped=new Set(['Core/echo','TractandaSession/get','TractandaAuth/createSession']);
    const needsAccount=method=>method.startsWith('Tractanda')&&!sessionScoped.has(method);
    async function exchange(entries) {
      const selectedAccountID=context.session?.accountID;
      let response, envelope;

      try {
        response = await fetch('/api', {
          method:'POST', headers:{'Content-Type':'application/json','Authorization':'Bearer '+requestToken},
          body:JSON.stringify({using:["urn:ietf:params:jmap:core",nativeCapability],methodCalls:entries.map(([method,args],index)=>[method,args,'web-'+index])}),
          signal:AbortSignal.timeout(Math.min(18000*entries.length,60000)), cache:'no-store', credentials:'omit'
        });
        envelope = await response.json();
      } catch {
        throw apiError('connectionLost','No confirmed response from the server. The edit may have committed; retry the same edit.');
      }
      if (typeof envelope.type==='string' && envelope.type.startsWith('urn:ietf:params:jmap:error:') && Number.isInteger(envelope.status) && envelope.status>=400 && envelope.status<=599) {
        const code=envelope.type.slice('urn:ietf:params:jmap:error:'.length);
        if (!['notJSON','notRequest','unknownCapability','limit'].includes(code)) throw apiError('invalidResponse','Unknown JMAP request problem.');
        throw apiError(code,'JMAP request rejected: '+code,true);
      }
      if (!response.ok) {
        if (response.status===401 && accessToken===requestToken) {
          forgetAccessToken(requestToken);showSignIn(pendingWrite?'Sign in again to retry your retained edit.':'Your session has expired. Sign in again.');
        }
        throw apiError(envelope.code || 'httpError', envelope.message || 'The web connection failed.');
      }
      if(typeof envelope.sessionState==='string' && context.session && envelope.sessionState!==context.session.state) context.session=null;
      if (envelope.code) throw apiError(envelope.code,envelope.message,envelope.code !== 'responseTooLarge');
      if(!Array.isArray(envelope.methodResponses)||envelope.methodResponses.length!==entries.length)throw apiError('invalidResponse','The server response could not be matched to this request.');
      return envelope.methodResponses.map((call,index)=>{
        if (!call || call[2] !== 'web-'+index) throw apiError('invalidResponse','The server response could not be matched to this request.');
        if (call[0] === 'error') {
          const definitive=['accountNotFound','accountReadOnly','accountNotSupportedByMethod','revisionConflict','stateConflict','forbidden','notFound','operationMismatch','invalidArguments','invalidRecord','invalidValue','invalidKey','invalidID','unknownClass','abstractClass','invalidClass','invalidView','invalidSelection','invalidHolder','invalidPermissions','invalidRole','invalidPendency','categoryCycle','invalidCategory','invalidReferenceLabel','invalidLearningSettings','invalidLearningFeedback','itemDeleted','invalidCapture','captureLimit','captureReviewRequired','captureChanged','dateOverrideConflict','unknownMethod','invalidResultReference'];
          throw apiError(call[1].type,call[1].description,definitive.includes(call[1].type));
        }
        if(['TractandaItem/get','TractandaRevision/get'].includes(call[0]) &&
           ['remainingIDs','oversizedIDs','unresolved'].some(key=>Object.hasOwn(call[1],key)))
          throw apiError('invalidResponse','Standard get returned unsupported continuation fields.');
        if(['TractandaItem/get','TractandaItem/getBounded','TractandaRevision/get','TractandaItem/history','TractandaItem/query'].includes(call[0]) && call[1]?.accountId!==(entries[index][1].accountId??selectedAccountID))
          throw apiError('invalidResponse','Read response account does not match this request.');
        if (call[0] !== entries[index][0]) throw apiError('invalidResponse','The server returned an unexpected method.');
        if (call[0]==='TractandaStore/info') showServerVersion(call[1]?.server?.version);
        return call[1];
      });
    }

    if(calls.some(([method])=>needsAccount(method)) && !context.session) {
      if(!context.pending) context.pending=(async()=>{
        const [document]=await exchange([['TractandaSession/get',{}]]);
        const accountID=document?.primaryAccounts?.[nativeCapability];
        if(document?.profile!=='tractanda.local-session.v1' || typeof document.state!=='string' || !document.state ||
           typeof accountID!=='string' || !accountID || !document.accounts?.[accountID]?.accountCapabilities?.[nativeCapability])
          throw apiError('invalidResponse','Invalid local session discovery.');
        context.session={accountID,state:document.state};
      })();
      try {await context.pending;} finally {context.pending=null;}
    }
    if(accessToken!==requestToken || nativeCalls.context!==context)
      throw apiError('contextChanged','Authentication changed; prepare the request again.');
    return exchange(calls.map(([method,args])=>[method,needsAccount(method)&&!Object.hasOwn(args,'accountId')&&!Object.hasOwn(args,'#accountId')?
      {...args,accountId:context.session.accountID}:args]));
  }

  async function nativeCall(method, argumentsObject = {}) {
    return (await nativeCalls([[method,argumentsObject]]))[0];
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
    const f=revision.fields, task=Object.fromEntries(Object.entries(f).filter(([k])=>['rationale','originalPosition','requestedTitle','acceptance','evidence','activityNotes'].includes(k)).map(([k,v])=>[k,plain(v)]));
    Object.assign(task,{id:fieldText(f,'itemID'),revisionID:fieldText(f,'revisionID'),
      reference:(preferredScopes.slice().reverse().map(scope=>(plain(f.referenceLabels)||[]).find(l=>l.scope===scope)).find(Boolean)||(plain(f.referenceLabels)||[])[0])?.label||fieldText(f,'itemID').slice(0,8),title:fieldText(f,'subject'),summary:fieldText(f,'body'),updatedAt:f.modifiedAt.value,
      categoryIDs,filterCategoryIDs,notes:fieldText(f,'workingNotes')});
    task.dependsOn=categoryReferences(f.dependencies);
    task.checklist=(plain(f.checklist)||[]).map(step=>{const result={...step,done:step.isComplete===true};delete result.isComplete;return result;});
    task.history=task.activityNotes||[];task.acceptance??=[];task.evidence??=[];
    return task;
  }
  function boardDefinition(project,root) {
    const own=plain(project.fields.viewDefinition)||{},defaults=plain(root?.fields.viewDefinition)||{};
    return {...own,sort:own.sort??defaults.sort??[],presentation:own.presentation??defaults.presentation};
  }
  async function readCategoryAxes(revisions,definition,state,at) {
    const roots=[];
    for(const entry of [...(definition?.presentation?.columns||[]),...(definition?.sort||[])]) {
      const id=entry?.categoryRootID;if(typeof id==='string'&&!roots.includes(id))roots.push(id);
    }
    if(roots.length>8)throw apiError('invalidView','Use at most eight category axes.');
    const memberships=new Map();let categoryAxes=[];
    if(!roots.length)return {categoryAxes,memberships};
    // An empty board still needs its axis choices for the first new item.
    const ids=revisions.length?revisions.map(r=>fieldText(r.fields,'itemID')):[roots[0]];
    for(let index=0;index<ids.length;index+=64) {
      const result=await nativeCall('TractandaCategory/memberships',{ids:ids.slice(index,index+64),categoryRootIDs:roots,at});
      if(result.state!==state||result.notFound?.length)throw apiError('stateChanged','The category graph changed during refresh.');
      for(const [id,values] of Object.entries(result.memberships||{}))memberships.set(id,values);
      if(index===0)categoryAxes=result.roots||[];
    }
    return {categoryAxes,memberships};
  }
  function categoryOrder(revision) {
    const value=revision?.fields?.categoryOrder;
    return value?.type==='integer' ? BigInt(value.value) : 0n;
  }
  function categoryGraph(revisions) {
    const categories=new Map(revisions.filter(r=>!r.fields.isDeleted?.value&&r.fields.selection).map(r=>[fieldText(r.fields,'itemID'),r]));
    const children=new Map();
    for(const [id,category] of categories) for(const parent of categoryReferences(category.fields.categoryParents)) {
      if(categories.has(parent)) children.set(parent,[...(children.get(parent)||[]),id]);
    }
    const compare=(left,right)=>{const a=categoryOrder(categories.get(left)),b=categoryOrder(categories.get(right));return (a<b?-1:a>b?1:0)||fieldText(categories.get(left).fields,'subject').localeCompare(fieldText(categories.get(right).fields,'subject'))||left.localeCompare(right);};
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
  function queryArguments(criteria) {
    const {expression,text,categoryPath,excludedCategoryIDs,viewID,sectionID,at,timeZone,sort,...paging}=criteria;
    const filter=Object.fromEntries(Object.entries({expression,text,categoryPath,excludedCategoryIDs,viewID,sectionID,at,timeZone}).filter(([,value])=>value!==undefined));
    return {filter,...paging,calculateTotal:true,...(sort?{sort:sort.map(entry=>entry.categoryRootID?
      {property:'categoryMembership',categoryRootId:entry.categoryRootID,isAscending:entry.isAscending??true}:
      {property:entry.property,isAscending:entry.isAscending??true,...(entry.collation?{collation:entry.collation}:{})})}:{})};
  }
  function unresolvedReadItems(page) {return page.list.filter(item=>item.resolution&&item.resolution.status!=='ready').map(item=>item.resolution);}
  function readyReadItems(page) {return page.list.filter(item=>!item.resolution||item.resolution.status==='ready');}

  async function queryIDGroups(argumentsList,state) {
    const positions=argumentsList.map(()=>0),groups=argumentsList.map(()=>[]),at=currentDate();
    let pending=argumentsList.map((_,index)=>index);
    while(pending.length) {
      const current=pending.slice(0,8);
      pending=pending.slice(8);
      const pages=await nativeCalls(current.map(index=>['TractandaItem/query',queryArguments({
        ...argumentsList[index],at:argumentsList[index].at||at,position:positions[index],limit:64
      })]));
      for(let offset=0;offset<current.length;offset++) {
        const index=current[offset],page=pages[offset];
        if(page.queryState!==state)return null;
        groups[index].push(...page.ids);positions[index]+=page.ids.length;
        if(positions[index]<page.total) {
          if(!page.ids.length)throw apiError('invalidResponse','An incomplete query page was empty.');
          pending.push(index);
        }
      }
    }
    return groups;
  }
  async function queryPageWithRevisions(argumentsObject,position,projection,cursor) {
    let limit=64;
    while(true) {
      try {
        return await nativeCalls([
          ['TractandaItem/query',queryArguments({...argumentsObject,...(cursor?{cursor}:{position}),limit})],
          ['TractandaItem/getBounded',{maxBytes:524288,'#ids':{resultOf:'web-0',name:'TractandaItem/query',path:'/ids'},...projection}]
        ]);
      } catch(error) {
        if(error.code!=='responseTooLarge'||limit===1)throw error;
        limit=Math.max(1,Math.floor(limit/2));
      }
    }
  }
  async function queryRevisions(argumentsObject, state, properties) {
    const at=argumentsObject.at||currentDate(),revisions=[],unresolved=[],unhydratedIDs=[];let cursor=null,conflictsAvailable=false,completeness='complete';
    for(let position=0;;) {
      // The get uses this request's query IDs, so each page is coherent and keeps
      // full editor content without the server's replay receipt.
      const projection=properties?{fieldProperties:properties}:{projection:'content'};
      let pair;
      try { pair=await queryPageWithRevisions({...argumentsObject,at},position,projection,cursor); }
      catch(error) {
        if(!cursor||!['invalidCursor','unsupportedCursor'].includes(error.code))throw error;
        cursor=null;
        pair=await queryPageWithRevisions({...argumentsObject,at},position,projection,null);
      }
      const [query,page]=pair;
      if(query.queryState!==state||page.state!==state||page.notFound.length)return null;
      const pageUnresolved=unresolvedReadItems(page);
      const classified=[...page.list.map(item=>item.id),...(page.remainingIDs||[]),...(page.oversizedIDs||[])];
      if(new Set(classified).size!==classified.length||classified.length!==query.ids.length||query.ids.some(id=>!classified.includes(id)))
        throw apiError('invalidResponse','The server omitted or repeated item projection results.');
      revisions.push(...readyReadItems(page));unresolved.push(...pageUnresolved);unhydratedIDs.push(...(page.remainingIDs||[]),...(page.oversizedIDs||[]));
      conflictsAvailable=conflictsAvailable||!!query.conflictsAvailable||pageUnresolved.length>0;
      if(query.completeness==='unresolvedItems'||pageUnresolved.length)completeness='unresolvedItems';
      position=query.position+query.ids.length;cursor=query.nextCursor||null;
      if(position>=query.total)return {revisions,unresolved,unhydratedIDs,conflictsAvailable,completeness};
      if(!query.ids.length)throw apiError('invalidResponse','An incomplete query page was empty.');
    }
  }
  async function projectGraph(state) {
    const result=await queryRevisions({expression:'selection == *'},state,[
      'subject','isDeleted','selection','categoryParents','categoryOrder','viewDefinition',
      'filterCategories','defaultCategory','completionCategory','maintenance','sequenceStatus',
      'originalSequence','recommendedSequence','activity'
    ]);
    if(result===null)return null;
    if(result.unresolved.length)throw Object.assign(apiError('itemUnresolved','A category could not be validated for the current board.'),{projectionNotice:true});
    return categoryGraph(result.revisions);
  }
  async function discoverProjects(viewID,generation,snapshot) {
    const state=(await nativeCall('TractandaStore/info')).state;
    const graph=await projectGraph(state);
    if(!graph||!selectionIsCurrent(viewID,generation))return null;
    const root=projectBoard.projectRootID;
    if(!graph.categories.has(root))throw apiError('projectRootUnavailable','The project root category is unavailable.');
    const projects=categoryDescendants(root,graph).map(entry=>({id:entry.id,name:entry.id===root?'All projects':entry.path.join(' / '),path:entry.path}));
    if((await nativeCall('TractandaStore/info')).state!==state||!selectionIsCurrent(viewID,generation))return null;
    // This snapshot belongs to one refresh, never a later login or selection.
    if(snapshot)Object.assign(snapshot,{state,graph});
    return projects;
  }
  async function readProjectBoard(projectID,snapshot) {
    for(let attempt=0;attempt<3;attempt++) {
      const info=await nativeCall('TractandaStore/info'),at=currentDate();
      const graph=snapshot?.state===info.state?snapshot.graph:await projectGraph(info.state);
      if(!graph)continue;
      const projectRootID=projectBoard.projectRootID,statusRootID=projectBoard.statusRootID;
      const project=graph.categories.get(projectID),statusRoot=graph.categories.get(statusRootID);
      if(!project||!statusRoot||!categoryDescendants(projectRootID,graph).some(entry=>entry.id===projectID)) throw apiError('projectUnavailable','The selected project category is unavailable.');
      let statusEntries=categoryDescendants(statusRootID,graph).filter(entry=>entry.id!==statusRootID&&(graph.children.get(entry.id)||[]).length===0);
      if(!statusEntries.length)throw apiError('invalidStatusRoot','The status root needs at least one readable leaf category.');
      const definition=boardDefinition(project,graph.categories.get(projectRootID));
      try {
        const preferred=(definition.presentation?.sections||[]), available=new Map(statusEntries.map(entry=>[entry.id,entry]));
        const ordered=preferred.map(id=>available.get(id)).filter(Boolean), seen=new Set(ordered.map(entry=>entry.id));
        statusEntries=[...ordered,...statusEntries.filter(entry=>!seen.has(entry.id))];
      } catch { /* An unrelated/invalid optional view cannot make a category board unavailable. */ }
      const viewSort=definition.sort;
      const query=await queryRevisions({at,categoryPath:[projectID,statusRootID],...(viewSort.length?{sort:viewSort}:{})},info.state);
      if(query===null)continue;
      const revisions=query.revisions;
      const memberships=new Map();
      const filterIDs=categoryReferences(project.fields.filterCategories).filter(id=>graph.categories.has(id));
      const filters=new Map();
      const membershipIDs=[...statusEntries.map(status=>status.id),...filterIDs];
      const membershipGroups=await queryIDGroups(membershipIDs.map(id=>({at,categoryPath:[projectID,id]})),info.state);
      if(membershipGroups===null)continue;
      membershipGroups.forEach((matches,index)=>{
        const map=index<statusEntries.length?memberships:filters,id=membershipIDs[index];
        for(const itemID of matches)map.set(itemID,[...(map.get(itemID)||[]),id]);
      });
      if((await nativeCall('TractandaStore/info')).state!==info.state)continue;
      const axes=await readCategoryAxes(revisions,definition,info.state,at);
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
        categoryAxes:axes.categoryAxes,
        tasks:revisions.map(revision=>{const task=projectTask(revision,memberships.get(fieldText(revision.fields,'itemID'))||[],filters.get(fieldText(revision.fields,'itemID'))||[],[projectID]);task.axisCategoryIDs=axes.memberships.get(task.id)||{};return task;})};
      return {data:next,revisions:new Map(revisions.map(r=>[fieldText(r.fields,'itemID'),r])),projectionNotice:query.completeness==='unresolvedItems'||query.conflictsAvailable||query.unhydratedIDs.length>0,unhydratedIDs:query.unhydratedIDs};
    }
    throw apiError('stateChanged','The project board changed during refresh. Try again; an open draft is kept.');
  }
  async function discoverProjectViews(viewID, generation, snapshot) {
    return projectBoard ? discoverProjects(viewID,generation,snapshot) : null;
  }

  async function readLiveBoard(viewID=selectedViewID,snapshot) {
    if(projectBoard)return readProjectBoard(viewID,snapshot);
    for (let attempt=0;attempt<3;attempt++) {
      const info=await nativeCall('TractandaStore/info'),at=currentDate();
      const result=await nativeCall('TractandaItem/get',{ids:[viewID]});
      if(unresolvedReadItems(result).length)throw apiError('itemUnresolved','This saved view needs projection review.');
      if((result.remainingIDs||[]).length||(result.oversizedIDs||[]).length)throw apiError('viewUnavailable','This saved view could not be completely loaded.');
      const view=readyReadItems(result)[0], fields=view?.fields;
      if (!fields || fields.isDeleted?.value || !fields.viewDefinition) throw apiError('viewUnavailable','This saved view is unavailable.');
      if (result.state!==info.state) continue;
      const definition=fields.viewDefinition.value;
      const columnIDs=categoryReferences(definition.presentation?.value.sections);
      if (!columnIDs.length) throw apiError('invalidView','Choose category sections for this view first.');
      const filterIDs=categoryReferences(fields.filterCategories);
      const categoryResult=await nativeCall('TractandaItem/get',{ids:[...new Set([...columnIDs,...filterIDs])]});
      if (categoryResult.state!==info.state) continue;
      const requiredCategories=[...new Set([...columnIDs,...filterIDs])];
      if(unresolvedReadItems(categoryResult).length)throw apiError('itemUnresolved','A saved-view section or filter category needs review.');
      if((categoryResult.remainingIDs||[]).length||(categoryResult.oversizedIDs||[]).length)
        throw apiError('categoryUnavailable','The saved-view categories could not be completely loaded. Retry this board refresh.');
      if((categoryResult.notFound||[]).length)throw apiError('categoryUnavailable','A required saved-view category is unavailable.');
      const categories=new Map(readyReadItems(categoryResult).filter(r=>!r.fields.isDeleted?.value && r.fields.selection).map(r=>[fieldText(r.fields,'itemID'),r]));
      if(requiredCategories.some(id=>!categories.has(id)))throw apiError('categoryUnavailable','The complete saved-view category definition is unavailable.');
      let hasChanged=false,projectionNotice=false;
      const unhydratedIDs=[];
      const revisions=[];
      for(let position=0;;){
        const [query,page]=await queryPageWithRevisions({viewID,at},position,{projection:'content'});
        if(query.queryState!==info.state||page.state!==info.state||page.notFound.length){hasChanged=true;break;}
        const unresolved=unresolvedReadItems(page);
        const classified=[...page.list.map(item=>item.id),...(page.remainingIDs||[]),...(page.oversizedIDs||[])];
        if(new Set(classified).size!==classified.length||classified.length!==query.ids.length||query.ids.some(id=>!classified.includes(id)))
          throw apiError('invalidResponse','The server omitted or repeated item projection results.');
        revisions.push(...readyReadItems(page));unhydratedIDs.push(...(page.remainingIDs||[]),...(page.oversizedIDs||[]));
        projectionNotice=projectionNotice||unresolved.length>0||query.completeness==='unresolvedItems'||!!query.conflictsAvailable||unhydratedIDs.length>0;position=query.position+query.ids.length;
        if(position>=query.total)break;
        if(!query.ids.length)throw apiError('invalidResponse','An incomplete query page was empty.');
      }
      const memberships=new Map(), filters=new Map();
      const visibleColumns=columnIDs.filter(id=>categories.has(id)),visibleFilters=filterIDs.filter(id=>categories.has(id));
      const membershipQueries=visibleColumns.map(id=>({viewID,sectionID:id}));
      for(const id of visibleFilters) {
        const args={categoryPath:[...new Set([...categoryReferences(definition.categoryPath),id])]};
        if(definition.expression)args.expression=plain(definition.expression);
        if(definition.text)args.text=plain(definition.text);
        if(definition.excludedCategoryIDs)args.excludedCategoryIDs=categoryReferences(definition.excludedCategoryIDs);
        membershipQueries.push(args);
      }
      const membershipGroups=await queryIDGroups(membershipQueries.map(args=>({...args,at})),info.state);
      if(membershipGroups===null)continue;
      membershipGroups.forEach((matches,index)=>{
        const map=index<visibleColumns.length?memberships:filters;
        const categoryID=index<visibleColumns.length?visibleColumns[index]:visibleFilters[index-visibleColumns.length];
        for(const itemID of matches)map.set(itemID,[...(map.get(itemID)||[]),categoryID]);
      });
      if(hasChanged||(await nativeCall('TractandaStore/info')).state!==info.state)continue;
      const axes=await readCategoryAxes(revisions,plain(fields.viewDefinition),info.state,at);
      const descriptors=ids=>ids.filter(id=>categories.has(id)).map(id=>({id,name:fieldText(categories.get(id).fields,'subject')}));
      const next=Object.fromEntries(Object.entries(fields).filter(([k])=>['maintenance','sequenceStatus','originalSequence','recommendedSequence','activity'].includes(k)).map(([k,v])=>[k,plain(v)]));
      Object.assign(next,{schemaVersion:3,categoryAxes:axes.categoryAxes,viewItemID:viewID,viewRevisionID:fieldText(fields,'revisionID'),serverState:info.state,title:fieldText(fields,'subject'),
        updatedAt:currentDate(),columns:descriptors(columnIDs),filters:descriptors(filterIDs),captureCategoryIDs:categoryReferences(fields.captureCategories||definition.categoryPath),
        completionCategoryID:fields.completionCategory?.value.itemID,defaultCategoryID:fields.defaultCategory?.value.itemID,
        originalSequence:plain(fields.originalSequence)||[],recommendedSequence:plain(fields.recommendedSequence)||[],
        tasks:revisions.map(r=>{const task=projectTask(r,memberships.get(fieldText(r.fields,'itemID'))||[],filters.get(fieldText(r.fields,'itemID'))||[],categoryReferences(definition.categoryPath));task.axisCategoryIDs=axes.memberships.get(task.id)||{};return task;})});
      return {data:next,revisions:new Map(revisions.map(r=>[fieldText(r.fields,'itemID'),r])),projectionNotice,unhydratedIDs};
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
    const viewID=selectedViewID,generation=viewGeneration,snapshot={};
    try {
      if(projectBoard) {
        // Discovery precedes the selected-board read.  A deleted bookmark can therefore clear
        // stale cards while still offering every readable replacement project.
        const views=await discoverProjectViews(viewID,generation,snapshot);
        if(!selectionIsCurrent(viewID,generation))return false;
        if(views){projectViews=views;renderProjectViews();}
        if(!views||!views.some(view=>view.id===viewID)) {
          clearViewData(viewID);$('connection-message').textContent='This project is no longer available. Choose an available project.';
          return false;
        }
      }
      const refreshed=await readLiveBoard(viewID,snapshot);
      if (!selectionIsCurrent(viewID,generation)) return false;
      data=refreshed.data;revisionsByID=refreshed.revisions;isConnected=true;
      $('board-load-error').hidden=true;$('project-counts').hidden=false;
      render();showWorkspace();
      if(resumeEditorAfterSignIn && !pendingWrite){resumeEditorAfterSignIn=false;$('task-dialog').showModal();}
      $('connection-message').textContent=refreshed.unhydratedIDs?.length?'Some queried items could not be loaded; this board is partial. Retry refresh.':refreshed.projectionNotice?'Some accessible items need review; current readable results remain available. Use item-state/conflicts for details.':pendingWrite?'An edit needs a retry. Its original request is retained.':'Connected · changes are saved as item revisions';
      return true;
    } catch(error) {
      if (!selectionIsCurrent(viewID,generation)) return false;
      if(error.code==='itemUnresolved') {
        clearViewData(viewID);
        isConnected=false;
        $('board-load-error').textContent='Could not validate this board because its view or a category needs review. No old board rows are shown.';
        $('board-load-error').hidden=false;$('project-counts').hidden=true;$('filter-count').textContent='Board unavailable';
        $('connection-message').textContent='The view or a category needs review; no current board rows are shown. Use item-state/conflicts for details.';
        return false;
      }
      isConnected=false;clearViewData(viewID);
      const message='Could not load this board: '+(error.message||'The server read failed.');
      $('board-load-error').textContent=message;$('board-load-error').hidden=false;
      $('project-counts').hidden=true;$('filter-count').textContent='Board unavailable';
      $('connection-message').textContent=message;
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
    const fields={subject:typedText(candidate.title)};
    for(const [key,value] of [['body',candidate.summary],['workingNotes',candidate.notes]]) {
      if(typeof value==='string'&&value.length) fields[key]=typedText(value);
    }
    if((base.checklist?.value||[]).length||(candidate.checklist||[]).length)fields.checklist={type:'list',value:(candidate.checklist||[]).map(step=>{
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
    for(const axis of data.categoryAxes||[]) {
      const before=baseRevision?(candidate.originalAxisCategoryIDs?.[axis.id]||previous?.axisCategoryIDs?.[axis.id]||[]):[];
      const after=candidate.axisCategoryIDs?.[axis.id]||[];
      for(const choice of axis.children?.length?axis.children:[axis])if(after.includes(choice.id)!==before.includes(choice.id))overrides[choice.id]=typedText(after.includes(choice.id)?'include':'exclude');
    }
    if(JSON.stringify(overrides)!==JSON.stringify(base.categoryOverrides?.value||{}))fields.categoryOverrides={type:'object',value:overrides};
    return Object.fromEntries(Object.entries(fields).filter(([key,value])=>JSON.stringify(base[key])!==JSON.stringify(value)));
  }

  function makeLiveEdit(candidate, baseRevision) {
    const base=baseRevision?.fields||{};
    const unset=[];
    for(const [key,value] of [['body',candidate.summary],['workingNotes',candidate.notes]]) {
      // Only an actual clear of displayed text removes a key. An untouched
      // absent/explicit-empty value or an undisplayed non-text property survives.
      if(value===''&&base[key]?.type==='text'&&base[key].value.length)unset.push(key);
    }
    return {changes:makeLiveFields(candidate,baseRevision),unset};
  }

  function liveRequest(candidate, baseRevision) {
    const {changes,unset}=makeLiveEdit(candidate,baseRevision);
    const request={action:baseRevision?'revise':'create',changes,unset,operationID:'web:'+crypto.randomUUID()};
    if (baseRevision) {request.itemID=fieldText(baseRevision.fields,'itemID');request.expectedRevisionID=fieldText(baseRevision.fields,'revisionID');}
    else request.classID='Item';
    return request;
  }

  function invalidateCapturePreview() {
    capturePreviewGeneration++;capturePlan=null;
    const preview=$('capture-preview');
    if(preview){preview.hidden=true;preview.replaceChildren();}
  }

  function captureCategoryLabel(id) {
    const categories=[...columns(),...filters(),...(data.categoryAxes||[]).flatMap(axis=>[axis,...(axis.children||[])])];
    return categories.find(category=>category.id===id)?.name||id;
  }

  function captureCanCommit(plan) { return !!plan && (plan.issues||[]).length===0; }

  function renderCapturePreview(plan) {
    const preview=$('capture-preview');preview.replaceChildren();preview.hidden=false;
    for(const mention of plan.mentions||[]) {
      const detail=mention.categoryID?captureCategoryLabel(mention.categoryID):
        (mention.candidates||[]).map(captureCategoryLabel).join(', ');
      let line=mention.token+(detail?' → '+detail:'');
      if(mention.reusedBinding&&mention.dateProperty&&mention.dateValue)line+=' · Already captured; date unchanged';
      else if(mention.dateProperty&&mention.dateValue)line+=' · '+mention.dateProperty+' = '+mention.dateValue;
      preview.append(element('p',{text:line}));
    }
    for(const issue of plan.issues||[])preview.append(element('p',{class:'capture-issue',text:issue.token+': '+issue.message}));
    if(!(plan.mentions||[]).length&&!(plan.issues||[]).length)preview.append(element('p',{text:'No category hashtags found.'}));
    preview.dataset.canCommit=String(captureCanCommit(plan));
  }

  async function previewLiveCapture() {
    if(!isLive||capturePreparing||isSaving||pendingWrite)return;
    if(!$('interpret-hashtags').checked){$('capture-preview').hidden=false;$('capture-preview').textContent='Enable “Interpret #categories” to preview capture.';return;}
    const candidate=readLiveDraftFromForm();
    const error=completionError(candidate);if(error){$('dialog-error').textContent=error;return;}
    const generation=++capturePreviewGeneration;capturePlan=null;capturePreparing=true;
    $('preview-capture').disabled=true;$('capture-preview').hidden=false;$('capture-preview').textContent='Preparing capture preview…';
    try {
      const plan=await nativeCall('TractandaItem/prepareCapture',{request:liveRequest(candidate,editingBase)});
      if(generation!==capturePreviewGeneration||!$('task-dialog').open)return;
      capturePlan=plan;renderCapturePreview(plan);
    } catch(error) {
      if(generation===capturePreviewGeneration){$('capture-preview').hidden=false;$('capture-preview').textContent=error.message||'Could not prepare the capture preview.';}
    } finally {capturePreparing=false;$('preview-capture').disabled=false;}
  }

  function retainPendingWrite(write) {
    // This is a retry journal for one unconfirmed request, not an authoritative task database.
    sessionStorage.setItem(pendingStorageKey(write.viewItemID),JSON.stringify(write));
    pendingWrite=write;dirty=true;
  }
  function clearPendingWrite() {
    if (pendingWrite) sessionStorage.removeItem(pendingStorageKey(pendingWrite.viewItemID));pendingWrite=null;dirty=false;
  }

  async function saveLiveTask(candidate, baseRevision, preparedCapture = null) {
    if (isSaving || pendingWrite) {toast('Resolve the pending edit before starting another.',true);return;}
    const request=preparedCapture||liveRequest(candidate,baseRevision);
    const method=preparedCapture?'TractandaItem/commitCapture':'TractandaItem/commit';
    if(!preparedCapture&&!Object.keys(request.changes).length&&!request.unset.length) {$('task-dialog').close();toast('No changes to save.');return;}
    try {retainPendingWrite({viewItemID:selectedViewID,method,request,candidate});}
    catch {toast('This browser could not retain the retry record. The edit has not been sent.',true);return;}
    await sendPendingWrite();
  }

  async function sendPendingWrite() {
    if (!pendingWrite || isSaving) return;
    const write=pendingWrite;
    if (write.viewItemID!==selectedViewID) {toast('Return to the project / view that owns this pending edit.',true);return;}
    const writeGeneration=viewGeneration;let confirmed=false;isSaving=true;updateConnectionState();
    $('connection-message').textContent='Saving to Tractanda…';
    try {
      const result=write.confirmation || await nativeCall(write.method || 'TractandaItem/commit',write.request);
      const intent=write.request.commitRequest||write.request;
      if (!result.itemId || !result.revisionId || result.operationId!==intent.operationID ||
          (!['create','copy'].includes(intent.action) && result.itemId!==(intent.itemID||intent.categoryID)) ||
          !Array.isArray(result.diagnostics) || result.diagnostics.some(code=>!['indexDelayed','checkpointPending','additionalDiagnostics'].includes(code)))
        throw apiError('invalidResponse','The save receipt does not match this edit; retry the same intent.');
      confirmed=true;
      write.confirmation=result;
      sessionStorage.setItem(pendingStorageKey(write.viewItemID),JSON.stringify(write));
      clearPendingWrite();
      if (!selectionIsCurrent(write.viewItemID,writeGeneration)) return;
      $('task-dialog').close();
      const refreshed=await refreshLiveBoard();
      if (!refreshed) $('connection-message').textContent='The edit was saved. '+$('connection-message').textContent;
      toast(result.indexReady===false?'Saved; the index needs rebuilding before further queries.':result.replayed?'Original edit confirmed; no duplicate revision.':'Saved as a new item revision.');
      if (write.context==='learning') {
        learningCategoryID=write.categoryID || result.itemId;
        learningNotice='Saved. Train again when you are ready to use the updated examples.';
        await refreshLearningPanel();
      }
    } catch(error) {
      if (confirmed) {
        $('connection-message').textContent='Saved. Refresh or local recovery cleanup failed: '+error.message;
        toast('The edit was saved. '+error.message,true);
        return;
      }
      if (write.context==='learning') learningNotice=error.message;
      if (error.isDefinitive) {
        clearPendingWrite();
        if (write.method==='TractandaItem/commitCapture') invalidateCapturePreview();
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
