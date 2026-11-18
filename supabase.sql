-- App Universal · banco de dados do aplicativo (marca atual: AD Ministério Madureira)
-- Contas, vídeos, abaixo-assinados, assinaturas, solicitações de serviço, módulos e administração.
--
-- Rode este arquivo inteiro em: painel do Supabase > SQL Editor > New query > Run.
-- Pode ser rodado mais de uma vez sem duplicar nada.
-- Base: supabase.sql e supabase-cliente.sql do repositório apoloweb/celeiro.

-- =====================================================================
-- 0) ADMINISTRADORES
--    Regra central: é administrador E entrou com as duas etapas (senha + aplicativo autenticador).
-- =====================================================================

create table if not exists public.administradores (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  criado_em timestamptz not null default now()
);
alter table public.administradores enable row level security;

create or replace function public.eh_admin_2fa()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists (
       select 1 from public.administradores a
       where a.user_id = (select auth.uid())
     );
$$;

revoke all on function public.eh_admin_2fa() from public;
grant execute on function public.eh_admin_2fa() to authenticated;

revoke all on public.administradores from anon, authenticated;
grant select on public.administradores to authenticated;

drop policy if exists "admin ve o proprio registro" on public.administradores;
create policy "admin ve o proprio registro" on public.administradores
  for select to authenticated
  using (user_id = (select auth.uid()));

-- =====================================================================
-- 1) TABELAS
-- =====================================================================

-- Dados do cliente (o e-mail e a senha ficam no cadastro de acesso do Supabase)
create table if not exists public.clientes (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  nome          text not null check (char_length(nome) between 3 and 120),
  telefone      text check (telefone is null or char_length(telefone) <= 30),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create table if not exists public.videos (
  id         uuid primary key default gen_random_uuid(),
  titulo     text not null check (char_length(titulo) between 1 and 160),
  descricao  text not null default '' check (char_length(descricao) <= 4000),
  categoria  text not null default 'Institucional' check (char_length(categoria) between 1 and 40),
  origem     text not null check (origem in ('link', 'arquivo')),
  url        text check (url is null or (url ~ '^https://' and char_length(url) <= 500)),
  arquivo    text check (arquivo is null or char_length(arquivo) <= 300),
  publicado  boolean not null default true,
  criado_em  timestamptz not null default now(),
  constraint videos_origem check (
    (origem = 'link' and url is not null) or (origem = 'arquivo' and arquivo is not null)
  )
);

create table if not exists public.abaixo_assinados (
  id        uuid primary key default gen_random_uuid(),
  titulo    text not null check (char_length(titulo) between 1 and 160),
  resumo    text not null default '' check (char_length(resumo) <= 300),
  texto     text not null check (char_length(texto) between 1 and 8000),
  meta      int  not null check (meta > 0),
  prazo     date not null,
  aberto    boolean not null default true,
  criado_em timestamptz not null default now()
);

create table if not exists public.assinaturas (
  id        uuid primary key default gen_random_uuid(),
  abaixo_id uuid not null references public.abaixo_assinados(id) on delete restrict,
  user_id   uuid not null references auth.users(id) on delete restrict,
  nome      text not null,
  cpf       text not null,
  protocolo text not null unique,
  ip        text,
  criado_em timestamptz not null default now(),
  unique (abaixo_id, user_id),
  unique (abaixo_id, cpf)
);

create table if not exists public.solicitacoes (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  tipo           text not null check (tipo in ('conta_digital', 'cotacao_veicular', 'migracao_energia')),
  dados          jsonb not null default '{}'::jsonb check (length(dados::text) <= 8000),
  protocolo      text not null check (char_length(protocolo) between 4 and 40),
  enviado_office boolean not null default false,
  criado_em      timestamptz not null default now()
);

create index if not exists assinaturas_abaixo_data on public.assinaturas (abaixo_id, criado_em desc);

-- Como cada assinatura foi confirmada e as provas guardadas com ela.
--   metodo        'senha' (CPF e senha da conta) ou 'biometria' (biometria do aparelho)
--   aparelho      navegador e sistema informados pelo aparelho
--   texto_hash    resumo SHA-256 do título e do texto no momento da assinatura
--   declaracao    o que foi assinado com a biometria (documento, CPF, conta, data), em texto
--   credencial_id, chave_publica e prova: dados para conferir a assinatura biométrica depois
alter table public.assinaturas
  add column if not exists metodo        text not null default 'senha',
  add column if not exists aparelho      text,
  add column if not exists texto_hash    text,
  add column if not exists declaracao    text,
  add column if not exists credencial_id text,
  add column if not exists chave_publica text,
  add column if not exists prova         jsonb;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'assinaturas_metodo_check') then
    alter table public.assinaturas
      add constraint assinaturas_metodo_check check (metodo in ('senha', 'biometria'));
  end if;
end $$;
create index if not exists solicitacoes_user_data on public.solicitacoes (user_id, criado_em desc);

