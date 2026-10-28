"""Protocol adapters. No simulated responses are used by the production UI."""
from __future__ import annotations
import json, os, queue, secrets, shutil, subprocess, threading, time
from pathlib import Path
from .brainstorm import TOOL, RULES

class LineProcess:
    def __init__(self,command,cwd,env=None):
        self.events=queue.Queue();self.pending={};self.lock=threading.RLock();self.serial=0;self.closed=False
        self.process=subprocess.Popen(command,cwd=cwd,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,bufsize=1)
        threading.Thread(target=self._read,daemon=True).start()
    def _read(self):
        try:
            for line in self.process.stdout:
                try:event=json.loads(line)
                except ValueError:continue
                with self.lock:
                    ident=event.get('id');pending=self.pending.get(ident)
                    if pending and ('method' not in event or event.get('type')=='response'):pending.put(event)
                    else:self.events.put(event)
        finally:
            with self.lock:
                for pending in self.pending.values():pending.put({'error':{'message':'Agent process disconnected'}})
            self.events.put({'disconnected':True})
    def send(self,value):
        with self.lock:
            if self.closed or self.process.poll() is not None:raise RuntimeError('Agent process is not running')
            self.process.stdin.write(json.dumps(value,ensure_ascii=False)+'\n');self.process.stdin.flush()
    def request(self,method,params=None,timeout=30,pi=False):
        with self.lock:
            self.serial+=1;ident=str(self.serial);pending=queue.Queue();self.pending[ident]=pending
        try:
            self.send({'id':ident,'type':method,**(params or {})} if pi else {'id':ident,'method':method,'params':params or {}})
            try:response=pending.get(timeout=timeout)
            except queue.Empty:raise RuntimeError('Agent request timed out: '+method)
            if response.get('error') or response.get('success') is False:raise RuntimeError(str(response.get('error','Agent request failed')))
            return response.get('data',{}) if pi else response.get('result',{})
        finally:
            with self.lock:self.pending.pop(ident,None)
    def close(self):
        with self.lock:
            if self.closed:return
            self.closed=True
            if self.process.poll() is None:self.process.terminate()
        try:self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:self.process.kill();self.process.wait(timeout=2)
        for stream in (self.process.stdin,self.process.stdout):
            if stream:
                try:stream.close()
                except OSError:pass


def executable(name,env):
    result=os.environ.get(env) or shutil.which(name)
    if not result:raise RuntimeError(name+' is not installed or not on PATH')
    return result

PI_FLAGS=['--mode','rpc','--no-session','--no-extensions','--no-skills','--no-prompt-templates','--no-context-files','--no-themes','--no-builtin-tools']

