# OLYMPUS V6 — Filas, draft animado, resultados e ranking In House

Esta atualização parte da versão V5 e corrige o fluxo de ponta a ponta. **Não basta trocar os arquivos: o SQL da V6 também precisa ser executado no Supabase.**

## O que mudou

### Botão para entrar na fila
- O botão **🎮 Entrar na fila** fica visível **no início** da página da partida, antes da lista de jogadores.
- A inscrição aceita a função do perfil, as cinco funções quando o ADM permite fill, e as cinco funções de perfis cadastrados como `Flex`.
- Se o perfil não possui função válida, o usuário vê uma mensagem com link para editar o perfil, em vez de a opção desaparecer silenciosamente.
- A fila mantém dois jogadores por função, lista de espera e promoção, conforme a V4. Após o horário de confirmação, inscritos podem confirmar presença sem sair da tela.

### Draft com animações
- Destaque do lado de cada turno: Azul → Vermelho → Azul → Vermelho, 20 segundos cada.
- Capitães com foto, cronômetro regressivo, barra de progresso e cartões animados dos jogadores disponíveis.
- **Uma escolha distribui automaticamente o par da mesma função para o time adversário.** O sistema anima a confirmação mostrando as duas atribuições, inclusive para espectadores de sessões sincronizadas.
- Ao terminar quatro turnos, os dez jogadores ocupam times de cinco, com uma função por time.
- Música/som são opcionais e requerem clique do usuário; o site respeita as configurações de redução de movimento.

### Lançar e confirmar o resultado
1. Quando o draft termina, a partida passa para **Em jogo**.
2. Um **participante confirmado** ou **administrador** lança o placar: campeão Azul/Vermelho, em MD3 `2 × 0` ou `2 × 1`.
3. Cada participante vê o placar proposto e os botões **✓ Confirmar resultado** e **Não concordo**.
4. O Supabase exige **cinco confirmações positivas de cinco jogadores distintos da própria partida**. Votos discordantes não contam como confirmações.
5. Ao receber o quinto aceite, a operação finaliza a partida **no banco**, gravando o resultado definitivo. A view `inhouse_ranking` da V5 inclui automaticamente a vitória, a derrota e os pontos de cada jogador, usando `draft_side` (não a vaga provisória da fila).
6. O botão **Ver ranking atualizado** leva ao ranking In House, que consulta novamente o Supabase quando aberto e permite atualização manual.
7. Se o placar for corrigido antes da finalização, confirmações anteriores são apagadas e a validação recomeça. Corrigir exige ser o lançador, um dos capitães ou ADM.

## Instalação

1. Faça backup do banco.
2. Certifique-se de que executou `schema.sql` e as migrações V3, V4 e V5 nesta ordem.
3. Finalize/cancele drafts antigos da V4, conforme orientação da V5.
4. Execute **`supabase/OLYMPUS-V6-FILA-DRAFT-RESULTADOS.sql`** pelo **Supabase → SQL Editor**.
5. Atualize **toda a pasta `assets/` e `pages/`**, inclusive `assets/app.js`, `assets/inhouse-v5.js`, `assets/styles.css`. O módulo mantém o nome de arquivo `inhouse-v5.js` para ser compatível com o carregamento atual.
6. Abra `pages/index.html` para login; depois acesse **In House → Partidas** ou **Ranking**.
7. Faça um teste com dez contas reais em **ambiente de homologação**: entrada, confirmação, capitães, quatro escolhas, envio do placar, cinco confirmações e pontuação na tabela.

## Segurança e dados
- O frontend não finaliza partidas, nem grava resultados diretamente nas tabelas: usa funções RPC verificadas com `auth.uid()` no banco.
- A confirmação é transacional e mantém as permissões RLS de leitura do sistema.
- A função antiga `inhouse_vote_result` tem execução revogada para usuários, impedindo que versões antigas contornem o novo fluxo de validação.
- A tabela de confirmações é nova e independente dos votos da V4/V5. Partidas concluídas anteriormente continuam no ranking.
- O modo laboratório do ADM é **apenas simulação**, não grava ranking nem entra em partidas reais.

## Verificações

- `python tests/test_v5_ui.py` — navegação, laboratório e draft V5 (mock Playwright).
- `python tests/test_v6_ui.py` — entrada, animação da escolha, placar, cinco aceites e conclusão em interface com Supabase simulado.
- `node --check assets/app.js` e `node --check assets/inhouse-v5.js` — verificação de sintaxe.
- Imagens de referência: `tests/OLYMPUS-V6-FILA.png` e `tests/OLYMPUS-V6-RESULTADO.png`.

**Limitação:** não houve acesso a um banco Supabase real neste ambiente. Os testes validam fluxos simulados e sintaxe do JavaScript, **não** substituem a execução da migração e testes de integração reais no projeto Supabase. Atualizações da tabela via view são consultadas novamente ao abrir ou atualizar o ranking.
