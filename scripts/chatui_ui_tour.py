#!/usr/bin/env python3
"""Refs: book_prefers_reproducible_ui_examples; named_ui_scenarios_are_keyboard_and_braille_first.
Named real-DOM captures, semantic keyboard navigation and shareable accessibility evidence.
Only the owning disposable test server is supplied by chatui_application_test.py.
"""
import base64
import os
from datetime import datetime, timezone
import hashlib
import json
import shutil
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
FINAL=ROOT/'book/assets/ui-tour'
# Captures are staged and published only when the whole tour succeeds, so a
# failed run never leaves screenshots that disagree with the manifest.
OUT=FINAL/'.staging'
INPUTS=['ui/src/main.tsx','assets/chatui.css','LeanFM/ChatUI/Server.lean','LeanFM/ChatUI/Store.lean','LeanFM/ChatUI/Web.lean','Server.lean','scripts/chatui_application_test.py','scripts/chatui_ui_tour.py']
PROMPT='Document how to use the LeanFM Chat UI in detail, with screenshots.'

class Tour:
    def __init__(self,call,evaluate,wait,request,fixture,project_id):
        self.call,self.evaluate,self.wait,self.request=call,evaluate,wait,request
        self.fixture,self.project_id=fixture,project_id
        self.actions=[]; self.captures=[]
        shutil.rmtree(OUT,ignore_errors=True)
        OUT.mkdir(parents=True,exist_ok=True)
        self.browser=call('Browser.getVersion')['product']
    def viewport(self,session):
        self.call('Emulation.setDeviceMetricsOverride',{'width':1600,'height':1000,'deviceScaleFactor':1,'mobile':False},session)
    def active(self,session):
        return self.evaluate(session,"(()=>{const e=document.activeElement;return {role:e?.getAttribute('role')||e?.tagName||'',name:e?.getAttribute('aria-label')||e?.getAttribute('placeholder')||(e?.tagName==='BODY'?'Document':e?.textContent?.trim().slice(0,100))||''}})()")
    def key(self,session,key,modifiers=0):
        codes={'Tab':9,'Enter':13,'Escape':27,'a':65}
        data={'key':key,'code':('KeyA' if key=='a' else key),'windowsVirtualKeyCode':codes[key],'nativeVirtualKeyCode':codes[key],'modifiers':modifiers}
        down=dict(data,type='keyDown')
        if key=='Enter': down.update(text='\r',unmodifiedText='\r')
        self.call('Input.dispatchKeyEvent',down,session)
        self.call('Input.dispatchKeyEvent',dict(data,type='keyUp'),session)
        self.actions.append({'action':'key','key':key,'modifiers':modifiers,'focused':self.active(session)})
    def seek(self,session,selector,name='',starts=False):
        selector_js=json.dumps(selector); name_js=json.dumps(name)
        matcher="(e.getAttribute('aria-label')||e.getAttribute('placeholder')||e.textContent||'').trim()"
        test=(matcher+('.startsWith('+name_js+')' if starts else '==='+name_js)) if name else 'true'
        target="Array.from(document.querySelectorAll("+selector_js+")).find(e=>e.getClientRects().length&&!e.disabled&&("+test+"))"
        if not self.evaluate(session,'!!('+target+')'):
            raise AssertionError('No visible accessible target: '+selector+' '+name)
        for _ in range(180):
            if self.evaluate(session,'document.activeElement===('+target+')'):
                return
            self.key(session,'Tab')
        raise AssertionError('Keyboard cannot reach: '+selector+' '+name)
    def activate(self,session,selector,name='',starts=False):
        self.seek(session,selector,name,starts); self.key(session,'Enter')
    def type(self,session,selector,text):
        self.seek(session,selector); self.key(session,'a',2)
        self.call('Input.insertText',{'text':text},session)
        self.actions.append({'action':'type','public_fixture_text':text,'focused':self.active(session)})
    def capture(self,session,name,boundary,notice):
        self.viewport(session)
        # Native browser rendering and its accessibility tree are the evidence.
        screenshot=self.call('Page.captureScreenshot',{'format':'png','captureBeyondViewport':False},session)
        image=base64.b64decode(screenshot['data']); (OUT/(name+'.png')).write_bytes(image)
        tree=self.call('Accessibility.getFullAXTree',session=session)['nodes']
        accessible=[]
        for node in tree:
            if node.get('ignored'): continue
            item={'role':node.get('role',{}).get('value',''),'name':node.get('name',{}).get('value','')}
            if 'value' in node: item['value']=node['value'].get('value','')
            states={p['name']:p.get('value',{}).get('value') for p in node.get('properties',[]) if p['name'] in {'focused','focusable','disabled','checked','expanded','selected','required','multiline','live'}}
            if states: item['states']=states
            accessible.append(item)
        ax={'boundary':boundary,'focused':self.active(session),'nodes':accessible}
        ax_body=json.dumps(ax,indent=2,ensure_ascii=False)+'\n'
        (OUT/(name+'.accessibility.json')).write_text(ax_body)
        focus_body=json.dumps(self.actions,indent=2,ensure_ascii=False)+'\n'
        (OUT/(name+'.keyboard.json')).write_text(focus_body)
        _,body,_=self.request('/api/projects/'+self.project_id+'/conversation')
        event_ids=[m['message_id'] for m in json.loads(body).get('messages',[])]
        provenance={'name':name,'prompt':PROMPT,'task':'develop_project_specification','scenario':'chat-ui-user-guide',
            'question':notice,'boundary':boundary,'visible_event_ids':event_ids,
            'event_source':'production React DOM, real local provider/chat/lifecycle responses and current project task catalog',
            'reducer':'Chrome Page.captureScreenshot and Accessibility.getFullAXTree after semantic keyboard actions',
            'unit':'CSS pixels and accessible roles at the named UI event boundary','viewport':{'width':1600,'height':1000,'scale':1},
            'font_scale':1,'theme':'dark','browser':self.browser,'captured_at':datetime.now(timezone.utc).isoformat(),
            'project_id':self.project_id,'requirements_sha256':hashlib.sha256((self.fixture/'workspace/projects/GoServer/spec/Requirements.lean').read_bytes()).hexdigest(),
            'artifacts':{name+'.png':hashlib.sha256(image).hexdigest(),name+'.accessibility.json':hashlib.sha256(ax_body.encode()).hexdigest(),name+'.keyboard.json':hashlib.sha256(focus_body.encode()).hexdigest()}}
        self.captures.append(provenance)
        self.actions=[]
    def finish(self):
        for filename in ['Requirements.lean','Requirements.proto','tasks.json']:
            shutil.copyfile(self.fixture/'workspace/projects/GoServer/spec'/filename,OUT/('example-'+filename))
        manifest={'version':1,'prompt':PROMPT,'fixture':'Disposable GoServer replica; local deterministic provider; no live account, provider key or external network',
            'source_sha256':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in INPUTS},'captures':self.captures}
        for artifact in OUT.glob('*.json'):
            text=artifact.read_text()
            if 'documentation-placeholder' in text or 'a'*64 in text: raise AssertionError('Fixture credential reached a capture artifact')
        (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
        # Publish: every artifact first, the manifest that vouches for them last.
        for artifact in sorted(OUT.iterdir(),key=lambda path:path.name=='manifest.json'):
            os.replace(artifact,FINAL/artifact.name)
        OUT.rmdir()
        print('ok: '+str(len(self.captures))+' real Chat UI screenshots with accessibility, keyboard and provenance records')
