# App Universal (white label)

Aplicativo white label com conta real e banco de dados próprio. Primeira marca aplicada: **Assembleia de Deus Ministério Madureira**.

Base: área do cliente do repositório `apoloweb/celeiro` (pasta `cliente/`, versão de 13/11/2026), que é a versão do app da Celeiro com banco de dados. No celular aparecem as abas embaixo; no computador, as mesmas abas viram o menu do topo.

## Arquivos

| Arquivo | Para que serve |
|---|---|
| `index.html` | O aplicativo (telas, estilo e comportamento) |
| `config.js` | Endereço e chave pública do banco do app e do Office que recebe as solicitações |
| `supabase.sql` | Tabelas, regras de acesso e vídeos iniciais, para rodar no Supabase do app |
| `termos.html` | Termos de Uso e Política de Privacidade (minuta, em revisão) |
| `marcas/ad-madureira/` | Logo original, símbolo sem o nome, ícone |

Publicação na Vercel: projeto apontando para a raiz deste repositório, Framework "Other", sem comando de build.

## Configuração no Supabase do app (uma vez)

1. **Rodar o SQL.** SQL Editor > New query > cole `supabase.sql` > Run. Pode rodar mais de uma vez.
2. **Abrir o cadastro.** Authentication > Sign In / Providers > "Allow new users to sign up" ligado.
3. **Exigir e-mail confirmado.** Na mesma tela, em Email, "Confirm email" ligado.
4. **Enviar código em vez de link.** Authentication > Emails > Templates. Em **Confirm signup** e em **Reset password**, o corpo precisa mostrar o código:

   ```html
   <h2>Confirme o seu e-mail</h2>
   <p>Use este código no aplicativo AD Ministério Madureira:</p>
   <p style="font-size:28px;letter-spacing:6px"><b>{{ .Token }}</b></p>
   <p>Se você não criou uma conta, ignore este e-mail.</p>
   ```

   Para Reset password, o mesmo com o título "Crie uma senha nova". Sem `{{ .Token }}` o e-mail chega com link e a tela do código não tem o que receber.
5. **Envio de e-mails.** Authentication > Emails > SMTP Settings com um SMTP próprio (por exemplo, Resend). Sem isso o Supabase limita a poucos e-mails por hora.
6. **Segunda etapa do administrador.** Authentication > Sign In / Providers > Multi-Factor: "TOTP (App Authenticator)" ligado.
7. **Endereço do app.** Authentication > URL Configuration: Site URL e Redirect URLs com o endereço onde o app for publicado.
8. **Pastas de arquivos.** Storage deve mostrar `videos` e `faturas`, as duas privadas (o SQL cria).

## Primeiro administrador

1. Crie a conta pelo próprio app (Criar conta) e confirme o e-mail.
2. No SQL Editor, rode o trecho do fim do `supabase.sql` (item 12) com o e-mail dessa conta.
3. No app, em Perfil, toque em **Entrar como administrador**, leia o código QR com o Google Authenticator e digite os 6 números. Nas próximas vezes, o app pede só os 6 números.

Em **Perfil > Administrar o aplicativo** ficam: Vídeos, Abaixo-assinados, Módulos (liga e desliga cada parte do app), Solicitações e Cadastros.

## Como a segurança funciona

- **Sem conta, nada aparece.** Vídeos, abaixo-assinados e solicitações só são entregues pelo banco a quem entrou e confirmou o e-mail. A lista de módulos é a única coisa pública.
- **Cada pessoa vê só o que é seu.** Outros assinantes aparecem com primeiro nome e inicial.
- **Administrador** precisa estar na tabela `administradores` **e** ter entrado com o autenticador. Sem o autenticador, vê o app como uma pessoa comum.
- **Saída automática** depois de 30 minutos sem uso.
- O app leva só chaves públicas. A chave `service_role` / `secret` nunca entra neste repositório.

## Envio ao Office da Celeiro

Cada cadastro novo (lead) e cada solicitação (veicular, energia, conta digital) é gravado no banco do app **e** copiado para o Office da Celeiro (`officeUrl` no `config.js`), com `app: "AD Madureira"` e, enquanto `teste: true`, marcado como teste. Para desligar a cópia, deixe `officeUrl` vazio.

## Como trocar de marca

| O que | Onde |
|---|---|
| Cores, fontes, raios | bloco `:root` no início do `<style>` do `index.html` (e o do `termos.html`) |
| Nome e símbolo | objeto `const MARCA={` no `<script>` do `index.html` |
| Arquivos da logo | pasta `marcas/<cliente>/` |
| Banco de dados | `config.js` |
| Vídeos iniciais | item 11 do `supabase.sql` |

Marca atual: índigo `#33327A` (institucional), amarelo `#FCBC19` (destaque), azul `#0272BD` (reserva), fonte Montserrat.

## Pendências

1. Imagens e vídeos da primeira tela interna: serão enviados pelo Paulo.
2. Texto institucional da igreja (tela "Quem somos").
3. Devocional e Bíblia online: ainda não construídos.
4. Visitante sem conta: hoje é preciso criar conta para ver qualquer conteúdo (a primeira versão, só de protótipo, deixava explorar sem cadastro).
5. Termos de Uso e Política de Privacidade: minuta adaptada da Celeiro. Falta definir quem responde pelos dados (igreja, Celeiro ou as duas), preencher o bloco `EMPRESA` no fim do `termos.html` e passar por revisão jurídica. O cadastro em um app de igreja pode indicar religião, que a LGPD trata como dado sensível.
6. Textos dos serviços (veicular, energia, conta digital) ainda citam a equipe da Celeiro, que é quem atende.
7. Conferir se cada vídeo do YouTube continua no ar e permite incorporação.
8. Autorização da igreja para uso da marca, das imagens e dos vídeos.
9. Login com Google e Apple: os botões aparecem sozinhos quando o provedor for ligado no Supabase.