alter table public.clientes         enable row level security;
alter table public.videos           enable row level security;
alter table public.abaixo_assinados enable row level security;
alter table public.assinaturas      enable row level security;
alter table public.solicitacoes     enable row level security;

-- =====================================================================
-- 2) FUNÇÕES DE APOIO
-- =====================================================================

-- Está logado e já confirmou o e-mail
create or replace function public.acesso_confirmado()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from auth.users u
    where u.id = (select auth.uid()) and u.email_confirmed_at is not null
  );
$$;

-- Confere os dois dígitos verificadores do CPF
create or replace function public.cpf_valido(p_cpf text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  d text := regexp_replace(coalesce(p_cpf, ''), '[^0-9]', '', 'g');
  s int; r int; i int;
begin
  if length(d) <> 11 or d ~ '^(.)\1{10}$' then
    return false;
  end if;
  s := 0;
  for i in 1..9 loop s := s + substr(d, i, 1)::int * (11 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  if r <> substr(d, 10, 1)::int then return false; end if;
  s := 0;
  for i in 1..10 loop s := s + substr(d, i, 1)::int * (12 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  return r = substr(d, 11, 1)::int;
end;
$$;

-- "Marina Lopes da Silva" vira "Marina S." na lista pública de assinantes
create or replace function public.nome_curto(p_nome text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when array_length(p, 1) is null then 'Assinante'
    when array_length(p, 1) = 1 then p[1]
    else p[1] || ' ' || upper(left(p[array_length(p, 1)], 1)) || '.'
  end
  from (select regexp_split_to_array(trim(coalesce(p_nome, '')), '\s+') as p) x;
$$;

-- =====================================================================
-- 3) ABAIXO-ASSINADOS
-- =====================================================================

-- Lista para o cliente: totais, se ele já assinou e as últimas assinaturas (nomes abreviados)
create or replace function public.abaixo_listar()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.acesso_confirmado() then
    raise exception 'Acesso negado';
  end if;
  return coalesce((
    select jsonb_agg(x.j order by x.aberto desc, x.prazo, x.criado_em desc)
    from (
      select a.aberto, a.prazo, a.criado_em,
        jsonb_build_object(
          'id', a.id, 'titulo', a.titulo, 'resumo', a.resumo, 'texto', a.texto,
          'meta', a.meta, 'prazo', a.prazo,
          'aberto', a.aberto and a.prazo >= (now() at time zone 'America/Sao_Paulo')::date,
          'total', (select count(*) from public.assinaturas s where s.abaixo_id = a.id),
          'minha', (select jsonb_build_object('protocolo', s.protocolo, 'data', s.criado_em, 'metodo', s.metodo)
                    from public.assinaturas s where s.abaixo_id = a.id and s.user_id = (select auth.uid())),
          'ultimas', coalesce((
            select jsonb_agg(jsonb_build_object('nome', public.nome_curto(u.nome), 'data', u.criado_em) order by u.criado_em desc)
            from (select s.nome, s.criado_em from public.assinaturas s
                  where s.abaixo_id = a.id order by s.criado_em desc limit 5) u), '[]'::jsonb)
        ) as j
      from public.abaixo_assinados a
    ) x), '[]'::jsonb);
end;
$$;

-- Resumo (SHA-256, em hexadecimal) do título e do texto de um abaixo-assinado.
create or replace function public.abaixo_texto_hash(p_titulo text, p_texto text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(sha256(convert_to(coalesce(p_titulo, '') || E'\n' || coalesce(p_texto, ''), 'UTF8')), 'hex');
$$;

-- Assina com CPF e senha. Uma assinatura por conta e por CPF em cada abaixo-assinado.
create or replace function public.assinar(p_id uuid, p_cpf text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_nome text;
  v_cpf  text := regexp_replace(coalesce(p_cpf, ''), '[^0-9]', '', 'g');
  v_a    public.abaixo_assinados%rowtype;
  v_prot text;
  v_ip   text;
  v_ag   text;
  v_em   timestamptz;
begin
  if not public.acesso_confirmado() then
    raise exception 'Acesso negado';
  end if;
  select nome into v_nome from public.clientes where user_id = v_user;
  if v_nome is null then
    raise exception 'Complete o seu cadastro antes de assinar';
  end if;
  if not public.cpf_valido(v_cpf) then
    raise exception 'CPF inválido';
  end if;
  select * into v_a from public.abaixo_assinados where id = p_id;
  if v_a.id is null then
    raise exception 'Abaixo-assinado não encontrado';
  end if;
  if not v_a.aberto or v_a.prazo < (now() at time zone 'America/Sao_Paulo')::date then
    raise exception 'Este abaixo-assinado está encerrado';
  end if;
  if exists (select 1 from public.assinaturas where abaixo_id = p_id and user_id = v_user) then
    raise exception 'Você já assinou este abaixo-assinado';
  end if;
  if exists (select 1 from public.assinaturas where abaixo_id = p_id and cpf = v_cpf) then
    raise exception 'Este CPF já assinou este abaixo-assinado';
  end if;

  begin
    v_ip := split_part(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ',', 1);
    v_ag := left(current_setting('request.headers', true)::json ->> 'user-agent', 300);
  exception when others then
    v_ip := null;
  end;
  v_prot := 'ADM-' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYY') || '-' ||
            upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  insert into public.assinaturas (abaixo_id, user_id, nome, cpf, protocolo, ip, metodo, aparelho, texto_hash)
  values (p_id, v_user, v_nome, v_cpf, v_prot, nullif(trim(v_ip), ''), 'senha', nullif(trim(v_ag), ''),
          public.abaixo_texto_hash(v_a.titulo, v_a.texto))
  returning criado_em into v_em;

  return jsonb_build_object('protocolo', v_prot, 'data', v_em, 'metodo', 'senha');
end;
$$;

-- =====================================================================
-- 4) PERMISSÕES
-- =====================================================================

revoke all on public.clientes, public.videos, public.abaixo_assinados, public.assinaturas, public.solicitacoes from anon, authenticated;

grant select, insert on public.clientes to authenticated;
grant update (nome, telefone, atualizado_em) on public.clientes to authenticated;
grant select, insert, update, delete on public.videos to authenticated;
grant select, insert, update on public.abaixo_assinados to authenticated;
grant select on public.assinaturas to authenticated;
grant select, insert on public.solicitacoes to authenticated;
grant update (enviado_office) on public.solicitacoes to authenticated;

revoke all on function public.acesso_confirmado()  from public, anon;
revoke all on function public.abaixo_listar()      from public, anon;
revoke all on function public.assinar(uuid, text)  from public, anon;
grant execute on function public.acesso_confirmado() to authenticated;
grant execute on function public.abaixo_listar()     to authenticated;
grant execute on function public.assinar(uuid, text) to authenticated;
grant execute on function public.cpf_valido(text)    to authenticated;
grant execute on function public.nome_curto(text)    to authenticated;

-- =====================================================================
-- 5) REGRAS DE ACESSO POR LINHA
--    Cliente: só com o e-mail confirmado, e só os próprios dados.
--    Conteúdo: quem grava é administrador do site com as duas etapas de login.
-- =====================================================================

drop policy if exists "cliente le o proprio cadastro" on public.clientes;
create policy "cliente le o proprio cadastro" on public.clientes
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.eh_admin_2fa()));

drop policy if exists "cliente cria o proprio cadastro" on public.clientes;
create policy "cliente cria o proprio cadastro" on public.clientes
  for insert to authenticated
  with check (user_id = (select auth.uid()) and (select public.acesso_confirmado()));

drop policy if exists "cliente altera o proprio cadastro" on public.clientes;
create policy "cliente altera o proprio cadastro" on public.clientes
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists "clientes veem videos publicados" on public.videos;
create policy "clientes veem videos publicados" on public.videos
  for select to authenticated
  using (((select public.acesso_confirmado()) and publicado) or (select public.eh_admin_2fa()));

drop policy if exists "admin 2fa gerencia videos" on public.videos;
create policy "admin 2fa gerencia videos" on public.videos
  for all to authenticated
  using ((select public.eh_admin_2fa()))
  with check ((select public.eh_admin_2fa()));

drop policy if exists "clientes veem abaixo-assinados" on public.abaixo_assinados;
create policy "clientes veem abaixo-assinados" on public.abaixo_assinados
  for select to authenticated
  using ((select public.acesso_confirmado()) or (select public.eh_admin_2fa()));

drop policy if exists "admin 2fa cria abaixo-assinados" on public.abaixo_assinados;
create policy "admin 2fa cria abaixo-assinados" on public.abaixo_assinados
  for insert to authenticated
  with check ((select public.eh_admin_2fa()));

drop policy if exists "admin 2fa altera abaixo-assinados" on public.abaixo_assinados;
create policy "admin 2fa altera abaixo-assinados" on public.abaixo_assinados
  for update to authenticated
  using ((select public.eh_admin_2fa()))
  with check ((select public.eh_admin_2fa()));

-- Assinatura só entra pela função assinar; ninguém altera nem apaga
drop policy if exists "assinante ve a propria assinatura" on public.assinaturas;
create policy "assinante ve a propria assinatura" on public.assinaturas
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.eh_admin_2fa()));

