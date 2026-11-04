
create table if not exists public.people (
  id uuid primary key references auth.users(id) on delete cascade,
  pid text unique not null,
  username text unique not null,
  name text not null,
  role text not null check (role in ('teacher','student')),
  grad int,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.people enable row level security;

do $$
declare t text;
begin
  foreach t in array array['projects','assignments','items','notifs','syncs','asks','lessons','polls','checkins','weeks','settings','events','bank','reminders','todos'] loop
    execute format('create table if not exists public.%I (id text primary key, data jsonb not null default ''{}''::jsonb, updated_at timestamptz not null default now())', t);
    execute format('alter table public.%I add column if not exists updated_at timestamptz not null default now()', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I replica identity full', t);
    execute format('drop policy if exists "test open access" on public.%I', t);
    execute format('drop policy if exists "jarvis read" on public.%I', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('truncate public.%I', t);   -- wipe the character test data
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

drop function if exists public.patch_row(text, text, jsonb);
drop function if exists public.append_row(text, text, text, jsonb);

create or replace function public.jarvis_me() returns text
language sql stable security definer set search_path = public as $$
  select pid from people where id = auth.uid() and active
$$;
create or replace function public.jarvis_is_teacher() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from people where id = auth.uid() and role = 'teacher' and active)
$$;
create or replace function public.jarvis_role(proj_id text, who text) returns text
language sql stable security definer set search_path = public as $$
  select case when p.data->>'owner' = who then 'admin' else p.data->'roles'->>who end from projects p where p.id = proj_id
$$;
create or replace function public.jarvis_can_see_project(proj_id text) returns boolean
language sql stable security definer set search_path = public as $$
  select jarvis_is_teacher() or exists(
    select 1 from projects p where p.id = proj_id
      and ((p.data->'roles') ? jarvis_me() or p.data->>'owner' = jarvis_me() or coalesce((p.data->>'private')::boolean, false) = false))
$$;
create or replace function public.jarvis_to_includes(d jsonb, who text) returns boolean
language sql immutable as $$
  select d->>'to' = 'all' or (jsonb_typeof(d->'to') = 'array' and (d->'to') ? who)
$$;
create or replace function public.jarvis_can_see_item(d jsonb) returns boolean
language sql stable security definer set search_path = public as $$
  select d is not null and (
    jarvis_is_teacher()
    or coalesce(d->'assignees', '[]'::jsonb) ? jarvis_me()
    or (d->>'projectId' is not null and jarvis_can_see_project(d->>'projectId'))
    or exists(select 1 from asks a where a.data->>'itemId' = d->>'id' and a.data->>'kind' = 'feedback' and jarvis_to_includes(a.data, jarvis_me())))
$$;

drop policy if exists "jarvis read" on public.people;
create policy "jarvis read" on public.people for select to authenticated using (jarvis_me() is not null);
drop policy if exists "jarvis teacher edit" on public.people;
create policy "jarvis teacher edit" on public.people for update to authenticated using (jarvis_is_teacher()) with check (jarvis_is_teacher());
revoke all on public.people from anon, authenticated;
grant select on public.people to authenticated;
grant update (name, grad) on public.people to authenticated;

create policy "jarvis read" on public.projects for select to authenticated using (jarvis_can_see_project(id));
create policy "jarvis read" on public.items for select to authenticated using (jarvis_can_see_item(data));
create policy "jarvis read" on public.assignments for select to authenticated using (jarvis_me() is not null);
create policy "jarvis read" on public.notifs for select to authenticated using (jarvis_is_teacher() or data->>'to' = jarvis_me() or data->>'to' = 'all');
create policy "jarvis read" on public.syncs for select to authenticated using (jarvis_is_teacher());
create policy "jarvis read" on public.asks for select to authenticated using (
  jarvis_is_teacher() or data->>'by' = jarvis_me() or data->>'kind' = 'lesson'
  or (data->>'kind' in ('feedback','merge') and jarvis_to_includes(data, jarvis_me()))
  or (data->>'kind' = 'feedback' and data->>'itemId' is not null and jarvis_can_see_item((select i.data from items i where i.id = data->>'itemId')))
  or (data->>'kind' = 'feedback' and data->>'itemId' is null and data->>'projectId' is not null and jarvis_can_see_project(data->>'projectId')));
create policy "jarvis read" on public.lessons for select to authenticated using (jarvis_me() is not null);
create policy "jarvis read" on public.polls for select to authenticated using (jarvis_me() is not null);
create policy "jarvis read" on public.checkins for select to authenticated using (jarvis_is_teacher() or data->>'by' = jarvis_me());
create policy "jarvis read" on public.weeks for select to authenticated using (jarvis_is_teacher() or data->>'by' = jarvis_me());
create policy "jarvis read" on public.events for select to authenticated using (jarvis_is_teacher() or data->>'status' = 'approved' or data->>'by' = jarvis_me());
create policy "jarvis read" on public.bank for select to authenticated using (jarvis_is_teacher() or data->>'status' = 'ready' or data->>'by' = jarvis_me());
create policy "jarvis read" on public.reminders for select to authenticated using (data->>'by' = jarvis_me() or (data->>'to' = jarvis_me() and coalesce((data->>'when')::bigint, 0) <= (extract(epoch from now()) * 1000)::bigint));
create policy "jarvis read" on public.todos for select to authenticated using (data->>'by' = jarvis_me());
create policy "jarvis read" on public.settings for select to authenticated using (
  jarvis_is_teacher() or id like 'profile\_%' or id like 'week\_%' or id = 'mp_config'
  or (id like 'claim\_%' and data->>'by' = jarvis_me()));

create or replace function public.jarvis_changed(o jsonb, n jsonb) returns text[]
language sql immutable as $$
  select coalesce(array_agg(k), '{}') from (
    select k from (select jsonb_object_keys(coalesce(o,'{}'::jsonb)) k union select jsonb_object_keys(coalesce(n,'{}'::jsonb))) ks
    where coalesce(o->k, 'null'::jsonb) is distinct from coalesce(n->k, 'null'::jsonb)) x
$$;
create or replace function public.jarvis_appended(o jsonb, n jsonb) returns jsonb
language plpgsql immutable as $$
declare lo int := coalesce(jsonb_array_length(coalesce(o,'[]'::jsonb)),0); ln int; head jsonb; tail jsonb;
begin
  if n is null or jsonb_typeof(n) <> 'array' then return null; end if;
  ln := jsonb_array_length(n);
  if ln < lo then return null; end if;
  select coalesce(jsonb_agg(e order by i), '[]'::jsonb) into head from jsonb_array_elements(n) with ordinality as x(e,i) where i <= lo;
  if head is distinct from coalesce(o,'[]'::jsonb) then return null; end if;
  select coalesce(jsonb_agg(e order by i), '[]'::jsonb) into tail from jsonb_array_elements(n) with ordinality as x(e,i) where i > lo;
  return tail;
end $$;
create or replace function public.jarvis_append_ok(o jsonb, n jsonb, who text) returns boolean
language sql immutable as $$
  select jarvis_appended(o, n) is not null
     and not exists(select 1 from jsonb_array_elements(jarvis_appended(o, n)) e where e->>'by' is distinct from who)
$$;
create or replace function public.jarvis_toggle_ok(o jsonb, n jsonb, who text) returns boolean
language sql immutable as $$
  select coalesce((select array_agg(x order by x) from (
      (select jsonb_array_elements_text(coalesce(o,'[]'::jsonb)) except select jsonb_array_elements_text(coalesce(n,'[]'::jsonb)))
      union
      (select jsonb_array_elements_text(coalesce(n,'[]'::jsonb)) except select jsonb_array_elements_text(coalesce(o,'[]'::jsonb)))) d(x)), '{}') <@ array[who]
$$;
create or replace function public.jarvis_deny(msg text) returns void language plpgsql as $$
begin raise exception 'JARVIS: %', msg using errcode = '42501'; end $$;

create or replace function public.jarvis_check(tbl text, o jsonb, n jsonb, me text) returns void
language plpgsql stable security definer set search_path = public as $$
declare ch text[] := jarvis_changed(o, n); r text; r2 text; d jsonb := coalesce(n, o); k text;
begin
  if tbl = 'projects' then
    if o is null then
      if n->>'owner' is distinct from me or n->'roles'->>me is distinct from 'admin' or coalesce(n->>'parentId','') <> '' then perform jarvis_deny('new projects must be yours'); end if;
      return;
    end if;
    r := jarvis_role(o->>'id', me);
    if n is null then if r = 'admin' then return; end if; perform jarvis_deny('only a project admin can delete it'); end if;
    if 'owner' = any(ch) then perform jarvis_deny('the owner can’t be changed'); end if;
    if 'parentId' = any(ch) and coalesce(n->>'parentId','') <> '' then perform jarvis_deny('use Combine to put a project inside another'); end if;
    if 'thread' = any(ch) and not jarvis_append_ok(o->'thread', n->'thread', me) then perform jarvis_deny('updates can only be added'); end if;
    if r = 'admin' then return; end if;
    if r = 'editor' and ch <@ array['description','files','thread','eventId'] then return; end if;
    perform jarvis_deny('you can’t change this project');

  elsif tbl = 'items' then
    if o is null then
      if n->>'source' = 'task' then
        r := jarvis_role(n->>'projectId', me);
        if r in ('admin','editor') then return; end if;
        perform jarvis_deny('you need to be an editor on that project');
      end if;
      if n->>'source' = 'assignment' and n->>'id' like 'iw\_%' and n->>'assignmentId' like 'aw\_%' and n->>'status' = 'not' then return; end if;
      perform jarvis_deny('only {{teacher}} can create assignments');
    end if;
    if n is null then
      if o->>'source' = 'task' and jarvis_role(o->>'projectId', me) in ('admin','editor') then return; end if;
      perform jarvis_deny('you can’t delete this');
    end if;
    if ch && array['source','assignmentId','syncId','missingId','id'] then perform jarvis_deny('that can’t be changed'); end if;
    if 'history' = any(ch) and not jarvis_append_ok(o->'history', n->'history', me) then perform jarvis_deny('history can only be added to'); end if;
    if 'thread' = any(ch) and not jarvis_append_ok(o->'thread', n->'thread', me) then perform jarvis_deny('updates can only be added'); end if;
    if o->>'source' = 'assignment' then
      if not (coalesce(o->'assignees','[]'::jsonb) ? me) then perform jarvis_deny('this isn’t your assignment'); end if;
      if not ch <@ array['status','files','thread','history'] then perform jarvis_deny('only {{teacher}} can change that'); end if;
      if 'status' = any(ch) and (n->>'status' = 'done' or o->>'status' = 'done') then perform jarvis_deny('only {{teacher}} marks assignments Done'); end if;
      return;
    end if;
    r := jarvis_role(o->>'projectId', me);
    if r in ('admin','editor') then
      if 'projectId' = any(ch) then
        r2 := jarvis_role(n->>'projectId', me);
        if coalesce(r2,'') not in ('admin','editor') then perform jarvis_deny('you need to be an editor on the other project'); end if;
      end if;
      return;
    end if;
    if coalesce(o->'assignees','[]'::jsonb) ? me and ch <@ array['status','files','thread','history','when'] then return; end if;
    perform jarvis_deny('you can’t change this item');

  elsif tbl = 'assignments' then
    if o is null and n->>'id' = 'aw_' || (n->>'weekStart') and (n->>'weekly')::boolean then return; end if;
    perform jarvis_deny('only {{teacher}} can change assignments');

  elsif tbl = 'notifs' then
    if o is null and n->>'by' = me then return; end if;
    if o is not null and n is not null and ch <@ array['readBy'] and jarvis_appended(o->'readBy', n->'readBy') is not null
       and not exists(select 1 from jsonb_array_elements_text(jarvis_appended(o->'readBy', n->'readBy')) e where e <> me) then return; end if;
    perform jarvis_deny('notification change not allowed');

  elsif tbl = 'asks' then
    if o is null then
      if n->>'by' is distinct from me or coalesce(jsonb_array_length(n->'replies'),0) > 0 then perform jarvis_deny('asks must be yours'); end if;
      if n->>'kind' = 'lesson' and (n->'plus') is distinct from jsonb_build_array(me) then perform jarvis_deny('bad lesson request'); end if;
      if n->>'kind' = 'merge' and jarvis_role(n->>'projectId', me) is distinct from 'admin' then perform jarvis_deny('only a project admin can ask to combine it'); end if;
      if coalesce(n->>'kind','') not in ('feedback','help','lesson','merge') then perform jarvis_deny('bad ask'); end if;
      return;
    end if;
    if n is null then perform jarvis_deny('asks can’t be deleted'); end if;
    if 'replies' = any(ch) and not jarvis_append_ok(o->'replies', n->'replies', me) then perform jarvis_deny('replies can only be added'); end if;
    if 'plus' = any(ch) and (o->>'kind' <> 'lesson' or not jarvis_toggle_ok(o->'plus', n->'plus', me)) then perform jarvis_deny('you can only +1 for yourself'); end if;
    if o->>'by' = me and ch <@ array['open','note','replies','plus'] then return; end if;
    if o->>'kind' = 'merge' and jarvis_role(o->>'targetId', me) = 'admin' and ch <@ array['open','result','replies'] then return; end if;
    if ch <@ array['replies','plus'] and (o->>'kind' = 'lesson' or jarvis_to_includes(o, me)
        or (o->>'kind' = 'feedback' and (o->>'itemId' is not null and jarvis_can_see_item((select i.data from items i where i.id = o->>'itemId'))))) then return; end if;
    perform jarvis_deny('you can’t change this ask');

  elsif tbl = 'lessons' then
    if o is not null and n is not null and ch <@ array['signups'] and jarvis_toggle_ok(o->'signups', n->'signups', me) then
      if jsonb_array_length(n->'signups') > jsonb_array_length(coalesce(o->'signups','[]'::jsonb)) then
        if jsonb_array_length(n->'signups') > coalesce((o->>'seats')::int, 0) then perform jarvis_deny('that lesson is full'); end if;
      end if;
      return;
    end if;
    perform jarvis_deny('only {{teacher}} can change lessons');

  elsif tbl = 'polls' then
    if o is not null and n is not null and ch <@ array['responses'] and coalesce((o->>'open')::boolean, false)
       and jarvis_append_ok(o->'responses', n->'responses', me) then return; end if;
    perform jarvis_deny('you can only answer open polls');

  elsif tbl = 'checkins' then
    if n is null then perform jarvis_deny('check-ins can’t be deleted'); end if;
    if n->>'by' = me and n->>'id' = 'ci_' || me || '_' || (n->>'date') and (o is null or o->>'by' = me) then return; end if;
    perform jarvis_deny('that’s not your check-in');

  elsif tbl = 'weeks' then
    if n is null then perform jarvis_deny('weekly reports can’t be deleted'); end if;
    if n->>'by' = me and n->>'id' = 'wk_' || me || '_' || (n->>'weekStart') and (o is null or o->>'by' = me) and not ('days' = any(ch)) then return; end if;
    perform jarvis_deny('that’s not your weekly report');

  elsif tbl = 'settings' then
    k := d->>'id';
    if k = 'profile_' || me then
      if n is null then perform jarvis_deny('profiles can’t be deleted'); end if;
      if 'img' = any(ch) and n->'img' is not null and n->'img' <> 'null'::jsonb then perform jarvis_deny('pictures need {{teacher}}’s approval'); end if;
      if ch <@ array['id','color','shape','mode','text','imgPending','img','simple','nick'] then return; end if;
      perform jarvis_deny('profile change not allowed');
    end if;
    if k like 'claim\_' || me || '\_%' and d->>'by' = me then
      if n is null then
        if coalesce(o->>'status','planned') in ('planned','returned') then return; end if;
        perform jarvis_deny('counted work can’t be removed');
      end if;
      if coalesce(o->>'status','planned') not in ('planned','returned') and ch <> '{}' then perform jarvis_deny('that’s waiting for {{teacher}}'); end if;
      if coalesce(n->>'status','planned') not in ('planned','submitted') then perform jarvis_deny('only {{teacher}} counts work'); end if;
      if ch && array['mp','creditedAt','by','target'] and o is not null then perform jarvis_deny('that can’t be changed'); end if;
      if o is null and (n->>'status' <> 'planned' or n ? 'mp') then perform jarvis_deny('new tags start as planned'); end if;
      return;
    end if;
    perform jarvis_deny('only {{teacher}} can change that setting');

  elsif tbl = 'events' then
    if o is null then
      if n->>'by' is distinct from me or coalesce(n->>'status','') <> 'pending' then perform jarvis_deny('new events wait for {{teacher}}’s approval'); end if;
      return;
    end if;
    if o->>'by' is distinct from me or coalesce(o->>'status','') <> 'pending' then perform jarvis_deny('only {{teacher}} can change this event'); end if;
    if n is null then return; end if;
    if ch && array['status','by','note'] then perform jarvis_deny('only {{teacher}} approves events'); end if;
    return;

  elsif tbl = 'bank' then
    if o is null then
      if n->>'by' is distinct from me or coalesce(n->>'status','') <> 'raw' then perform jarvis_deny('suggestions go to {{teacher}} first'); end if;
      return;
    end if;
    if n is null then
      if o->>'by' = me and o->>'status' = 'raw' then return; end if;
      perform jarvis_deny('only a teacher can remove bank cards');
    end if;
    if o->>'by' = me and o->>'status' = 'raw' and not (ch && array['status','by']) then return; end if;
    if o->>'status' = 'ready' and o->>'type' = 'idea' and ch <@ array['starts'] and jarvis_append_ok(o->'starts', n->'starts', me) then return; end if;
    if o->>'status' = 'ready' and o->>'type' = 'request' and ch <@ array['hands'] and jarvis_toggle_ok(o->'hands', n->'hands', me) then return; end if;
    perform jarvis_deny('only a teacher can change bank cards');

  elsif tbl = 'reminders' then
    if o is null then
      if n->>'by' is distinct from me or n->>'to' is distinct from me then perform jarvis_deny('you can only set reminders for yourself'); end if;
      return;
    end if;
    if n is null then
      if o->>'by' = me then return; end if;
      perform jarvis_deny('only the person who set a reminder can delete it');
    end if;
    if o->>'by' = me and not ('by' = any(ch)) and n->>'to' is not distinct from o->>'to' then return; end if;
    if o->>'to' = me and ch <@ array['done','doneAt','when','notified','snoozes'] then return; end if;
    perform jarvis_deny('that reminder belongs to someone else');

  elsif tbl = 'todos' then
    if (o is null or o->>'by' = me) and (n is null or n->>'by' = me) then return; end if;
    perform jarvis_deny('that list belongs to someone else');

  elsif tbl = 'syncs' then
    perform jarvis_deny('only {{teacher}} can do that');
  else
    perform jarvis_deny('unknown table');
  end if;
end $$;

create or replace function public.jarvis_write(op text, tbl text, rid text, payload jsonb default null, k text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me text := jarvis_me(); t boolean := jarvis_is_teacher(); o jsonb; n jsonb;
begin
  if me is null then perform jarvis_deny('please sign in'); end if;
  if tbl not in ('projects','assignments','items','notifs','syncs','asks','lessons','polls','checkins','weeks','settings','events','bank','reminders','todos') then perform jarvis_deny('bad table'); end if;
  execute format('select data from public.%I where id = $1 for update', tbl) into o using rid;
  if op = 'put' then n := payload;
  elsif op = 'patch' then n := coalesce(o, '{}'::jsonb) || payload;
  elsif op = 'append' then
    if o is null then perform jarvis_deny('that was deleted'); end if;
    n := jsonb_set(o, array[k], coalesce(o->k, '[]'::jsonb) || payload);
  elsif op = 'delete' then n := null;
  else perform jarvis_deny('bad operation'); end if;
  if n is not null then n := jsonb_set(n, '{id}', to_jsonb(rid)); end if;
  if not t then perform jarvis_check(tbl, o, n, me); end if;
  if n is null then execute format('delete from public.%I where id = $1', tbl) using rid;
  elsif o is null then execute format('insert into public.%I (id, data) values ($1, $2)', tbl) using rid, n;
  else execute format('update public.%I set data = $2, updated_at = now() where id = $1', tbl) using rid, n;
  end if;
  return n;
end $$;
revoke all on function public.jarvis_write(text, text, text, jsonb, text) from public, anon;
grant execute on function public.jarvis_write(text, text, text, jsonb, text) to authenticated;

create or replace function public.jarvis_stamp() returns jsonb language sql stable as $$
  select jsonb_build_object('ts', (extract(epoch from now()) * 1000)::bigint, 'at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
$$;
create or replace function public.jarvis_merge(p_id text, t_id text, mode text, ask_id text default null) returns text
language plpgsql security definer set search_path = public as $$
declare me text := jarvis_me(); pd jsonb; td jsonb; a jsonb; ok boolean := false; st jsonb := jarvis_stamp(); nid text; status text; r record;
begin
  if me is null then perform jarvis_deny('please sign in'); end if;
  select data into pd from projects where id = p_id for update;
  select data into td from projects where id = t_id for update;
  if pd is null or td is null or p_id = t_id then perform jarvis_deny('project not found'); end if;
  if mode not in ('nest','convert') then perform jarvis_deny('bad mode'); end if;
  if jarvis_is_teacher() then ok := true;
  elsif jarvis_role(p_id, me) = 'admin' and jarvis_role(t_id, me) = 'admin' then ok := true;
  elsif ask_id is not null and jarvis_role(t_id, me) = 'admin' then
    select data into a from asks where id = ask_id;
    ok := a is not null and a->>'kind' = 'merge' and coalesce((a->>'open')::boolean,false) and a->>'projectId' = p_id and a->>'targetId' = t_id and a->>'mode' = mode
          and jarvis_role(p_id, a->>'by') = 'admin';
  end if;
  if not ok then perform jarvis_deny('you can’t combine these projects'); end if;
  if coalesce(td->>'parentId','') <> '' then perform jarvis_deny('the bigger project is already inside another'); end if;
  if exists(select 1 from projects where data->>'parentId' = p_id) then perform jarvis_deny('take the projects inside it out first'); end if;

  if mode = 'nest' then
    update projects set data = jsonb_set(data, '{parentId}', to_jsonb(t_id)) || jsonb_build_object('thread', coalesce(data->'thread','[]'::jsonb) ||
      jsonb_build_array(jsonb_build_object('id','u'||substr(md5(random()::text),1,10),'by',me,'text','Moved inside “'||(td->>'name')||'”','sys',true) || st)), updated_at = now() where id = p_id;
    update projects set data = data || jsonb_build_object('thread', coalesce(data->'thread','[]'::jsonb) ||
      jsonb_build_array(jsonb_build_object('id','u'||substr(md5(random()::text),1,10),'by',me,'text','“'||(pd->>'name')||'” is now part of this project','sys',true) || st)), updated_at = now() where id = t_id;
    nid := null;
  else
    select case when count(*) > 0 and bool_and(data->>'status' in ('done','sub')) then 'done' when bool_or(data->>'status' <> 'not') then 'work' else 'not' end
      into status from items where data->>'projectId' = p_id;
    nid := 'i' || substr(md5(random()::text), 1, 12);
    insert into items (id, data) values (nid, jsonb_build_object(
      'id', nid, 'source','task', 'title', pd->>'name', 'description', coalesce(pd->>'description',''),
      'assignees', coalesce((select jsonb_agg(key) from jsonb_each_text(coalesce(pd->'roles','{}'::jsonb)) where value <> 'viewer' and key <> 't'), '[]'::jsonb),
      'status', coalesce(status,'not'), 'due','', 'priority','med', 'projectId', t_id, 'parentId', null,
      'files', coalesce(pd->'files','[]'::jsonb), 'thread', coalesce(pd->'thread','[]'::jsonb),
      'history', jsonb_build_array(jsonb_build_object('kind','converted','by',me,'from',pd->>'name') || st)));
    -- everything moves over; top-level items go under the new item, deeper layers keep their place
    update items set data = data || jsonb_build_object('projectId', t_id,
        'history', coalesce(data->'history','[]'::jsonb) || jsonb_build_array(jsonb_build_object('kind','moved','by',me,'from',pd->>'name','to',td->>'name') || st))
      || case when coalesce(data->>'parentId','') = '' then jsonb_build_object('parentId', nid) else '{}'::jsonb end,
      updated_at = now()
      where data->>'projectId' = p_id and id <> nid;
    -- people from the smaller project join the bigger one
    update projects set data = jsonb_set(data, '{roles}', coalesce((select jsonb_object_agg(key, case when value = 'viewer' then 'viewer' else 'editor' end) from jsonb_each_text(coalesce(pd->'roles','{}'::jsonb))), '{}'::jsonb) || coalesce(data->'roles','{}'::jsonb))
      || jsonb_build_object('thread', coalesce(data->'thread','[]'::jsonb) || jsonb_build_array(jsonb_build_object('id','u'||substr(md5(random()::text),1,10),'by',me,'text','“'||(pd->>'name')||'” was turned into an item in this project','sys',true) || st)),
      updated_at = now() where id = t_id;
    update asks set data = data || jsonb_build_object('projectId', t_id, 'itemId', coalesce(data->>'itemId', nid)), updated_at = now() where data->>'projectId' = p_id and data->>'kind' <> 'merge';
    update asks set data = data || jsonb_build_object('open', false), updated_at = now() where data->>'kind' = 'merge' and (data->>'projectId' = p_id or data->>'targetId' = p_id) and coalesce(id,'') <> coalesce(ask_id,'');
    update checkins set data = jsonb_set(data, '{active}', (select coalesce(jsonb_agg(case when e = to_jsonb('p:'||p_id) then to_jsonb('i:'||nid) else e end), '[]'::jsonb) from jsonb_array_elements(coalesce(data->'active','[]'::jsonb)) e)), updated_at = now()
      where data->'active' ? ('p:'||p_id);
    update projects set data = data || jsonb_build_object('parentId', null), updated_at = now() where data->>'parentId' = p_id;
    delete from projects where id = p_id;
  end if;
  if ask_id is not null then
    update asks set data = data || jsonb_build_object('open', false, 'result', 'approved'), updated_at = now() where id = ask_id;
  end if;
  return nid;
end $$;
revoke all on function public.jarvis_merge(text, text, text, text) from public, anon;
grant execute on function public.jarvis_merge(text, text, text, text) to authenticated;

create or replace function public.jarvis_restore(backup jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare t text; n int := 0; rj jsonb;
begin
  if not jarvis_is_teacher() then perform jarvis_deny('only {{teacher}} can restore'); end if;
  foreach t in array array['projects','assignments','items','notifs','syncs','asks','lessons','polls','checkins','weeks','settings','events','bank'] loop
    execute format('delete from public.%I', t);
    for rj in select value from jsonb_array_elements(coalesce(backup->t, '[]'::jsonb)) loop
      if rj->>'id' is not null then
        execute format('insert into public.%I (id, data) values ($1, $2) on conflict (id) do update set data = excluded.data', t) using rj->>'id', rj;
        n := n + 1;
      end if;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function public.jarvis_restore(jsonb) from public, anon;
grant execute on function public.jarvis_restore(jsonb) to authenticated;

revoke execute on function public.jarvis_check(text, jsonb, jsonb, text) from public, anon, authenticated;



create table if not exists public.events (id text primary key, data jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now());
alter table public.events enable row level security;
alter table public.events replica identity full;
revoke all on public.events from anon, authenticated;
grant select on public.events to authenticated;
drop policy if exists "jarvis read" on public.events;
create policy "jarvis read" on public.events for select to authenticated using (jarvis_is_teacher() or data->>'status' = 'approved' or data->>'by' = jarvis_me());
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='events') then
    alter publication supabase_realtime add table public.events;
  end if;
end $$;

create table if not exists public.bank (id text primary key, data jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now());
alter table public.bank enable row level security;
alter table public.bank replica identity full;
revoke all on public.bank from anon, authenticated;
grant select on public.bank to authenticated;
drop policy if exists "jarvis read" on public.bank;
create policy "jarvis read" on public.bank for select to authenticated using (jarvis_is_teacher() or data->>'status' = 'ready' or data->>'by' = jarvis_me());
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='bank') then
    alter publication supabase_realtime add table public.bank;
  end if;
end $$;

create table if not exists public.reminders (id text primary key, data jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now());
alter table public.reminders enable row level security;
alter table public.reminders replica identity full;
revoke all on public.reminders from anon, authenticated;
grant select on public.reminders to authenticated;
drop policy if exists "jarvis read" on public.reminders;
create policy "jarvis read" on public.reminders for select to authenticated using (data->>'by' = jarvis_me() or (data->>'to' = jarvis_me() and coalesce((data->>'when')::bigint, 0) <= (extract(epoch from now()) * 1000)::bigint));
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='reminders') then
    alter publication supabase_realtime add table public.reminders;
  end if;
end $$;

create table if not exists public.todos (id text primary key, data jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now());
alter table public.todos enable row level security;
alter table public.todos replica identity full;
revoke all on public.todos from anon, authenticated;
grant select on public.todos to authenticated;
drop policy if exists "jarvis read" on public.todos;
create policy "jarvis read" on public.todos for select to authenticated using (data->>'by' = jarvis_me());
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='todos') then
    alter publication supabase_realtime add table public.todos;
  end if;
end $$;

create table if not exists public.reflections (id text primary key, data jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now());
alter table public.reflections enable row level security;
alter table public.reflections replica identity full;
revoke all on public.reflections from anon, authenticated;
grant select on public.reflections to authenticated;
drop policy if exists "jarvis read" on public.reflections;
create policy "jarvis read" on public.reflections for select to authenticated using (jarvis_is_teacher() or data->>'by' = jarvis_me());
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='reflections') then
    alter publication supabase_realtime add table public.reflections;
  end if;
