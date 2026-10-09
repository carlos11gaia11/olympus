"""Smoke tests de UI sem conexão com o Supabase: python tests/test_v5_ui.py"""
from pathlib import Path
from playwright.sync_api import sync_playwright

BASE = Path(__file__).resolve().parents[1]
PAGE = BASE / 'pages/menu.html'
SCRIPT = BASE / 'assets/inhouse-v5.js'

ROLES=['Top','Jungle','Mid','ADC','Support']
profiles=[{'id':f'p{i}','nickname':f'Jogador {i}','full_name':f'Player {i}','avatar_url':''} for i in range(10)]
entries=[{'id':f'e{i}', 'lobby_id':'l1','player_id':f'p{i}', 'role':ROLES[i//2], 'side':'A' if i%2==0 else 'B','draft_side':'A' if i==4 else ('B' if i==5 else None),'status':'CONFIRMED'} for i in range(10)]
lobby={'id':'l1','status':'DRAFT','title':'Teste MD3','captain_a':'p4','captain_b':'p5','captain_role':'Mid','draft_step':0,'draft_deadline':'2099-01-01T00:00:00Z', 'queue_open_at':'2026-10-08T10:00:00Z','confirm_at':'2026-10-08T10:30:00Z','allow_fill':False}

with sync_playwright() as p:
 browser=p.chromium.launch(headless=True,executable_path='/usr/bin/chromium',args=['--no-sandbox'])
 page=browser.new_page(viewport={'width':1360,'height':920})
 errors=[]
 page.on('pageerror',lambda e: errors.append(str(e)))
 page.set_content('<html><head><meta charset="utf-8"></head><body style="background:#080f1b;color:#fff"><main id="pageContent"></main></body></html>')
 page.add_style_tag(path=str(BASE / 'assets/styles.css'))
 page.add_script_tag(path=str(SCRIPT))
 page.evaluate("""({lobby,entries,profiles}) => {
 const ctx={state:{profile:{id:'p4',nickname:'Capitão Azul',lol_role:'Mid'},profiles},toast:(msg)=>{window.lastToast=msg},api:async(path,params)=>{
  if(path.includes('/rpc/')) {window.lastRpc={path,params};return 1;}
  if(path.includes('inhouse_lobbies'))return [lobby];
  if(path.includes('inhouse_queue_entries'))return entries;
  if(path.includes('inhouse_player_draft_picks'))return [];
  if(path.includes('inhouse_result_votes'))return [];
  return [];
 }};
 window.OlympusInhouseV5.render('admin',document.getElementById('pageContent'),ctx);
} """,{'lobby':lobby,'entries':entries,'profiles':profiles})
 page.locator('.ih5-draft').wait_for(timeout=5000)
 page.wait_for_timeout(550)
 page.screenshot(path=str(BASE / 'tests/OLYMPUS-V5-DRAFT.png'),full_page=False)
 assert page.locator('.ih5-player').count() == 8
 assert page.locator('.ih5-captain').count() == 2
 assert page.get_by_text('Hora de montar os times').count()==1
 assert page.locator('.ih5-photo').count()>10
 # Aciona seleção real: somente capitão chama endpoint server-side.
 page.locator('[data-ih-pick="p0"]').click()
 page.wait_for_timeout(400)
 last=page.evaluate('window.lastRpc')
 assert last['path'].endswith('/inhouse_pick_player'),last
 assert '"p_player_id":"p0"' in last['params']['body']
 # ADM: Fila -> espera -> promoção -> confirmar -> selecionar 4 pares -> 5 por time.
 page.locator('[data-demo="fill"]').click()
 assert '10 jogadores entraram' in page.locator('.ih5-demo-status').inner_text()
 page.locator('[data-demo="wait"]').click()
 assert 'Esperando:' in page.locator('.ih5-demo-meta').inner_text()
 page.locator('[data-demo="leave"]').click()
 assert 'entrou automaticamente na vaga Top' in page.locator('.ih5-demo-status').inner_text()
 page.locator('[data-demo="confirm"]').click()
 assert 'DRAFT' in page.locator('.ih5-demo-meta').inner_text()
 assert page.locator('[data-demo-pick]').count()==8
 page.locator('[data-demo-pick]').first.click()
 assert page.locator('[data-demo-pick]').count()==6
 page.locator('[data-demo="timeout"]').click()
 assert page.locator('[data-demo-pick]').count()==4
 page.locator('[data-demo="pick"]').click()
 assert page.locator('[data-demo-pick]').count()==2
 page.locator('[data-demo-pick]').first.click()
 assert 'EM_JOGO' in page.locator('.ih5-demo-meta').inner_text()
 assert page.locator('.ih5-team-panel.is-blue .ih5-player-demo').count()==5
 assert page.locator('.ih5-team-panel.is-red .ih5-player-demo').count()==5
 assert len(errors)==0,errors
 page.wait_for_timeout(700)
 page.screenshot(path=str(BASE / 'tests/OLYMPUS-V5-PREVIEW.png'),full_page=True)
 print('PASS: draft real exibe 8 jogadores disponíveis e RPC correta')
 print('PASS: 10 vagas, espera e promoção automática no laboratório')
 print('PASS: draft de 4 escolhas resulta em dois times de 5')
 print('PASS: sem exceções JavaScript; captura visual gerada')
 browser.close()