drop policy if exists "cliente ve as proprias solicitacoes" on public.solicitacoes;
create policy "cliente ve as proprias solicitacoes" on public.solicitacoes
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.eh_admin_2fa()));

drop policy if exists "cliente cria solicitacao" on public.solicitacoes;
create policy "cliente cria solicitacao" on public.solicitacoes
  for insert to authenticated
  with check (user_id = (select auth.uid()) and (select public.acesso_confirmado()));

drop policy if exists "cliente marca envio ao office" on public.solicitacoes;
create policy "cliente marca envio ao office" on public.solicitacoes
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- =====================================================================
-- 6) ARQUIVOS DE VÍDEO (Storage)
--    Pasta privada: cliente assiste por link temporário; só administrador envia e apaga.
-- =====================================================================

insert into storage.buckets (id, name, public)
values ('videos', 'videos', false)
on conflict (id) do nothing;

drop policy if exists "clientes assistem videos" on storage.objects;
create policy "clientes assistem videos" on storage.objects
  for select to authenticated
  using (bucket_id = 'videos' and ((select public.acesso_confirmado()) or (select public.eh_admin_2fa())));

drop policy if exists "admin 2fa envia videos" on storage.objects;
create policy "admin 2fa envia videos" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'videos' and (select public.eh_admin_2fa()));