end $$;

create table if not exists public.broadcast (id text primary key, data jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now());
alter table public.broadcast enable row level security;
alter table public.broadcast replica identity full;
revoke all on public.broadcast from anon, authenticated;
grant select on public.broadcast to authenticated;
drop policy if exists "jarvis read" on public.broadcast;
create policy "jarvis read" on public.broadcast for select to authenticated using (true);
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='broadcast') then
    alter publication supabase_realtime add table public.broadcast;
  end if;
end $$;

create or replace function public.jarvis_check(tbl text, o jsonb, n jsonb, me text) returns void
language plpgsql stable security definer set search_path = public as $$
declare ch text[] := jarvis_changed(o, n); r text; r2 text; d jsonb := coalesce(n, o); k text;
begin
  if tbl = 'projects' then
    if o is null then
      if n->>'owner' is distinct from me or n->'roles'->>me is distinct from 'admin' or coalesce(n->>'parentId','') <> '' then perform jarvis_deny('new projects must be yours'); end if;
      return;
    end if;
    r := jarvis_role(o->>'id', me);
    if n is null then if r = 'admin' then return; end if; perform jarvis_deny('only a project admin can delete it'); end if;
    if 'owner' = any(ch) then perform jarvis_deny('the owner can’t be changed'); end if;
    if 'parentId' = any(ch) and coalesce(n->>'parentId','') <> '' then perform jarvis_deny('use Combine to put a project inside another'); end if;
    if 'thread' = any(ch) and not jarvis_append_ok(o->'thread', n->'thread', me) then perform jarvis_deny('updates can only be added'); end if;
    if coalesce((o->>'completed')::boolean,false) and not coalesce((n->>'completed')::boolean,false) then perform jarvis_deny('only a teacher can reopen a finished project'); end if;
    if r = 'admin' then return; end if;
    if r = 'editor' and ch <@ array['description','files','thread','eventId'] then return; end if;
    perform jarvis_deny('you can’t change this project');

  elsif tbl = 'items' then
    if o is null then
      if n->>'source' = 'task' then
        r := jarvis_role(n->>'projectId', me);
        if r in ('admin','editor') then return; end if;
        perform jarvis_deny('you need to be an editor on that project');
      end if;
      if n->>'source' = 'assignment' and n->>'id' like 'iw\_%' and n->>'assignmentId' like 'aw\_%' and n->>'status' = 'not' then return; end if;
      perform jarvis_deny('only {{teacher}} can create assignments');
    end if;
    if n is null then
      if o->>'source' = 'task' and jarvis_role(o->>'projectId', me) in ('admin','editor') then return; end if;
      perform jarvis_deny('you can’t delete this');
    end if;
    if ch && array['source','assignmentId','syncId','missingId','id'] then perform jarvis_deny('that can’t be changed'); end if;
    if 'history' = any(ch) and not jarvis_append_ok(o->'history', n->'history', me) then perform jarvis_deny('history can only be added to'); end if;
    if 'thread' = any(ch) and not jarvis_append_ok(o->'thread', n->'thread', me) then perform jarvis_deny('updates can only be added'); end if;
    if o->>'source' = 'assignment' then
      if not (coalesce(o->'assignees','[]'::jsonb) ? me) then perform jarvis_deny('this isn’t your assignment'); end if;
      if not ch <@ array['status','files','thread','history'] then perform jarvis_deny('only {{teacher}} can change that'); end if;
      if 'status' = any(ch) and (n->>'status' = 'done' or o->>'status' = 'done') then perform jarvis_deny('only {{teacher}} marks assignments Done'); end if;
      return;
    end if;
    r := jarvis_role(o->>'projectId', me);
    if r in ('admin','editor') then
      if 'projectId' = any(ch) then
        r2 := jarvis_role(n->>'projectId', me);
        if coalesce(r2,'') not in ('admin','editor') then perform jarvis_deny('you need to be an editor on the other project'); end if;
      end if;
      return;
    end if;
    if coalesce(o->'assignees','[]'::jsonb) ? me and ch <@ array['status','files','thread','history','when'] then return; end if;
    perform jarvis_deny('you can’t change this item');

  elsif tbl = 'assignments' then
    if o is null and n->>'id' = 'aw_' || (n->>'weekStart') and (n->>'weekly')::boolean then return; end if;
    perform jarvis_deny('only {{teacher}} can change assignments');

  elsif tbl = 'notifs' then
    if o is null and n->>'by' = me then return; end if;
    if o is not null and n is not null and ch <@ array['readBy'] and jarvis_appended(o->'readBy', n->'readBy') is not null
       and not exists(select 1 from jsonb_array_elements_text(jarvis_appended(o->'readBy', n->'readBy')) e where e <> me) then return; end if;
    perform jarvis_deny('notification change not allowed');

  elsif tbl = 'asks' then
    if o is null then
      if n->>'by' is distinct from me or coalesce(jsonb_array_length(n->'replies'),0) > 0 then perform jarvis_deny('asks must be yours'); end if;
      if n->>'kind' = 'lesson' and (n->'plus') is distinct from jsonb_build_array(me) then perform jarvis_deny('bad lesson request'); end if;
      if n->>'kind' = 'merge' and jarvis_role(n->>'projectId', me) is distinct from 'admin' then perform jarvis_deny('only a project admin can ask to combine it'); end if;
      if coalesce(n->>'kind','') not in ('feedback','help','lesson','merge') then perform jarvis_deny('bad ask'); end if;
      return;
    end if;
    if n is null then perform jarvis_deny('asks can’t be deleted'); end if;
    if 'replies' = any(ch) and not jarvis_append_ok(o->'replies', n->'replies', me) then perform jarvis_deny('replies can only be added'); end if;
    if 'plus' = any(ch) and (o->>'kind' <> 'lesson' or not jarvis_toggle_ok(o->'plus', n->'plus', me)) then perform jarvis_deny('you can only +1 for yourself'); end if;
    if o->>'by' = me and ch <@ array['open','note','replies','plus'] then return; end if;
    if o->>'kind' = 'merge' and jarvis_role(o->>'targetId', me) = 'admin' and ch <@ array['open','result','replies'] then return; end if;
    if ch <@ array['replies','plus'] and (o->>'kind' = 'lesson' or jarvis_to_includes(o, me)
        or (o->>'kind' = 'feedback' and (o->>'itemId' is not null and jarvis_can_see_item((select i.data from items i where i.id = o->>'itemId'))))) then return; end if;
    perform jarvis_deny('you can’t change this ask');

  elsif tbl = 'lessons' then
    if o is not null and n is not null and ch <@ array['signups'] and jarvis_toggle_ok(o->'signups', n->'signups', me) then
      if jsonb_array_length(n->'signups') > jsonb_array_length(coalesce(o->'signups','[]'::jsonb)) then
        if jsonb_array_length(n->'signups') > coalesce((o->>'seats')::int, 0) then perform jarvis_deny('that lesson is full'); end if;
      end if;
      return;
    end if;
    perform jarvis_deny('only {{teacher}} can change lessons');

  elsif tbl = 'polls' then
    if o is not null and n is not null and ch <@ array['responses'] and coalesce((o->>'open')::boolean, false)
       and jarvis_append_ok(o->'responses', n->'responses', me) then return; end if;
    perform jarvis_deny('you can only answer open polls');

  elsif tbl = 'checkins' then
    if n is null then perform jarvis_deny('check-ins can’t be deleted'); end if;
    if n->>'by' = me and n->>'id' = 'ci_' || me || '_' || (n->>'date') and (o is null or o->>'by' = me) then return; end if;
    perform jarvis_deny('that’s not your check-in');

  elsif tbl = 'weeks' then
    if n is null then perform jarvis_deny('weekly reports can’t be deleted'); end if;
    if n->>'by' = me and n->>'id' = 'wk_' || me || '_' || (n->>'weekStart') and (o is null or o->>'by' = me) and not ('days' = any(ch)) then return; end if;
    perform jarvis_deny('that’s not your weekly report');

  elsif tbl = 'settings' then
    k := d->>'id';
    if k = 'profile_' || me then
      if n is null then perform jarvis_deny('profiles can’t be deleted'); end if;
      if 'img' = any(ch) and n->'img' is not null and n->'img' <> 'null'::jsonb then perform jarvis_deny('pictures need {{teacher}}’s approval'); end if;
      if ch <@ array['id','color','shape','mode','text','imgPending','img','simple','nick'] then return; end if;
      perform jarvis_deny('profile change not allowed');
    end if;
    if k like 'claim\_' || me || '\_%' and d->>'by' = me then
      if n is null then
        if coalesce(o->>'status','planned') in ('planned','returned') then return; end if;
        perform jarvis_deny('counted work can’t be removed');
      end if;
      if coalesce(o->>'status','planned') not in ('planned','returned') and ch <> '{}' then perform jarvis_deny('that’s waiting for {{teacher}}'); end if;
      if coalesce(n->>'status','planned') not in ('planned','submitted') then perform jarvis_deny('only {{teacher}} counts work'); end if;
      if ch && array['mp','creditedAt','by','target'] and o is not null then perform jarvis_deny('that can’t be changed'); end if;
      if o is null and (n->>'status' <> 'planned' or n ? 'mp') then perform jarvis_deny('new tags start as planned'); end if;
      return;
    end if;
    if k like 'post\_%' and o is not null and n is not null and coalesce((o->>'published')::boolean,false)
       and ch <@ array['likes'] and jarvis_toggle_ok(coalesce(o->'likes','[]'::jsonb), n->'likes', me) then return; end if;
    perform jarvis_deny('only {{teacher}} can change that setting');

  elsif tbl = 'events' then
    if o is null then
      if n->>'by' is distinct from me or coalesce(n->>'status','') <> 'pending' then perform jarvis_deny('new events wait for {{teacher}}’s approval'); end if;
      return;
    end if;
    if o->>'by' is distinct from me or coalesce(o->>'status','') <> 'pending' then perform jarvis_deny('only {{teacher}} can change this event'); end if;
    if n is null then return; end if;
    if ch && array['status','by','note'] then perform jarvis_deny('only {{teacher}} approves events'); end if;
    return;

  elsif tbl = 'bank' then
    if o is null then
      if n->>'by' is distinct from me or coalesce(n->>'status','') <> 'raw' then perform jarvis_deny('suggestions go to {{teacher}} first'); end if;
      return;
    end if;
    if n is null then
      if o->>'by' = me and o->>'status' = 'raw' then return; end if;
      perform jarvis_deny('only a teacher can remove bank cards');
    end if;
    if o->>'by' = me and o->>'status' = 'raw' and not (ch && array['status','by']) then return; end if;
    if o->>'status' = 'ready' and o->>'type' = 'idea' and ch <@ array['starts'] and jarvis_append_ok(o->'starts', n->'starts', me) then return; end if;
    if o->>'status' = 'ready' and o->>'type' = 'request' and ch <@ array['hands'] and jarvis_toggle_ok(o->'hands', n->'hands', me) then return; end if;
    perform jarvis_deny('only a teacher can change bank cards');

  elsif tbl = 'reminders' then
    if o is null then
      if n->>'by' is distinct from me or n->>'to' is distinct from me then perform jarvis_deny('you can only set reminders for yourself'); end if;
      return;
    end if;
    if n is null then
      if o->>'by' = me then return; end if;
      perform jarvis_deny('only the person who set a reminder can delete it');
    end if;
    if o->>'by' = me and not ('by' = any(ch)) and n->>'to' is not distinct from o->>'to' then return; end if;
    if o->>'to' = me and ch <@ array['done','doneAt','when','notified','snoozes'] then return; end if;
    perform jarvis_deny('that reminder belongs to someone else');

  elsif tbl = 'todos' then
    if (o is null or o->>'by' = me) and (n is null or n->>'by' = me) then return; end if;
    perform jarvis_deny('that list belongs to someone else');

  elsif tbl = 'reflections' then
    if (o is not null and o->>'by' is distinct from me) or (n is not null and n->>'by' is distinct from me) then perform jarvis_deny('that reflection belongs to someone else'); end if;
    if n is not null then
      if n->>'kind' is distinct from 'student' then perform jarvis_deny('only teachers can write teacher notes'); end if;
      if n->>'id' is distinct from 'rf_' || (n->>'projectId') || '_' || me then perform jarvis_deny('bad reflection id'); end if;
      if jarvis_role(n->>'projectId', me) is null and not exists(select 1 from items i where i.data->>'projectId' = n->>'projectId' and (i.data->'assignees') ? me) then perform jarvis_deny('you’re not on that project'); end if;
    end if;
    return;

  elsif tbl = 'broadcast' then
    if o is null or n is null then perform jarvis_deny('only a teacher can add or remove broadcast items'); end if;
    if o->>'kind' = 'block' and ch <@ array['who','status','file','text','doneAt','editedBy']
       and (not ('who' = any(ch)) or jarvis_toggle_ok(o->'who', n->'who', me)) then return; end if;
    if o->>'kind' = 'ann' and ch <@ array['who','status','file','doneAt','editedBy']
       and (not ('who' = any(ch)) or jarvis_toggle_ok(o->'who', n->'who', me)) then return; end if;
    perform jarvis_deny('only a teacher can change that');

  elsif tbl = 'syncs' then
    perform jarvis_deny('only {{teacher}} can do that');
  else
    perform jarvis_deny('unknown table');
  end if;
