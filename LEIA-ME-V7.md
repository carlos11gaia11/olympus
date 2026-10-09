# OLYMPUS V7 — Agenda Livre, Tiers, Rankings e Dashboard

A V7 continua a V6 original. Todos os arquivos existentes, inclusive o draft In House e o fluxo de cinco confirmações, foram preservados. **Para as funcionalidades novas persistirem, execute a migração SQL V7 no mesmo projeto Supabase usado pelo site.**

## O que foi implementado

1. **Agenda livre de scrims:** um dono/manager/coach/staff abre uma vaga pública com time, divisão, MD1/MD3/MD5, data/hora e observações. Outro responsável de um time diferente da **mesma divisão** pode ocupá-la. Ao entrar, a vaga deixa de aparecer para outros times, pois a transação no banco bloqueia concorrência. É possível cancelar uma vaga ainda livre. O sistema impede agendar com menos de 15 minutos, mais de 90 dias e uma segunda partida para o mesmo time a menos de duas horas da primeira. Convites privados originais permanecem disponíveis.
2. **Ranks editáveis:** no Painel ADM → Pontos dos rankings, edite os pontos de qualquer jogador In House, time na Divisão A ou time na Divisão B. Informe o total desejado e uma justificativa. O banco grava o **ajuste separado** da base automática; resultados futuros seguem aumentando/diminuindo pontos normalmente. Cada ranking começa em 0 quando não há jogos ou ajuste prévio.
3. **Tiers de jogadores:** S, A, B, C, D, E e F, conforme elo selecionado no cadastro. Mapeamento inicial visível em **Regras e guia**: Mestre ou superior → S; Diamante → A; Esmeralda → B; Platina → C; Ouro → D; Prata/Bronze → E; Ferro/Não classificado → F. Depois do cadastro, apenas ADM/conselho pode alterar o tier.
4. **Tiers de times:** os times começam com tier F, definido posteriormente pelo administrador em Painel ADM → Times/divisões; a divisão inicial continua B. A classificação das equipes continua separada por divisão.
5. **Reputação:** novo jogador e novo time começam com 50 pontos, mínimos 0 e máximo 100, validados pelo banco. Na instalação, zeros legados sem histórico de penalidade passam para 50. Zeros relacionados a denúncias aprovadas permanecem zerados. Valores legados acima de 100 são limitados a 100.
6. **Dashboard pessoal:** informações individuais, tier e elo inicial, equipe e divisão, posições nos rankings, pontos, vitórias, derrotas, winrate, reputações, próximas atividades e número de vagas abertas. Notícias ficam exclusivamente na aba Notícias, não no dashboard.
7. **Regras e guia:** explica cadastro, tiers, divisões, scrims, In House, pontuação, reputação, reports e administração.
8. **Redes sociais:** seção na página de regras e nova aba Painel ADM → Redes sociais. Inclua os links HTTPS oficiais de Instagram, Discord, YouTube, TikTok e Twitch. Não foram inventados links para contas que você não informou; até serem cadastrados, aparece “Em breve”.
9. **Pasta `imagens/`:** logo própria Olympus e ícones vetoriais SVG das redes; podem ser substituídos mantendo nome e extensão. Favicon e marca do login/menu usam a nova imagem.

## Instalação em banco já na V6

1. Faça backup do Supabase e do código do site.
2. Abra **Supabase → SQL Editor**, selecione o projeto já usado pelo Olympus.
3. Cole e execute **`supabase/OLYMPUS-V7-AGENDA-TIERS-RANKINGS.sql`**. Ele usa objetos das versões anteriores V3, V4, V5, V6 e do módulo `REPORTS-MODERACAO.sql` e `ATUALIZACAO-SEGURA.sql`.
4. Publique **toda** a pasta de projeto (incluindo `assets/`, `pages/` e a nova pasta **`imagens/`**) no mesmo diretório. Mantenha os caminhos relativos.
5. Abra `pages/index.html`, faça login, abra **Agenda de Scrims** para publicar uma vaga e **Painel ADM** para gerenciar tiers, rankings e redes sociais.
6. Realize um teste no seu banco de homologação antes de usar em produção, especialmente com dois times de mesma divisão, dois candidatos à mesma vaga, um resultado finalizado e a classificação atualizada.

## Se está instalando do zero

Siga a ordem exigida pelo projeto original:

`schema.sql` → `ATUALIZACAO-SEGURA.sql` → `REPORTS-MODERACAO.sql` → V3 → V4 → V5 → V6 → **V7**.

> Não execute novamente o schema base nem migrações antigas em um banco já migrado; isso pode recriar políticas antigas ou alterar fluxos que funcionam.

## Como usar

**Criar agenda:** Agenda de Scrims → Criar partida aberta → selecione time → formato, horário e observações → Publicar vaga. A vaga ficará visível. Outro dono/gestor abre a mesma tela e escolhe **Entrar com meu time**. O time escolhido precisa estar na mesma divisão e não ter choque de horário. As partidas aceitas passam para “Partidas marcadas”. O ADM homologa resultados pelo botão “Editar / resultado”.

**Alterar ponto:** Painel ADM → Pontos dos rankings → escolha In House, Divisão A ou Divisão B → digite pontuação total e o motivo → Salvar pontos.

**Alterar tier:** Painel ADM → Jogadores/tiers ou Times/divisões → defina S…F e salve.

**Links sociais:** Painel ADM → Redes sociais → preencha apenas endereços oficiais HTTPS dos perfis → Salvar links oficiais.

## Testes locais

- `node --check assets/app.js`
- `node --check assets/inhouse-v5.js`
- `python tests/test_v5_ui.py` — draft e laboratório V5
- `python tests/test_v6_ui.py` — fila e validação do resultado V6
- `python tests/test_v7_ui.py` — dashboard, agenda livre, tiers, edição dos rankings e página de regras, com backend simulado

**Limite da validação:** não foi efetuada conexão com o Supabase real. Testes automatizados verificam interface e chamadas da API simuladas, não substituem execução da migração nem verificam políticas RLS no seu ambiente. As redes sociais também não terão links funcionais até que o administrador cadastre os oficiais.