drop policy if exists "admin 2fa apaga videos" on storage.objects;
create policy "admin 2fa apaga videos" on storage.objects
  for delete to authenticated
  using (bucket_id = 'videos' and (select public.eh_admin_2fa()));

-- =====================================================================
-- 7) ACEITE DOS TERMOS
--    Guarda a versão dos Termos de Uso e da Política de Privacidade aceita no cadastro.
-- =====================================================================

alter table public.clientes add column if not exists termos_versao     text check (termos_versao is null or char_length(termos_versao) <= 20);
alter table public.clientes add column if not exists termos_aceitos_em timestamptz;

-- =====================================================================
-- 8) CÓPIA DA FATURA DE ENERGIA (Storage)
--    Pasta privada. Cada cliente envia e lê só dentro da própria pasta (o nome da pasta é o
--    identificador da conta). Administrador com as duas etapas lê todas. Ninguém apaga pela página.
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('faturas', 'faturas', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "cliente envia a propria fatura" on storage.objects;
create policy "cliente envia a propria fatura" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'faturas'
              and (storage.foldername(name))[1] = (select auth.uid())::text
              and (select public.acesso_confirmado()));

drop policy if exists "cliente le a propria fatura" on storage.objects;
create policy "cliente le a propria fatura" on storage.objects
  for select to authenticated
  using (bucket_id = 'faturas'
         and ((storage.foldername(name))[1] = (select auth.uid())::text or (select public.eh_admin_2fa())));

-- =====================================================================
-- 9) MÓDULOS DO APLICATIVO
--    Cada parte do app pode ser ligada ou desligada na tela Administrar > Módulos.
--    Todos leem (a tela de entrada precisa saber o que mostrar); só administrador altera.
-- =====================================================================

create table if not exists public.modulos (
  codigo        text primary key check (codigo in ('videos', 'assinaturas', 'veicular', 'energia', 'conta')),
  habilitado    boolean not null default true,
  atualizado_em timestamptz not null default now()
);
alter table public.modulos enable row level security;

insert into public.modulos (codigo) values
  ('videos'), ('assinaturas'), ('veicular'), ('energia'), ('conta')
on conflict (codigo) do nothing;

revoke all on public.modulos from anon, authenticated;
grant select on public.modulos to anon, authenticated;
grant insert, update on public.modulos to authenticated;

drop policy if exists "todos leem os modulos" on public.modulos;
create policy "todos leem os modulos" on public.modulos
  for select to anon, authenticated
  using (true);

drop policy if exists "admin 2fa cria modulos" on public.modulos;
create policy "admin 2fa cria modulos" on public.modulos
  for insert to authenticated
  with check ((select public.eh_admin_2fa()));

drop policy if exists "admin 2fa altera modulos" on public.modulos;
create policy "admin 2fa altera modulos" on public.modulos
  for update to authenticated
  using ((select public.eh_admin_2fa()))
  with check ((select public.eh_admin_2fa()));

-- =====================================================================
-- 10) PAINEL DO ADMINISTRADOR
--     Cadastros e solicitações de todas as pessoas, com o e-mail de cada conta.
--     Só responde a administrador que entrou com as duas etapas.
-- =====================================================================

create or replace function public.admin_painel()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.eh_admin_2fa() then
    raise exception 'Acesso negado';
  end if;
  return jsonb_build_object(
    'totais', jsonb_build_object(
      'cadastros',    (select count(*) from public.clientes),
      'solicitacoes', (select count(*) from public.solicitacoes),
      'assinaturas',  (select count(*) from public.assinaturas)),
    'cadastros', coalesce((
      select jsonb_agg(jsonb_build_object(
               'nome', x.nome, 'telefone', x.telefone, 'email', x.email, 'criado_em', x.criado_em)
             order by x.criado_em desc)
      from (select c.nome, c.telefone, u.email, c.criado_em
            from public.clientes c join auth.users u on u.id = c.user_id
            order by c.criado_em desc limit 500) x), '[]'::jsonb),
    'solicitacoes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', x.id, 'tipo', x.tipo, 'protocolo', x.protocolo, 'dados', x.dados,
               'enviado_office', x.enviado_office, 'criado_em', x.criado_em,
               'nome', x.nome, 'telefone', x.telefone, 'email', x.email)
             order by x.criado_em desc)
      from (select s.id, s.tipo, s.protocolo, s.dados, s.enviado_office, s.criado_em,
                   c.nome, c.telefone, u.email
            from public.solicitacoes s
            join auth.users u on u.id = s.user_id
            left join public.clientes c on c.user_id = s.user_id
            order by s.criado_em desc limit 500) x), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.admin_painel() from public, anon;
