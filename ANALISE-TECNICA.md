# Olympus — diagnóstico técnico e correções (08/10/2026)

## Alterações realizadas no pacote
- Recuperação de senha no login via Supabase Auth `/recover`, com redefinição por link; no Supabase, cadastrar a URL de redirecionamento correspondente a `pages/index.html` em Authentication > URL Configuration. Em modo `file://`, recuperação por e-mail pode não funcionar corretamente: hospedar em HTTPS é recomendado.
- Identidade master `carlosgaia1100@gmail.com` validada no banco em `auth.users`, exigindo confirmação de e-mail. A interface identifica a conta master para exibir os controles, mas o banco faz a autorização real.
- Migração SQL elimina a atribuição automática de administrador a qualquer primeiro cadastro futuro e bloqueia mudança do próprio cargo/reputação/email via edição de perfil.
- Proteções contra exclusão/rebaixamento do usuário master, inclusive via RPC administrativa do aplicativo.
- Feed de notícias com curtidas e acesso direto aos comentários, e área de notificações com publicações recentes.
- Botão **Confirmar agendamento** habilitado após o horário, quando a partida está em status `AGENDADA`; a RPC valida hora e participação no servidor.
- Renovação básica de sessões expiradas e correção da apresentação de horário local no formulário de partidas.
- Configurações deixou de ser placeholder e oferece recuperação de senha.

## Principais problemas encontrados
1. **CRÍTICO — escalonamento de privilégios:** a política `profiles_update` permitia que usuários atualizassem `role_id`, atribuindo-se o cargo `Adm`. Proteção adicionada por trigger no SQL.
2. **CRÍTICO — primeiro cadastro com acesso total:** o trigger antigo promovia a primeira conta independente de e-mail; a migração substitui o trigger. **Revise administradores já existentes**, pois a migração não os remove automaticamente.
3. **ALTO — autorização no navegador:** ocultar controles não é autorização; todas as operações privilegiadas devem ser protegidas por RLS/RPC no Supabase. A conta master depende da função `is_master` no servidor.
4. **ALTO — estado da sessão desatualizado:** o aplicativo usava o token guardado indefinidamente; agora tenta verificar e renovar. Para produção, recomenda-se migrar para SDK `supabase-js` e cookies adequados.
5. **MÉDIO — agendamento sem aceite:** não existia confirmação separada da edição administrativa; RPC evita confirmação antes do prazo.
6. **MÉDIO — recuperação de senha ausente:** novo fluxo depende de URLs de redirecionamento autorizadas no Supabase.
7. **MÉDIO — notificações eram placeholder:** nova página exibe feed recente; **notificações pessoais em tempo real, push e badges de não lidas ainda não foram implementados**.
8. **MÉDIO — falta de paginação:** `loadCore` carrega todas as tabelas e comentários; pode ficar lento com muitos registros. Recomendado paginação e índices.
9. **MÉDIO — abrir HTML com file://:** algumas integrações e links de autenticação exigem URL HTTP(S). Recomenda-se hospedagem HTTPS ou servidor local.
10. **MÉDIO — RLS antiga com leitura ampla de perfis:** auditabilidade, privacidade, políticas de coleta de dados e restrição de campos requerem revisão adicional antes de produção pública.

## Como implantar
1. Faça backup do projeto e do banco. **Nunca exponha chave service_role** no site.
2. Caso seja uma instalação nova, execute `supabase/schema.sql` uma única vez no SQL Editor.
3. **Em ambos os casos execute `supabase/ATUALIZACAO-SEGURA.sql`** no SQL Editor com conta administrativa do projeto. Só atualizar o ZIP sem executar SQL não habilita a segurança ou confirmação.
4. Verifique em **Authentication > Users** se a conta `carlosgaia1100@gmail.com` existe e o e-mail foi confirmado. O master precisa fazer login normalmente; o e-mail sozinho não concede acesso a outra pessoa.
5. Configure em Supabase **Authentication > URL Configuration** o Site URL e os Redirect URLs para o domínio HTTPS onde publicará `pages/index.html`. Personalize o modelo de e-mail de redefinição se desejar.
6. Substitua os arquivos publicados pelos arquivos do pacote; abra `pages/index.html` no endereço público HTTPS.
7. Teste com duas contas reais: uma comum e a master; tente editar permissões indevidamente, comentar, curtir, recuperar senha e confirmar antes/depois da hora.

## Limites da verificação
Análise feita sobre os arquivos do RAR, **sem acesso autenticado ao banco Supabase em produção**. Não foi possível verificar tabelas, dados ou políticas efetivamente implantadas, nem executar testes de integração de login/RLS ao vivo. A migração deverá ser aplicada pelo responsável pelo projeto; teste sintático JavaScript realizado localmente.
