"""UI integration smoke tests: python tests/test_v6_ui.py. Supabase is mocked."""
from pathlib import Path
from playwright.sync_api import sync_playwright

BASE=Path(__file__).resolve().parents[1]
ROLES=['Top','Jungle','Mid','ADC','Support']
with sync_playwright() as p:
 browser=p.chromium.launch(headless=True,executable_path='/usr/bin/chromium',args=['--no-sandbox'])
 page=browser.new_page(viewport={'width':1380,'height':940},reduced_motion='no-preference')
 errors=[]
 page.on('pageerror',lambda e:errors.append(str(e)))
 page.on('dialog',lambda d:d.accept())
 page.set_content('<html><head><meta charset="utf-8"></head><body style="background:#080f1b;color:white"><main id="content"></main></body></html>')
 page.add_style_tag(path=str(BASE/'assets/styles.css'))
 page.add_script_tag(path=str(BASE/'assets/inhouse-v5.js'))
 page.evaluate('''(roles) => {
  const lobby={id:'l1',title:'OLYMPUS • MD3 de testes',status:'AGENDADA',allow_fill:true,queue_open_at:'2026-10-07T10:00:00Z',confirm_at:'2026-10-07T10:30:00Z',captain_a:null,captain_b:null,created_at:'2026-10-07T10:00:00Z'};
  const entries=[],picks=[],confirmations=[];
  const profiles=Array.from({length:10},(_,i)=>({id:'p'+i,nickname:'Jogador '+i,lol_role:roles[Math.floor(i/2)]}));
  const ctx={state:{profile:{...profiles[0]},profiles},toast:(text)=>window.lastToast=text,api:async(path,opts)=>{
    if(path.includes('/rpc/')){
      const body=JSON.parse(opts.body),fn=path.split('/rpc/')[1];window.lastRpc={fn,body};
      if(fn==='inhouse_join')entries.push({id:'e0',player_id:ctx.state.profile.id,lobby_id:lobby.id,role:body.p_role,side:'A',status:'SLOT'});
      if(fn==='inhouse_pick_player'){
        const e=entries.find(x=>x.player_id===body.p_player_id),pair=entries.find(x=>x.role===e.role&&x.player_id!==e.player_id),side=lobby.draft_step%2===0?'A':'B';
        e.draft_side=side;pair.draft_side=side==='A'?'B':'A';
        picks.push({lobby_id:lobby.id,turn:lobby.draft_step,chosen_player_id:e.player_id,paired_player_id:pair.player_id,role:e.role,captain_side:side,automatic:false});lobby.draft_step++;
      }
      if(fn==='inhouse_propose_result'){
        if(lobby.proposed_winner_side!==body.p_winner_side||lobby.proposed_loser_games!==body.p_loser_games)confirmations.splice(0);
        lobby.proposed_winner_side=body.p_winner_side;lobby.proposed_loser_games=body.p_loser_games;lobby.result_proposed_by=ctx.state.profile.id;
      }
      if(fn==='inhouse_confirm_result'){
        const old=confirmations.find(c=>c.player_id===ctx.state.profile.id);
        if(old)old.agree=body.p_agree;else confirmations.push({player_id:ctx.state.profile.id,lobby_id:lobby.id,agree:body.p_agree});
        if(confirmations.filter(c=>c.agree).length>=5){lobby.status='FINALIZADA';lobby.winner_side=lobby.proposed_winner_side;lobby.score_a=lobby.winner_side==='A'?2:lobby.proposed_loser_games;lobby.score_b=lobby.winner_side==='B'?2:lobby.proposed_loser_games;}
      }
      return 1;
    }
    if(path.includes('inhouse_lobbies'))return [lobby];
    if(path.includes('inhouse_queue_entries'))return entries;
    if(path.includes('inhouse_player_draft_picks'))return picks;
    if(path.includes('inhouse_result_confirmations'))return confirmations;
    return [];
  }};
  window.test={lobby,entries,picks,confirmations,ctx,profiles,rerender(){window.OlympusInhouseV5.render('matches',document.getElementById('content'),ctx)}};
  test.rerender();
 }''',ROLES)
 page.get_by_role('button',name='🎮 Entrar na fila').wait_for()
 assert page.locator('#ihRole option').count()==5
 page.screenshot(path=str(BASE/'tests/OLYMPUS-V6-FILA.png'),full_page=True)
 page.get_by_role('button',name='🎮 Entrar na fila').click()
 page.get_by_text('Vaga reservada').wait_for()
 assert page.evaluate('test.entries.length')==1
 print('PASS: entrar na fila aparece e registra a entrada')
 page.evaluate('''() => {const t=test;t.lobby.status='DRAFT';t.lobby.captain_a='p4';t.lobby.captain_b='p5';t.lobby.captain_role='Mid';t.lobby.draft_step=0;t.lobby.draft_deadline='2099-10-08T10:00:00Z';t.entries.splice(0,t.entries.length,...t.profiles.map((p,i)=>({id:'e'+i,lobby_id:'l1',player_id:p.id,role:p.lol_role,side:i%2===0?'A':'B',draft_side:i===4?'A':i===5?'B':null,status:'CONFIRMED'})));t.ctx.state.profile=t.profiles[4];t.rerender();}''')
 page.locator('.ih6-draft-banner').wait_for()
 assert page.locator('[data-ih-pick]').count()==8
 assert page.locator('.ih6-draft-banner').count()==1
 page.locator('[data-ih-pick="p0"]').click()
 page.locator('#ih6PickNotice').wait_for()
 assert page.locator('[data-ih-pick]').count()==6
 print('PASS: animação de escolha exibida e par removido do draft')
 page.evaluate("() => {test.lobby.status='EM_JOGO';test.ctx.state.profile=test.profiles[0];test.entries.forEach((e,i)=>e.draft_side=i%2===0?'A':'B');test.rerender()}")
 page.locator('#ih6ResultForm').wait_for()
 page.wait_for_timeout(650)
 page.screenshot(path=str(BASE/'tests/OLYMPUS-V6-RESULTADO.png'),full_page=True)
 page.locator('#ih6Winner').select_option('B')
 page.locator('#ih6LoserGames').select_option('1')
 page.get_by_role('button',name='Lançar placar para confirmação').click()
 page.get_by_text('Aguardando confirmação dos jogadores').wait_for()
 assert page.evaluate("test.lobby.proposed_winner_side==='B' && test.lobby.proposed_loser_games===1")
 assert page.locator('[data-ih-result-confirm="true"]').count()==1
 for i in range(5):
  page.evaluate('(i)=>{test.ctx.state.profile=test.profiles[i];test.rerender()}',i)
  page.get_by_role('button',name='✓ Confirmar resultado').click()
  page.wait_for_timeout(100)
  assert page.evaluate('test.confirmations.filter(x=>x.agree).length')==i+1
 page.get_by_text('Pontuação incorporada ao ranking In House',exact=False).wait_for()
 assert page.evaluate("test.lobby.status==='FINALIZADA' && test.lobby.score_a===1 && test.lobby.score_b===2")
 assert page.get_by_role('link',name='🏆 Ver ranking atualizado').count()==1
 print('PASS: placar lancado, 5 jogadores distintos confirmam, MD3 finalizada e ranking vinculado')
 assert not errors,errors
 print('PASS: sem erros JavaScript')
 browser.close()