grant execute on function public.admin_painel() to authenticated;

-- =====================================================================
-- 11) VÍDEOS INICIAIS
--     Mensagens do Bispo Samuel Ferreira e músicas cristãs, pelo player do YouTube.
--     Todos conferidos em 15/11/2026: públicos e com exibição fora do YouTube permitida.
--     Cada vídeo só entra se o endereço ainda não estiver na tabela.
--     Os vídeos do programa Palavra de Vida que entraram na primeira versão foram
--     tornados privados no YouTube e são retirados aqui.
-- =====================================================================

delete from public.videos
where url in (
  'https://www.youtube.com/watch?v=AJu97sk9yNk', 'https://www.youtube.com/watch?v=Ytq2SPpjU4w',
  'https://www.youtube.com/watch?v=6-2eGj0iJbQ', 'https://www.youtube.com/watch?v=gGVoWxRxehk',
  'https://www.youtube.com/watch?v=Vv47Lwc99uQ', 'https://www.youtube.com/watch?v=qmJfN653BeE',
  'https://www.youtube.com/watch?v=tBmtdRNZMEU', 'https://www.youtube.com/watch?v=iBa4tDVJId8',
  'https://www.youtube.com/watch?v=dG6L5RlR3SY', 'https://www.youtube.com/watch?v=YpmRyN5rt0A'
);

insert into public.videos (titulo, descricao, categoria, origem, url, criado_em)
select v.titulo, v.descricao, v.categoria, 'link',
       'https://www.youtube.com/watch?v=' || v.codigo, now() - (v.ordem * interval '1 minute')
from (values
  (1,  'Que darei eu ao Senhor?',                        'Mensagem do Bispo Samuel Ferreira. Canal AD Brás Itapevi.',        'Mensagens', 'pkP_qKK-WWY'),
  (2,  'Ministração na CIBEN 2022',                      'Ministração do Bispo Samuel Ferreira. Canal TV AD Brás Alagoas.',  'Mensagens', 'sq97YEEkdiY'),
  (3,  'Cassiane - Hino da Vitória',                     'Clipe oficial. Canal MK Music.',                                  'Músicas',   'cWA81k-7kp0'),
  (4,  'Cassiane - Com Muito Louvor (Ao Vivo)',          'Canal oficial da Cassiane.',                                      'Músicas',   '440SucDfC2Y'),
  (5,  'Aline Barros - Ressuscita-me',                   'Clipe oficial. Canal MK Music.',                                  'Músicas',   'dc6oADkbQSw'),
  (6,  'Aline Barros - Jeová Jireh',                     'Clipe oficial. Canal oficial da Aline Barros.',                   'Músicas',   'YyFd_dXy494'),
  (7,  'Gabriela Rocha - Me Atraiu (Ao Vivo)',           'Canal oficial da Gabriela Rocha.',                                'Músicas',   'Z6cONvRUFZQ'),
  (8,  'Fernandinho - Uma Nova História',                'Clipe oficial. Canal oficial do Fernandinho.',                    'Músicas',   'SdkWBHLHTgg'),
  (9,  'Anderson Freire - Raridade',                     'Vídeo com letra. Canal oficial do Anderson Freire.',              'Músicas',   'WdYO0JtOm0A'),
  (10, 'Bruna Karla - Oh Quão Lindo Esse Nome É',        'Clipe oficial. Canal oficial da Bruna Karla.',                    'Músicas',   'syT__AJIm7E'),
  (11, 'Shirley Carvalhaes - Vendavais (Ao Vivo)',       'Canal Art Music.',                                                'Músicas',   'p5ud6iDG2kc')
) as v(ordem, titulo, descricao, categoria, codigo)
where not exists (
  select 1 from public.videos x where x.url = 'https://www.youtube.com/watch?v=' || v.codigo
);

-- =====================================================================
-- 12) TORNAR UMA CONTA ADMINISTRADORA
--     Primeiro crie a conta pelo próprio aplicativo (Criar conta) e confirme o e-mail.
--     Depois troque o e-mail abaixo, tire os dois traços do início das três linhas e rode só elas:
-- =====================================================================
-- insert into public.administradores (user_id)
-- select id from auth.users where email = 'seu-email@exemplo.com.br'
-- on conflict do nothing;