class PiRunner:
    def __init__(self,brain,room,member):
        self.on_progress=lambda text:None
        self.brain=brain;self.room=room;self.member=member;self.token=secrets.token_urlsafe(32)
        with brain.lock:brain.tool_tokens[self.token]=(room,member['id'])
        folder=brain.path(room)/'members'/member['id']
        settings=folder/'.pi'/'settings.json';settings.parent.mkdir(exist_ok=True)
        settings.write_text(json.dumps({'retry':{'enabled':False},'compaction':{'enabled':False}}))
        extension=Path(__file__).with_name('brainstorm_pi.ts')
        env=dict(os.environ,RESEARCHOS_WORKBENCH_URL=brain.origin+'/v2/brainstorm/tool',RESEARCHOS_WORKBENCH_TOKEN=self.token)
        self.rpc=LineProcess([executable('pi','RESEARCHOS_PI'),*PI_FLAGS,'--extension',str(extension),'--tools','research_workbench','--provider',member['provider'],'--model',member['model']],brain.path(room)/'members'/member['id'],env)
    def run(self,prompt,timeout,stop):
        state=self.rpc.request('get_state',pi=True)
        selected=state.get('model',{})
        if selected.get('id')!=self.member['model'] or selected.get('provider')!=self.member['provider']:raise RuntimeError('Pi selected a different model; refusing silent substitution')
        if self.member['effort']:
            levels=self.rpc.request('get_available_thinking_levels',pi=True).get('levels',[])
            if self.member['effort'] not in levels:raise ValueError('Unsupported thinking level: '+self.member['effort'])
            self.rpc.request('set_thinking_level',{'level':self.member['effort']},pi=True)
        self.rpc.request('prompt',{'message':prompt},pi=True)
        deadline=time.monotonic()+timeout;last='';error='';partial='';updated=0
        while time.monotonic()<deadline and not stop.is_set():
            try:event=self.rpc.events.get(timeout=0.15)
            except queue.Empty:continue
            if event.get('disconnected'):raise RuntimeError('Pi disconnected')
            if event.get('type')=='message_update':
                change=event.get('assistantMessageEvent',{})
                if change.get('type')=='text_delta':
                    partial+=change.get('delta','')
                    if time.monotonic()-updated>0.5:self.on_progress(partial);updated=time.monotonic()
            if event.get('type') in ('auto_retry_start','auto_compaction_start'):raise RuntimeError('Automatic retry or compaction stopped to preserve the discussion budget')
            if event.get('type')=='message_end' and event.get('message',{}).get('role')=='assistant':
                message=event['message'];text='\n'.join(x.get('text','') for x in message.get('content',[]) if x.get('type')=='text')
                if text:last=text
                if message.get('stopReason') in ('error','aborted'):error=message.get('errorMessage') or message['stopReason']
            if event.get('type')=='agent_settled':
                if error:raise RuntimeError(error)
                if not last:raise RuntimeError('Pi finished without a response')
                return last
        raise TimeoutError('Member stopped or exceeded its turn time budget')
    def steer(self,text):
        self.rpc.request('steer',{'message':'Additional user guidance: '+text},pi=True,timeout=5)
    def close(self):
        self.rpc.close()
        with self.brain.lock:self.brain.tool_tokens.pop(self.token,None)