end $$;

create or replace function public.jarvis_write(op text, tbl text, rid text, payload jsonb default null, k text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me text := jarvis_me(); t boolean := jarvis_is_teacher(); o jsonb; n jsonb;
begin
  if me is null then perform jarvis_deny('please sign in'); end if;
  if tbl not in ('projects','assignments','items','notifs','syncs','asks','lessons','polls','checkins','weeks','settings','events','bank','reminders','todos','reflections','broadcast') then perform jarvis_deny('bad table'); end if;
  execute format('select data from public.%I where id = $1 for update', tbl) into o using rid;
  if op = 'put' then n := payload;
  elsif op = 'patch' then n := coalesce(o, '{}'::jsonb) || payload;
  elsif op = 'append' then
    if o is null then perform jarvis_deny('that was deleted'); end if;
    n := jsonb_set(o, array[k], coalesce(o->k, '[]'::jsonb) || payload);
  elsif op = 'delete' then n := null;
  else perform jarvis_deny('bad operation'); end if;
  if n is not null then n := jsonb_set(n, '{id}', to_jsonb(rid)); end if;
  if not t then perform jarvis_check(tbl, o, n, me); end if;
  if n is null then execute format('delete from public.%I where id = $1', tbl) using rid;
  elsif o is null then execute format('insert into public.%I (id, data) values ($1, $2)', tbl) using rid, n;
  else execute format('update public.%I set data = $2, updated_at = now() where id = $1', tbl) using rid, n;
  end if;
  return n;
end $$;
revoke all on function public.jarvis_write(text, text, text, jsonb, text) from public, anon;
grant execute on function public.jarvis_write(text, text, text, jsonb, text) to authenticated;

create or replace function public.jarvis_restore(backup jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare t text; n int := 0; rj jsonb;
begin
  if not jarvis_is_teacher() then perform jarvis_deny('only {{teacher}} can restore'); end if;
  foreach t in array array['projects','assignments','items','notifs','syncs','asks','lessons','polls','checkins','weeks','settings','events','bank','reflections','broadcast'] loop
    if not (backup ? t) then continue; end if;
    execute format('delete from public.%I', t);
    for rj in select value from jsonb_array_elements(coalesce(backup->t, '[]'::jsonb)) loop
      if rj->>'id' is not null then
        execute format('insert into public.%I (id, data) values ($1, $2) on conflict (id) do update set data = excluded.data', t) using rj->>'id', rj;
        n := n + 1;
      end if;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function public.jarvis_restore(jsonb) from public, anon;
grant execute on function public.jarvis_restore(jsonb) to authenticated;

create or replace function public.jarvis_merge(p_id text, t_id text, mode text, ask_id text default null) returns text
language plpgsql security definer set search_path = public as $$
declare me text := jarvis_me(); pd jsonb; td jsonb; a jsonb; ok boolean := false; st jsonb := jarvis_stamp(); nid text; status text; r record;
begin
  if me is null then perform jarvis_deny('please sign in'); end if;
  select data into pd from projects where id = p_id for update;
  select data into td from projects where id = t_id for update;
  if pd is null or td is null or p_id = t_id then perform jarvis_deny('project not found'); end if;
  if mode not in ('nest','convert') then perform jarvis_deny('bad mode'); end if;
  if jarvis_is_teacher() then ok := true;
  elsif jarvis_role(p_id, me) = 'admin' and jarvis_role(t_id, me) = 'admin' then ok := true;
  elsif ask_id is not null and jarvis_role(t_id, me) = 'admin' then
    select data into a from asks where id = ask_id;
    ok := a is not null and a->>'kind' = 'merge' and coalesce((a->>'open')::boolean,false) and a->>'projectId' = p_id and a->>'targetId' = t_id and a->>'mode' = mode
          and jarvis_role(p_id, a->>'by') = 'admin';
  end if;
  if not ok then perform jarvis_deny('you can’t combine these projects'); end if;
  if coalesce(td->>'parentId','') <> '' then perform jarvis_deny('the bigger project is already inside another'); end if;
  if exists(select 1 from projects where data->>'parentId' = p_id) then perform jarvis_deny('take the projects inside it out first'); end if;

  if mode = 'nest' then
    update projects set data = jsonb_set(data, '{parentId}', to_jsonb(t_id)) || jsonb_build_object('thread', coalesce(data->'thread','[]'::jsonb) ||
      jsonb_build_array(jsonb_build_object('id','u'||substr(md5(random()::text),1,10),'by',me,'text','Moved inside “'||(td->>'name')||'”','sys',true) || st)), updated_at = now() where id = p_id;
    update projects set data = data || jsonb_build_object('thread', coalesce(data->'thread','[]'::jsonb) ||
      jsonb_build_array(jsonb_build_object('id','u'||substr(md5(random()::text),1,10),'by',me,'text','“'||(pd->>'name')||'” is now part of this project','sys',true) || st)), updated_at = now() where id = t_id;
    nid := null;
  else
    select case when count(*) > 0 and bool_and(data->>'status' in ('done','sub')) then 'done' when bool_or(data->>'status' <> 'not') then 'work' else 'not' end
      into status from items where data->>'projectId' = p_id;
    nid := 'i' || substr(md5(random()::text), 1, 12);
    insert into items (id, data) values (nid, jsonb_build_object(
      'id', nid, 'source','task', 'title', pd->>'name', 'description', coalesce(pd->>'description',''),
      'assignees', coalesce((select jsonb_agg(key) from jsonb_each_text(coalesce(pd->'roles','{}'::jsonb)) where value <> 'viewer' and key <> 't'), '[]'::jsonb),
      'status', coalesce(status,'not'), 'due','', 'priority','med', 'projectId', t_id, 'parentId', null,
      'files', coalesce(pd->'files','[]'::jsonb), 'thread', coalesce(pd->'thread','[]'::jsonb),
      'history', jsonb_build_array(jsonb_build_object('kind','converted','by',me,'from',pd->>'name') || st)));
    -- everything moves over; top-level items go under the new item, deeper layers keep their place
    update items set data = data || jsonb_build_object('projectId', t_id,
        'history', coalesce(data->'history','[]'::jsonb) || jsonb_build_array(jsonb_build_object('kind','moved','by',me,'from',pd->>'name','to',td->>'name') || st))
      || case when coalesce(data->>'parentId','') = '' then jsonb_build_object('parentId', nid) else '{}'::jsonb end,
      updated_at = now()
      where data->>'projectId' = p_id and id <> nid;
    -- people from the smaller project join the bigger one
    update projects set data = jsonb_set(data, '{roles}', coalesce((select jsonb_object_agg(key, case when value = 'viewer' then 'viewer' else 'editor' end) from jsonb_each_text(coalesce(pd->'roles','{}'::jsonb))), '{}'::jsonb) || coalesce(data->'roles','{}'::jsonb))
      || jsonb_build_object('thread', coalesce(data->'thread','[]'::jsonb) || jsonb_build_array(jsonb_build_object('id','u'||substr(md5(random()::text),1,10),'by',me,'text','“'||(pd->>'name')||'” was turned into an item in this project','sys',true) || st)),
      updated_at = now() where id = t_id;
    update asks set data = data || jsonb_build_object('projectId', t_id, 'itemId', coalesce(data->>'itemId', nid)), updated_at = now() where data->>'projectId' = p_id and data->>'kind' <> 'merge';
    update asks set data = data || jsonb_build_object('open', false), updated_at = now() where data->>'kind' = 'merge' and (data->>'projectId' = p_id or data->>'targetId' = p_id) and coalesce(id,'') <> coalesce(ask_id,'');
    update checkins set data = jsonb_set(data, '{active}', (select coalesce(jsonb_agg(case when e = to_jsonb('p:'||p_id) then to_jsonb('i:'||nid) else e end), '[]'::jsonb) from jsonb_array_elements(coalesce(data->'active','[]'::jsonb)) e)), updated_at = now()
      where data->'active' ? ('p:'||p_id);
    update projects set data = data || jsonb_build_object('parentId', null), updated_at = now() where data->>'parentId' = p_id;
    delete from projects where id = p_id;
  end if;
  if ask_id is not null then
    update asks set data = data || jsonb_build_object('open', false, 'result', 'approved'), updated_at = now() where id = ask_id;
  end if;
  return nid;
end $$;
revoke all on function public.jarvis_merge(text, text, text, text) from public, anon;
grant execute on function public.jarvis_merge(text, text, text, text) to authenticated;
revoke execute on function public.jarvis_check(text, jsonb, jsonb, text) from public, anon, authenticated;


drop policy if exists "jarvis read" on public.settings;
create policy "jarvis read" on public.settings for select to authenticated using (
  jarvis_is_teacher() or id like 'profile\_%' or id like 'week\_%' or id = 'mp_config'
  or (id like 'claim\_%' and data->>'by' = jarvis_me())
  or (id like 'post\_%' and coalesce((data->>'published')::boolean, false)));



select 'JARVIS is set up. Now run file 2.' as status;