-- =====================================================================
-- 13) ASSINATURA COM A BIOMETRIA DO APARELHO
--     A pessoa confirma a assinatura com a digital ou o rosto do próprio aparelho (padrão WebAuthn).
--     A biometria nunca sai do aparelho: o que chega aqui é uma chave pública, cadastrada uma vez
--     por aparelho, e a cada assinatura uma confirmação criptográfica ligada ao texto assinado.
--     Quem confere a confirmação é a função de servidor "assinatura-biometrica"; as operações
--     abaixo só respondem a ela (papel service_role), nunca ao navegador.
-- =====================================================================

create table if not exists public.biometria_credenciais (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  credencial_id text not null unique,
  chave_publica text not null,
  contador      bigint not null default 0,
  transportes   text[] not null default '{}',
  aparelho      text,
  criado_em     timestamptz not null default now(),
  usado_em      timestamptz
);
create index if not exists biometria_credenciais_user on public.biometria_credenciais (user_id);

create table if not exists public.biometria_desafios (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  tipo          text not null check (tipo in ('registro', 'assinatura')),
  desafio       text not null,
  abaixo_id     uuid references public.abaixo_assinados(id) on delete cascade,
  cpf           text,
  texto_hash    text,
  declaracao    text,
  credencial_id text,
  criado_em     timestamptz not null default now(),
  expira_em     timestamptz not null default now() + interval '5 minutes',
  usado_em      timestamptz,
  concluido_em  timestamptz
);
create index if not exists biometria_desafios_user on public.biometria_desafios (user_id, criado_em desc);

alter table public.biometria_credenciais enable row level security;
alter table public.biometria_desafios    enable row level security;
revoke all on public.biometria_credenciais, public.biometria_desafios from anon, authenticated;

-- Conta com e-mail confirmado e cadastro feito (mesma regra do app, para uso pela função de servidor).
create or replace function public.bio_conta_ok(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from auth.users u where u.id = p_user and u.email_confirmed_at is not null)
     and exists (select 1 from public.clientes c where c.user_id = p_user);
$$;