class CodexRunner:
    def __init__(self,brain,room,member):
        self.on_progress=lambda text:None
        self.brain=brain;self.room=room;self.member=member
        self.thread_id=None;self.turn_id=None
        self.cwd=brain.path(room)/'members'/member['id']
        self.rpc=LineProcess([executable('codex','RESEARCHOS_CODEX'),'app-server','--listen','stdio://'],self.cwd)
    def run(self,prompt,timeout,stop):
        self.rpc.request('initialize',{'clientInfo':{'name':'research_os_brainstorm','title':'Research OS Brainstorm','version':'2.1.0'},'capabilities':{'experimentalApi':True}})
        self.rpc.send({'method':'initialized'})
        thread=self.rpc.request('thread/start',{'cwd':str(self.cwd),'model':self.member['model'],'sandbox':'read-only','approvalPolicy':'never','developerInstructions':RULES,'dynamicTools':[TOOL],'ephemeral':True,'config':{'web_search':'disabled','features.shell_tool':False,'features.multi_agent':False}})
        tid=thread['thread']['id'];params={'threadId':tid,'input':[{'type':'text','text':prompt}],'model':self.member['model'],'sandboxPolicy':{'type':'readOnly'}}
        if self.member['effort']:params['effort']=self.member['effort']
        self.thread_id=tid
        started=self.rpc.request('turn/start',params);self.turn_id=started.get('turn',{}).get('id')
        deadline=time.monotonic()+timeout;messages={};partial='';updated=0
        while time.monotonic()<deadline and not stop.is_set():
            try:event=self.rpc.events.get(timeout=0.15)
            except queue.Empty:continue
            if event.get('disconnected'):raise RuntimeError('Codex disconnected')
            method=event.get('method');p=event.get('params',{})
            if method=='item/agentMessage/delta':
                partial+=p.get('delta','')
                if time.monotonic()-updated>0.5:self.on_progress(partial);updated=time.monotonic()
            if 'id' in event and method=='item/tool/call':
                threading.Thread(target=self._tool,args=(event,),daemon=True).start()
            elif 'id' in event and method:
                self.rpc.send({'id':event['id'],'error':{'code':-32601,'message':'This discussion does not grant additional permissions; use the research workbench'}})
            elif method=='item/completed' and p.get('item',{}).get('type')=='agentMessage':
                item=p['item'];messages[item['id']]=item.get('text','')
            elif method=='turn/completed':
                turn=p.get('turn',{})
                if turn.get('status')!='completed':raise RuntimeError(str(turn.get('error') or turn.get('status')))
                if not messages:raise RuntimeError('Codex finished without a response')
                return list(messages.values())[-1]
        raise TimeoutError('Member stopped or exceeded its turn time budget')
    def _tool(self,event):
        try:
            p=event['params']
            if p.get('tool')!='research_workbench':raise ValueError('Unknown tool')
            value=self.brain.tool(self.room,self.member['id'],p.get('arguments',{}))
            output={'success':True,'contentItems':[{'type':'inputText','text':json.dumps(value,ensure_ascii=False)}]}
            if isinstance(value,dict) and 'image_url' in value:output={'success':True,'contentItems':[{'type':'inputText','text':value.get('citation','')},{'type':'inputImage','imageUrl':value['image_url']}]}
        except Exception as exc:output={'success':False,'contentItems':[{'type':'inputText','text':str(exc)}]}
        try:self.rpc.send({'id':event['id'],'result':output})
        except (RuntimeError,OSError):pass
    def steer(self,text):
        if not self.thread_id or not self.turn_id:raise RuntimeError('Turn is starting')
        self.rpc.request('turn/steer',{'threadId':self.thread_id,'expectedTurnId':self.turn_id,'input':[{'type':'text','text':'Additional user guidance: '+text}]},timeout=5)
    def close(self):self.rpc.close()


def catalog(brain,runtime,provider='',model=''):
    key=(runtime,provider,model)
    with brain.catalog_lock:
        cached=brain.catalog_cache.get(key)
        if cached and time.monotonic()-cached[0]<120:return cached[1]
        folder=brain.store.root/'brainstorm'/'catalog';folder.mkdir(parents=True,exist_ok=True)
        if runtime=='pi':
            rpc=LineProcess([executable('pi','RESEARCHOS_PI'),*PI_FLAGS],folder)
            try:
                if model:
                    rpc.request('set_model',{'provider':provider,'modelId':model},pi=True)
                    result={'levels':rpc.request('get_available_thinking_levels',pi=True).get('levels',[])}
                else:
                    models=rpc.request('get_available_models',pi=True).get('models',[])
                    result={'models':[{'id':m['id'],'name':m.get('name',m['id']),'provider':m['provider'],'runtime':'pi','reasoning':m.get('reasoning',False)} for m in models]}
            finally:rpc.close()
        elif runtime=='codex':
            rpc=LineProcess([executable('codex','RESEARCHOS_CODEX'),'app-server','--listen','stdio://'],folder)
            try:
                rpc.request('initialize',{'clientInfo':{'name':'research_os_brainstorm','version':'2.1.0'},'capabilities':{'experimentalApi':True}});rpc.send({'method':'initialized'})
                models=[];cursor=None
                while True:
                    page=rpc.request('model/list',{'cursor':cursor} if cursor else {});models.extend(page.get('data',[]));cursor=page.get('nextCursor')
                    if not cursor:break
                result={'models':[{'id':m['id'],'name':m.get('displayName',m['id']),'provider':'OpenAI','runtime':'codex','levels':[x['reasoningEffort'] for x in m.get('supportedReasoningEfforts',[])]} for m in models]}
            finally:rpc.close()
        else:raise ValueError('Unknown runtime')
        brain.catalog_cache[key]=(time.monotonic(),result);return result
