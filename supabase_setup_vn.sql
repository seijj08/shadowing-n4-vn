-- ============================================================================
-- Shadowing N4 ベトナム版 — ログイン＋学習履歴トラッキング用セットアップ
-- 既存のインドネシア/ミャンマー版（sh_）とは独立した shvn_ プレフィックスで作成。
-- staff_pin は本家と同じ 'n4admin' を初期設定。
-- 人材登録例:
--   insert into public.shvn_users (user_id, name, pin) values ('nguyen', 'Nguyen Van A', '1234');
-- ============================================================================

create table if not exists public.shvn_users (
  user_id    text primary key,
  name       text not null,
  pin        text not null,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.shvn_logins (
  id      bigint generated always as identity primary key,
  user_id text not null references public.shvn_users(user_id),
  ts      timestamptz not null default now()
);

create table if not exists public.shvn_play_events (
  id          bigint generated always as identity primary key,
  user_id     text not null references public.shvn_users(user_id),
  sentence_id text not null,
  mode        text not null,
  ts          timestamptz not null default now()
);

create table if not exists public.shvn_settings (
  key   text primary key,
  value text not null
);

insert into public.shvn_settings (key, value) values ('staff_pin', 'n4admin')
  on conflict (key) do nothing;

create index if not exists shvn_logins_user_ts_idx      on public.shvn_logins (user_id, ts desc);
create index if not exists shvn_logins_ts_idx           on public.shvn_logins (ts desc);
create index if not exists shvn_play_events_user_ts_idx on public.shvn_play_events (user_id, ts desc);
create index if not exists shvn_play_events_ts_idx      on public.shvn_play_events (ts desc);

alter table public.shvn_users       enable row level security;
alter table public.shvn_logins      enable row level security;
alter table public.shvn_play_events enable row level security;
alter table public.shvn_settings    enable row level security;

revoke all on table public.shvn_users, public.shvn_logins,
              public.shvn_play_events, public.shvn_settings
  from anon, authenticated;

create or replace function public.shvn_login(p_user_id text, p_pin text)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_name text;
begin
  select name into v_name
    from shvn_users
   where user_id = p_user_id and pin = p_pin and active;
  if v_name is null then
    return json_build_object('ok', false);
  end if;
  insert into shvn_logins (user_id) values (p_user_id);
  return json_build_object('ok', true, 'name', v_name);
end;
$fn$;

create or replace function public.shvn_log_open(p_user_id text)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not exists (select 1 from shvn_users where user_id = p_user_id and active) then
    return json_build_object('ok', false);
  end if;
  insert into shvn_logins (user_id) values (p_user_id);
  return json_build_object('ok', true);
end;
$fn$;

create or replace function public.shvn_log_plays(p_user_id text, p_events json)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  e       json;
  v_count int := 0;
begin
  if not exists (select 1 from shvn_users where user_id = p_user_id and active) then
    return json_build_object('ok', false);
  end if;
  if p_events is null or json_typeof(p_events) <> 'array'
     or json_array_length(p_events) > 1000 then
    return json_build_object('ok', false);
  end if;
  for e in select * from json_array_elements(p_events) loop
    insert into shvn_play_events (user_id, sentence_id, mode, ts)
    values (
      p_user_id,
      coalesce(e ->> 'sentence_id', ''),
      coalesce(e ->> 'mode', 'manual'),
      coalesce(to_timestamp((e ->> 'ts')::double precision / 1000.0), now())
    );
    v_count := v_count + 1;
  end loop;
  return json_build_object('ok', true, 'count', v_count);
end;
$fn$;

create or replace function public.shvn_teacher_report(p_staff_pin text, p_days int default 30)
returns json
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_since timestamptz;
begin
  if not exists (select 1 from shvn_settings
                  where key = 'staff_pin' and value = p_staff_pin) then
    return json_build_object('ok', false);
  end if;
  v_since := now() - make_interval(days => greatest(coalesce(p_days, 30), 1));
  return json_build_object(
    'ok', true,
    'days', p_days,
    'users', (
      select coalesce(json_agg(json_build_object(
               'user_id', user_id, 'name', name, 'active', active,
               'created_at', created_at) order by created_at), '[]'::json)
        from shvn_users
    ),
    'logins', (
      select coalesce(json_agg(json_build_object(
               'user_id', user_id, 'ts', ts) order by ts desc), '[]'::json)
        from shvn_logins where ts >= v_since
    ),
    'plays', (
      select coalesce(json_agg(json_build_object(
               'user_id', user_id, 'sentence_id', sentence_id,
               'mode', mode, 'ts', ts) order by ts desc), '[]'::json)
        from shvn_play_events where ts >= v_since
    )
  );
end;
$fn$;

revoke execute on function public.shvn_login(text, text)          from public;
revoke execute on function public.shvn_log_open(text)             from public;
revoke execute on function public.shvn_log_plays(text, json)      from public;
revoke execute on function public.shvn_teacher_report(text, int)  from public;

grant execute on function public.shvn_login(text, text)          to anon;
grant execute on function public.shvn_log_open(text)             to anon;
grant execute on function public.shvn_log_plays(text, json)      to anon;
grant execute on function public.shvn_teacher_report(text, int)  to anon;
