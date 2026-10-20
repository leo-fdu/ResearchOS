'use strict';
marked.setOptions({gfm:true, breaks:false});
const root=document.getElementById('messages'), latest=document.getElementById('latest');
const nodes=new Map(), data=new Map();
let following=true, lastRevision=-1, updateInFlight=false;
function bridge(value) { window.webkit.messageHandlers.action.postMessage(value); }
function escapeHtml(s) { return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
function bottom() { if (!window.researchDocument) window.scrollTo(0,document.documentElement.scrollHeight); }
function nearBottom() { return document.documentElement.scrollHeight-window.innerHeight-window.scrollY<90; }
window.addEventListener('scroll',()=>{ if(!updateInFlight) following=nearBottom(); latest.hidden=following; },{passive:true});
window.addEventListener('wheel',e=>{ if(e.deltaY<0) { following=false; latest.hidden=false; } },{passive:true});
latest.onclick=()=>{ following=true; bottom(); latest.hidden=true; };
window.copyResult=(id,success)=>{
    const el=nodes.get(id); if(!el) return;
    const button=el.querySelector('.copy');
    clearTimeout(el._copyTimer);
    button.innerHTML=success ? '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12 4 4L19 6"/></svg>' : el._copyIcon;
    el.classList.toggle('copy-success',success);
    button.setAttribute('aria-label',success?'Copied':'Copy failed; try again');
    button.title=success?'Copied!':'Copy failed; try again';
    el._copyTimer=setTimeout(()=>{
        button.innerHTML=el._copyIcon; el.classList.remove('copy-success');
        button.setAttribute('aria-label','Copy message'); button.title='Copy';
    },1500);
};
function renderText(element, text, streaming) {
    const selection=window.getSelection();
    if(selection && !selection.isCollapsed && element.contains(selection.anchorNode)) return false;
    const html=restoreMath(marked.parse(protectMath(text)));
    element.innerHTML=DOMPurify.sanitize(html,{FORBID_TAGS:['img','style','svg','math','iframe','form','input','button'], ALLOWED_URI_REGEXP:/^(?:(?:https?|mailto|pdfchat|researchos):|[#/])/i});
    renderMathInElement(element,{delimiters:[{left:'$$',right:'$$',display:true},{left:'\\[',right:'\\]',display:true},{left:'\\(',right:'\\)',display:false},{left:'$',right:'$',display:false}],throwOnError:false,trust:false,ignoredTags:['script','style','textarea','pre','code']});
    return true;
}
function createMessage(m) {
    const el=document.createElement('article'); el.className='message '+m.role;
    el.innerHTML='<div class="bubble"><div class="role"></div><div class="quote" hidden></div><div class="images"></div><div class="content"></div><div class="pending" hidden>Waiting for model</div></div><div class="actions"><button class="copy" tabindex="0" aria-label="Copy message" title="Copy"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><rect x="8" y="8" width="12" height="12" rx="3"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/></svg></button><button class="retry" hidden>Retry</button><span class="state"></span></div><details hidden><summary>Usage and tool activity</summary><pre></pre></details>';
    el._copyIcon=el.querySelector('.copy').innerHTML;
    el.querySelector('.copy').onclick=()=>bridge({type:'copy',id:m.id});
    el.querySelector('.copy').onfocus=()=>el.classList.add('copy-focused');
    el.querySelector('.copy').onblur=()=>el.classList.remove('copy-focused');
    el.querySelector('.retry').onclick=()=>bridge({type:'retry',id:m.id});
    nodes.set(m.id,el); return el;
}
function updateMessage(m) {
    const el=nodes.get(m.id) || createMessage(m);
    el.querySelector('.role').hidden=m.role==='user';
    el.querySelector('.role').textContent=m.role==='user' ? '' : (m.model||'Research assistant');
    const content=el.querySelector('.content');
    if(el._text!==m.text || el._streaming!==m.streaming) {
        const applied=m.role==='user' ? (content.textContent=m.text,true) : renderText(content,m.text,m.streaming);
        if(applied) { el._text=m.text; el._streaming=m.streaming; }
    }
    const quote=el.querySelector('.quote'); quote.hidden=!m.quote;
    if(m.quote) quote.textContent='Page '+m.quote.page+' · '+m.quote.text;
    if(m.images && !el._images) {
        for(const src of m.images) { if(!src.startsWith('data:image/')) continue; const img=document.createElement('img'); img.src=src; el.querySelector('.images').append(img); }
        el._images=true;
    }
    el.querySelector('.pending').hidden=!(m.streaming && !m.text);
    el.querySelector('.state').textContent=m.status==='stopped'?'Stopped':m.status==='error'?'Request failed':m.streaming?'Responding':'';
    el.querySelector('.state').classList.toggle('error',m.status==='error');
    el.querySelector('.retry').hidden=m.status!=='error';
    const details=el.querySelector('details'); details.hidden=!m.details;
    details.querySelector('pre').textContent=m.details||'';
    data.set(m.id,m);
    return el;
}
function applyUpdate(payload) {
    if(payload.revision<lastRevision) return;
    lastRevision=payload.revision;
    const keepFollowing=following;
    updateInFlight=true;
    if(payload.reset) { for(const el of nodes.values()) clearTimeout(el._copyTimer); root.replaceChildren(); nodes.clear(); data.clear(); following=true; }
    if(payload.order.length===0) {
        root.innerHTML='<div class="empty"><h2>Read, then explore.</h2><p>Discuss the document and its figures.<br>Select a passage to quote it.</p><div class="suggestions"><button data-prompt="Summarize the main question, methods and findings of this document with page citations.">Summarize this paper ↗</button><button data-prompt="Explain the key concepts in this document and cite the relevant pages.">Explain key concepts ↗</button><button data-prompt="Assess the evidence and limitations of this document with page citations.">Review evidence and limitations ↗</button></div></div>';
        if(payload.workspace) root.innerHTML='<div class="empty"><h2>Build on your research.</h2><p>Read papers, notes and code on demand.<br>Develop your projects and ideas.</p><div class="suggestions"><button data-prompt="Review my research resources and summarize the projects I am working on. Separate existing evidence from unknowns.">Map my research ↗</button><button data-prompt="Read the attached papers. Summarize methods and limitations with page citations; inspect page images if needed.">Read a paper together ↗</button><button data-prompt="List my saved ideas and help me choose a question worth investigating next.">Develop an idea ↗</button></div></div>';
        root.querySelectorAll('[data-prompt]').forEach(b=>b.onclick=()=>bridge({type:'prompt',text:b.dataset.prompt}));
    } else {
        root.querySelector('.empty')?.remove();
        for(const m of payload.updates) updateMessage(m);
        const valid=new Set(payload.order);
        for(const [id,node] of nodes) { if(!valid.has(id)) { clearTimeout(node._copyTimer); node.remove(); nodes.delete(id); data.delete(id); } }
        payload.order.forEach((id,index)=>{ const node=nodes.get(id); if(node && root.children[index]!==node) root.insertBefore(node,root.children[index]||null); });
    }
    requestAnimationFrame(()=>{ if(keepFollowing || payload.reset) { following=true; bottom(); } latest.hidden=following; updateInFlight=false; });
}
document.addEventListener('selectionchange',()=>{ const s=window.getSelection(); if(s && s.isCollapsed) for(const m of data.values()) { const el=nodes.get(m.id); if(el && el._text!==m.text) updateMessage(m); } });
document.addEventListener('click',e=>{ const a=e.target.closest('a'); if(a) { e.preventDefault(); bridge({type:'link',url:a.getAttribute('href')}); } });
new ResizeObserver(()=>{ if(following) requestAnimationFrame(bottom); }).observe(root);
window.webkit.messageHandlers.ready.postMessage('ready');
