"""Shared verification fixture: ordinary categories, a saved view and arbitrary typed items."""
import uuid

def create_fixture(commit):
    def text(v):return {'type':'text','value':v}
    def ref(v):return {'type':'reference','value':{'itemID':v}}
    def refs(v):return {'type':'list','value':[ref(i) for i in v]}
    def create(name,fields,kind='NoteItem'):
        return commit({'action':'create','classID':kind,'changes':{'subject':text(name),**fields},'unset':[],'operationID':'fixture-'+uuid.uuid4().hex})['revision']['fields']['itemID']['value']
    def category(name,parents=[]):
        return create(name,{'selection':{'type':'object','value':{'language':text('tractanda.spotlight.v0'),'expression':text('itemID == ""')}},'categoryParents':refs(parents)})
    project=category('Fixture project');status=category('Status');group=category('Clients',[project])
    columns={k:category(name,[status]) for k,name in [('ready','Ready'),('doing','In progress'),('review','In review'),('planned','Planned'),('done','Completed')]}
    view=create('Disposable category board',{'viewDefinition':{'type':'object','value':{
        'language':text('tractanda.spotlight.v0'),'categoryPath':refs([project,status]),
        'presentation':{'type':'object','value':{'profile':text('tractanda.table.v0'),'sections':refs(columns.values())}}
    }},'captureCategories':refs([project]),'completionCategory':ref(columns['done']),'defaultCategory':ref(columns['planned']),'filterCategories':refs([group])})
    items={}
    for index,name in enumerate(['HTTP test first','HTTP test second']):
        assignments=[project,group,columns['ready' if index==0 else 'planned']]
        items[f'TEST-{index+1}']=create(name,{
            'referenceLabels':{'type':'list','value':[{'type':'object','value':{'scope':ref(project),'label':text(f'TEST-{index+1}')}}]},'body':text('Only a test fixture.'),
            'sortOrder':{'type':'integer','value':10*(index+1)},'priority':text('P1'),
            'categoryOverrides':{'type':'object','value':{id:text('include') for id in assignments}},
            'checklist':{'type':'list','value':[{'type':'object','value':{'id':text(f'step-{index}'),'title':text('Verify'),'isComplete':{'type':'boolean','value':False}}}]},
            'dependencies':refs([] if not index else [items['TEST-1']]),
            'foreignMetadata':{'type':'object','value':{'retain':{'type':'boolean','value':True},'text':text('ä')}}
        },kind='EmailMessageItem' if not index else 'NoteItem')
    return {'viewItemID':view,'itemIDs':items,'projectID':project,'statusID':status,'columns':columns,'groupID':group}
