"""Smoke test local end-to-end (Supabase simulado): python tests/test_v7_ui.py"""
from pathlib import Path
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from threading import Thread
from playwright.sync_api import sync_playwright

BASE=Path(__file__).resolve().parents[1]
class QuietHandler(SimpleHTTPRequestHandler):
 def __init__(self,*args,**kwargs):super().__init__(*args,directory=str(BASE),**kwargs)
 def log_message(self,*a):pass

server=ThreadingHTTPServer(('127.0.0.1',0),QuietHandler)
thread=Thread(target=server.serve_forever,daemon=True);thread.start()
try:
 with sync_playwright() as p:
  browser=p.chromium.launch(headless=True,executable_path='/usr/bin/chromium',args=['--no-sandbox'])
  page=browser.new_page(viewport={'width':1440,'height':900})
  errors=[]
  page.on('pageerror',lambda e:errors.append(str(e)))
  page.on('dialog',lambda d:d.accept())
  fixture_code='''() => {
   const token={access_token:'abc',refresh_token:'refresh',user:{id:'p1',email:'admin@olympus.test',email_confirmed_at:'2026-10-01'}};
   localStorage.setItem('olympus_session',JSON.stringify(token));
   const profiles=[{id:'p1',role_id:'adm',email:'admin@olympus.test',full_name:'Admin Teste',nickname:'Admin',lol_role:'Mid',reputation:50,initial_elo:'Diamante',player_tier:'A',roles:{id:'adm',permissions:{all:true},name:'Adm'}},{id:'p2',role_id:'usr',full_name:'Jogador 2',nickname:'Player 2',email:'p2@olympus.test',lol_role:'Top',reputation:50,initial_elo:'Ouro',player_tier:'D',roles:{id:'usr',permissions:{},name:'Usuario'}}];
   const teams=[{id:'t1',name:'Falcões',tag:'FAL',division:'Divisão A',team_tier:'S',created_by:'p1'},{id:'t2',name:'Leões',tag:'LEO',division:'Divisão A',team_tier:'B',created_by:'p2'}];
   const members=[{id:'x1',team_id:'t1',profile_id:'p1',team_role:'manager'},{id:'x2',team_id:'t2',profile_id:'p2',team_role:'manager'}];
   const matches=[{id:'m1',team_a:'t2',team_b:null,division:'Divisão A',match_format:'MD3',scheduled_at:'2099-11-11T20:00:00Z',status:'AGENDADA',open_slot:true,score_a:0,score_b:0,open_slot_notes:'Teste de vaga aberta'}];
   const ranks=[{player_id:'p1',points:9.5,games:2,wins:2,losses:0,winrate:100,md3:2,md5:0},{player_id:'p2',points:0,games:0,wins:0,losses:0,winrate:0,md3:0,md5:0}];
   const scrim=[{team_id:'t1',division:'Divisão A',points:4,games:1,wins:1,losses:0,winrate:100,md3:1,md5:0},{team_id:'t2',division:'Divisão A',points:0,games:0,wins:0,losses:0,winrate:0,md3:0,md5:0}];
   const social={instagram:'https://www.instagram.com/olympus',discord:'',youtube:'',tiktok:'',twitch:''};
   window.fixture={profiles,teams,members,matches,ranks,scrim,social,calls:[]};
   window.fetch=async function(url,opts={}){
    const path=new URL(url).pathname,body=opts.body?JSON.parse(opts.body):{},f=window.fixture;
    if(path.includes('/auth/v1/user'))return new Response(JSON.stringify({id:'p1',email:'admin@olympus.test',email_confirmed_at:'2026-10-01'}),{status:200});
    if(path.includes('/rest/v1/rpc/')){
     const op=path.split('/rpc/')[1];f.calls.push({op,body});
     if(op==='create_scrim_slot') f.matches.push({id:'m2',team_a:body.p_team,team_b:null,division:'Divisão A',match_format:body.p_format,scheduled_at:body.p_scheduled_at,status:'AGENDADA',open_slot:true,score_a:0,score_b:0,open_slot_notes:body.p_notes});
     if(op==='claim_scrim_slot'){const m=f.matches.find(m=>m.id===body.p_match_id);m.team_b=body.p_team;m.open_slot=false}
     if(op==='cancel_scrim_slot'){const m=f.matches.find(m=>m.id===body.p_match_id);m.open_slot=false;m.status='CANCELADA'}
     if(op==='admin_set_ranking_points') {const list=body.p_category==='INHOUSE'?f.ranks:f.scrim;const key=body.p_category==='INHOUSE'?'player_id':'team_id';list.find(r=>r[key]===body.p_id).points=body.p_target_points}
     return new Response(JSON.stringify(null),{status:200,headers:{'Content-Type':'application/json'}});
    }
    if(path.includes('/rest/v1/profiles')&&opts.method==='PATCH'){
     Object.assign(f.profiles.find(p=>p.id===new URL(url).searchParams.get('id').replace('eq.','')),body);
     return new Response(JSON.stringify([{}]),{status:200});
    }
    if(path.includes('/rest/v1/teams')&&opts.method==='PATCH'){
     Object.assign(f.teams.find(t=>t.id===new URL(url).searchParams.get('id').replace('eq.','')),body);
     return new Response(JSON.stringify([{}]),{status:200});
    }
    if(path.includes('/rest/v1/platform_settings')&&opts.method==='PATCH')Object.assign(f.social,body.social_links);
    let data=[];
    if(path.endsWith('/rest/v1/profiles'))data=new URL(url).searchParams.has('id')?[f.profiles[0]]:f.profiles;
    else if(path.endsWith('/rest/v1/roles'))data=[{id:'adm',name:'Adm',permissions:{all:true},is_system:true},{id:'usr',name:'Usuario',permissions:{},is_system:true}];
    else if(path.endsWith('/rest/v1/teams'))data=f.teams;
    else if(path.endsWith('/rest/v1/team_members'))data=f.members;
    else if(path.endsWith('/rest/v1/team_stats'))data=[{team_id:'t1',reputation:50},{team_id:'t2',reputation:50}];
    else if(path.endsWith('/rest/v1/matches'))data=f.matches;
    else if(path.endsWith('/rest/v1/scrim_ranking'))data=f.scrim;
    else if(path.endsWith('/rest/v1/inhouse_ranking'))data=f.ranks;
    else if(path.endsWith('/rest/v1/platform_settings'))data=[{id:1,social_links:f.social}];
    return new Response(JSON.stringify(data),{status:200,headers:{'Content-Type':'application/json'}});
   }
  }'''
  page.set_content('<html><head><meta charset="utf-8"></head><body><div id="app"></div></body></html>')
  page.add_style_tag(path=str(BASE/'assets/styles.css'))
  page.evaluate('''() => {history.pushState=()=>{}; const memory=new Map();Object.defineProperty(window,'localStorage',{configurable:true,value:{setItem:(k,v)=>memory.set(k,v),getItem:k=>memory.get(k)||null,removeItem:k=>memory.delete(k)}})}''')
  page.evaluate(fixture_code)
  page.add_script_tag(path=str(BASE/'assets/config.js'))
  page.add_script_tag(path=str(BASE/'assets/inhouse-v5.js'))
  page.add_script_tag(path=str(BASE/'assets/app.js'))
  page.evaluate("document.dispatchEvent(new Event('DOMContentLoaded'))")
  page.get_by_text('Meu dashboard · Admin').wait_for()
  assert page.locator('#pageContent').get_by_text('Últimas notícias').count()==0
  assert page.get_by_text('Posição In House').count()==1
  assert page.get_by_text('Reputação pessoal').count()==1
  print('PASS: dashboard pessoal sem notícias, com estatísticas e reputação')
  page.locator('[data-dash="partidas.html"]').click()
  page.get_by_role('heading',name='Vagas disponíveis').wait_for()
  assert page.locator('[data-claim-slot="m1"]').count()==1
  page.locator('[data-claim-slot="m1"]').click()
  page.locator('#claimTeam').select_option('t1')
  page.get_by_role('button',name='Confirmar entrada').click()
  page.get_by_text('Falcões',exact=False).first.wait_for()
  assert page.evaluate('fixture.matches.find(x=>x.id==="m1").team_b')=='t1'
  page.get_by_role('button',name='+ Criar partida aberta').click()
  page.locator('#slotTeam').select_option('t1')
  page.locator('#slotAt').fill('2026-12-11T20:00')
  page.get_by_role('button',name='Publicar vaga').click()
  page.wait_for_function('window.fixture.matches.some(x=>x.id==="m2")')
  page.locator('[data-cancel-slot="m2"]').wait_for(timeout=5000)
  page.locator('[data-cancel-slot="m2"]').click()
  assert page.evaluate('fixture.matches.find(x=>x.id==="m2").status')=='CANCELADA'
  print('PASS: agenda publica vaga, recebe time e permite cancelar vaga')
  page.locator('[data-view="admin.html"]').first.click()
  page.get_by_text('Jogadores · tier individual').wait_for()
  page.locator('[data-tier-user="p2"]').select_option('S')
  page.locator('[data-rep-user="p2"]').fill('73')
  page.locator('[data-save-user="p2"]').click()
  page.wait_for_function('window.fixture.profiles[1].player_tier==="S"')
  assert page.evaluate('fixture.profiles[1].reputation')==73
  page.get_by_role('button',name='Times / divisões').click()
  page.locator('[data-team-tier="t2"]').select_option('A')
  page.locator('[data-save-team="t2"]').click()
  page.wait_for_function('window.fixture.teams[1].team_tier==="A"')
  page.get_by_role('button',name='Redes sociais').click()
  page.locator('[data-social-key="youtube"]').fill('https://www.youtube.com/@Olympus')
  page.get_by_role('button',name='Salvar links oficiais').click()
  page.wait_for_function('window.fixture.social.youtube==="https://www.youtube.com/@Olympus"')
  page.get_by_role('button',name='Pontos dos rankings').click()
  page.locator('[data-points-id="p1"]').fill('33.5')
  page.locator('[data-reason-id="p1"]').fill('Revisão do conselho')
  page.locator('[data-save-rank="p1"]').click()
  page.wait_for_function('window.fixture.ranks[0].points===33.5')
  page.locator('#adminRankingSelect').select_option('SCRIM|Divisão A')
  page.locator('[data-points-id="t1"]').fill('20')
  page.locator('[data-reason-id="t1"]').fill('Revisão do conselho')
  page.locator('[data-save-rank="t1"]').click()
  page.wait_for_function('window.fixture.scrim[0].points===20')
  print('PASS: ADM gerencia tiers e os dois tipos de ranking')
  page.locator('[data-view="regras.html"]').first.click()
  page.get_by_role('heading',name='Regras e funcionamento').wait_for()
  assert page.get_by_role('link',name='Instagram').count()==1
  assert page.get_by_text('50 pontos de reputação',exact=False).count()>=1
  assert not errors,errors
  print('PASS: regras, redes sociais e ausência de erros JS')
  browser.close()
finally:
 server.shutdown();server.server_close()