-- Confere se a pessoa pode assinar aquele abaixo-assinado com aquele CPF. Devolve o texto do erro ou null.
create or replace function public.bio_pode_assinar(p_user uuid, p_abaixo uuid, p_cpf text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_a public.abaixo_assinados%rowtype;
begin
  if not public.bio_conta_ok(p_user) then
    return 'Complete o seu cadastro antes de assinar';
  end if;
  if not public.cpf_valido(p_cpf) then
    return 'CPF inválido';
  end if;
  select * into v_a from public.abaixo_assinados where id = p_abaixo;
  if v_a.id is null then
    return 'Abaixo-assinado não encontrado';
  end if;
  if not v_a.aberto or v_a.prazo < (now() at time zone 'America/Sao_Paulo')::date then
    return 'Este abaixo-assinado está encerrado';
  end if;
  if exists (select 1 from public.assinaturas where abaixo_id = p_abaixo and user_id = p_user) then
    return 'Você já assinou este abaixo-assinado';
  end if;
  if exists (select 1 from public.assinaturas where abaixo_id = p_abaixo and cpf = p_cpf) then
    return 'Este CPF já assinou este abaixo-assinado';
  end if;
  return null;
end;
$$;

-- Cadastro da biometria do aparelho, passo 1: guarda o desafio gerado pela função de servidor.
create or replace function public.bio_registro_iniciar(p_user uuid, p_desafio text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id   uuid;
  v_nome text;
  v_mail text;
begin
  if not public.bio_conta_ok(p_user) then
    return jsonb_build_object('erro', 'Complete o seu cadastro antes de assinar');
  end if;
  if coalesce(length(p_desafio), 0) < 20 then
    return jsonb_build_object('erro', 'Pedido inválido');
  end if;
  delete from public.biometria_desafios where criado_em < now() - interval '1 day';
  if (select count(*) from public.biometria_desafios
      where user_id = p_user and criado_em > now() - interval '10 minutes') >= 30 then
    return jsonb_build_object('erro', 'Muitas tentativas em pouco tempo. Espere alguns minutos e tente de novo.');
  end if;
  select nome into v_nome from public.clientes where user_id = p_user;
  select email into v_mail from auth.users where id = p_user;
  insert into public.biometria_desafios (user_id, tipo, desafio) values (p_user, 'registro', p_desafio)
  returning id into v_id;
  return jsonb_build_object(
    'desafio_id', v_id, 'nome', v_nome, 'email', v_mail,
    'credenciais', coalesce((select jsonb_agg(jsonb_build_object('id', c.credencial_id, 'transportes', c.transportes))
                             from public.biometria_credenciais c where c.user_id = p_user), '[]'::jsonb));
end;
$$;

-- Usa um desafio uma única vez e devolve o que a função de servidor precisa para conferir a resposta do aparelho.
create or replace function public.bio_desafio_usar(p_user uuid, p_desafio_id uuid, p_tipo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_d public.biometria_desafios%rowtype;
  v_c public.biometria_credenciais%rowtype;
begin
  update public.biometria_desafios
     set usado_em = now()
   where id = p_desafio_id and user_id = p_user and tipo = p_tipo
     and usado_em is null and expira_em > now()
  returning * into v_d;
  if v_d.id is null then
    return jsonb_build_object('erro', 'O tempo para confirmar acabou. Comece de novo.');
  end if;
  if p_tipo = 'assinatura' then
    select * into v_c from public.biometria_credenciais
     where credencial_id = v_d.credencial_id and user_id = p_user;
    if v_c.id is null then
      return jsonb_build_object('erro', 'A biometria deste aparelho não está cadastrada.');
    end if;
  end if;
  return jsonb_build_object(
    'desafio', v_d.desafio, 'credencial_id', v_c.credencial_id, 'chave_publica', v_c.chave_publica,
    'contador', v_c.contador, 'transportes', to_jsonb(coalesce(v_c.transportes, '{}'::text[])));
end;
$$;

-- Cadastro da biometria do aparelho, passo 2: guarda a chave pública já conferida pela função de servidor.
create or replace function public.bio_registro_concluir(
  p_user uuid, p_desafio_id uuid, p_credencial text, p_chave text, p_contador bigint,
  p_transportes text[], p_aparelho text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.biometria_desafios
                 where id = p_desafio_id and user_id = p_user and tipo = 'registro'
                   and usado_em is not null and concluido_em is null
                   and usado_em > now() - interval '2 minutes') then
    return jsonb_build_object('erro', 'O tempo para confirmar acabou. Comece de novo.');
  end if;
  if coalesce(p_credencial, '') = '' or coalesce(p_chave, '') = '' then
    return jsonb_build_object('erro', 'Pedido inválido');
  end if;
  if exists (select 1 from public.biometria_credenciais where credencial_id = p_credencial and user_id <> p_user) then
    return jsonb_build_object('erro', 'Esta biometria já está cadastrada em outra conta.');
  end if;
  if (select count(*) from public.biometria_credenciais where user_id = p_user) >= 10
     and not exists (select 1 from public.biometria_credenciais where credencial_id = p_credencial) then
    return jsonb_build_object('erro', 'Esta conta já tem o número máximo de aparelhos cadastrados.');
  end if;
  insert into public.biometria_credenciais (user_id, credencial_id, chave_publica, contador, transportes, aparelho)
  values (p_user, p_credencial, p_chave, coalesce(p_contador, 0), coalesce(p_transportes, '{}'), left(p_aparelho, 300))
  on conflict (credencial_id) do update
    set chave_publica = excluded.chave_publica, contador = excluded.contador,
        transportes = excluded.transportes, aparelho = excluded.aparelho;
  update public.biometria_desafios set concluido_em = now() where id = p_desafio_id;
  return jsonb_build_object('ok', true, 'credencial_id', p_credencial);
end;
$$;

-- Assinatura com biometria, passo 1: confere se a pessoa pode assinar, monta a declaração que será
-- assinada e o desafio, que é o resumo SHA-256 dessa declaração (assim a confirmação do aparelho
-- fica presa ao documento, ao CPF, à conta e ao momento).
create or replace function public.bio_assinatura_iniciar(p_user uuid, p_abaixo uuid, p_cpf text, p_credencial text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cpf  text := regexp_replace(coalesce(p_cpf, ''), '[^0-9]', '', 'g');
  v_erro text;
  v_a    public.abaixo_assinados%rowtype;
  v_c    public.biometria_credenciais%rowtype;
  v_nome text;
  v_hash text;
  v_decl text;
  v_des  text;
  v_id   uuid;
begin
  v_erro := public.bio_pode_assinar(p_user, p_abaixo, v_cpf);
  if v_erro is not null then
    return jsonb_build_object('erro', v_erro);
  end if;
  select * into v_c from public.biometria_credenciais where credencial_id = p_credencial and user_id = p_user;
  if v_c.id is null then
    return jsonb_build_object('erro', 'A biometria deste aparelho não está cadastrada.', 'sem_credencial', true);
  end if;
  if (select count(*) from public.biometria_desafios
      where user_id = p_user and criado_em > now() - interval '10 minutes') >= 30 then
    return jsonb_build_object('erro', 'Muitas tentativas em pouco tempo. Espere alguns minutos e tente de novo.');
  end if;
  select * into v_a from public.abaixo_assinados where id = p_abaixo;
  select nome into v_nome from public.clientes where user_id = p_user;
  v_hash := public.abaixo_texto_hash(v_a.titulo, v_a.texto);
  v_decl := jsonb_build_object(
    'ato', 'assinatura de abaixo-assinado',
    'abaixo_id', p_abaixo, 'titulo', v_a.titulo, 'texto_sha256', v_hash,
    'assinante', v_nome, 'cpf', v_cpf, 'conta', p_user, 'credencial', p_credencial,
    'emitido_em', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'nonce', replace(gen_random_uuid()::text, '-', ''))::text;
  v_des := rtrim(translate(encode(sha256(convert_to(v_decl, 'UTF8')), 'base64'), '+/', '-_'), '=');
  insert into public.biometria_desafios (user_id, tipo, desafio, abaixo_id, cpf, texto_hash, declaracao, credencial_id)
  values (p_user, 'assinatura', v_des, p_abaixo, v_cpf, v_hash, v_decl, p_credencial)
  returning id into v_id;
  return jsonb_build_object('desafio_id', v_id, 'desafio', v_des, 'declaracao', v_decl,
                            'transportes', to_jsonb(v_c.transportes));
end;
$$;

-- Assinatura com biometria, passo 2: grava a assinatura depois que a função de servidor conferiu a confirmação do aparelho.
create or replace function public.bio_assinatura_concluir(
  p_user uuid, p_desafio_id uuid, p_contador bigint, p_ip text, p_aparelho text, p_prova jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_d    public.biometria_desafios%rowtype;
  v_c    public.biometria_credenciais%rowtype;
  v_erro text;
  v_nome text;
  v_prot text;
  v_em   timestamptz;
begin
  select * into v_d from public.biometria_desafios
   where id = p_desafio_id and user_id = p_user and tipo = 'assinatura'
     and usado_em is not null and concluido_em is null
     and usado_em > now() - interval '2 minutes'
   for update;
  if v_d.id is null then
    return jsonb_build_object('erro', 'O tempo para confirmar acabou. Comece de novo.');
  end if;
  select * into v_c from public.biometria_credenciais where credencial_id = v_d.credencial_id and user_id = p_user;
  if v_c.id is null then
    return jsonb_build_object('erro', 'A biometria deste aparelho não está cadastrada.');
  end if;
  v_erro := public.bio_pode_assinar(p_user, v_d.abaixo_id, v_d.cpf);
  if v_erro is not null then
    return jsonb_build_object('erro', v_erro);
  end if;
  if v_d.texto_hash is distinct from (select public.abaixo_texto_hash(a.titulo, a.texto)
                                      from public.abaixo_assinados a where a.id = v_d.abaixo_id) then
    return jsonb_build_object('erro', 'O texto do abaixo-assinado mudou. Leia de novo e assine outra vez.');
  end if;
  select nome into v_nome from public.clientes where user_id = p_user;
  v_prot := 'ADM-' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYY') || '-' ||
            upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  insert into public.assinaturas (abaixo_id, user_id, nome, cpf, protocolo, ip, metodo, aparelho,
                                  texto_hash, declaracao, credencial_id, chave_publica, prova)
  values (v_d.abaixo_id, p_user, v_nome, v_d.cpf, v_prot, nullif(trim(split_part(coalesce(p_ip, ''), ',', 1)), ''),
          'biometria', nullif(left(trim(coalesce(p_aparelho, '')), 300), ''),
          v_d.texto_hash, v_d.declaracao, v_c.credencial_id, v_c.chave_publica, p_prova)
  returning criado_em into v_em;
  update public.biometria_credenciais set contador = greatest(contador, coalesce(p_contador, 0)), usado_em = now()
   where id = v_c.id;
  update public.biometria_desafios set concluido_em = now() where id = v_d.id;
  return jsonb_build_object('protocolo', v_prot, 'data', v_em, 'metodo', 'biometria');
end;
$$;

-- Só a função de servidor (service_role) chama estas operações.
revoke all on function public.bio_conta_ok(uuid)                                              from public, anon, authenticated;
revoke all on function public.bio_pode_assinar(uuid, uuid, text)                              from public, anon, authenticated;
revoke all on function public.bio_registro_iniciar(uuid, text)                                from public, anon, authenticated;
revoke all on function public.bio_desafio_usar(uuid, uuid, text)                              from public, anon, authenticated;
revoke all on function public.bio_registro_concluir(uuid, uuid, text, text, bigint, text[], text) from public, anon, authenticated;
revoke all on function public.bio_assinatura_iniciar(uuid, uuid, text, text)                  from public, anon, authenticated;
revoke all on function public.bio_assinatura_concluir(uuid, uuid, bigint, text, text, jsonb)  from public, anon, authenticated;
grant execute on function public.bio_registro_iniciar(uuid, text)                                 to service_role;
grant execute on function public.bio_desafio_usar(uuid, uuid, text)                               to service_role;
grant execute on function public.bio_registro_concluir(uuid, uuid, text, text, bigint, text[], text) to service_role;
grant execute on function public.bio_assinatura_iniciar(uuid, uuid, text, text)                   to service_role;
grant execute on function public.bio_assinatura_concluir(uuid, uuid, bigint, text, text, jsonb)   to service_role;
grant execute on function public.abaixo_texto_hash(text, text) to authenticated, service_role;
