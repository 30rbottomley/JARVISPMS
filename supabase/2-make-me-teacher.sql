-- Run AFTER file 1 and after you create your login in Authentication > Users.
-- Change YOUR-USERNAME and YOUR NAME below (use the same username as your login, e.g. smith for smith@jarvis.local). Safe to run again.
insert into public.people (id, pid, username, name, role)
select id, 't', 'volz', 'Mr. Volz', 'teacher' from auth.users where email = 'volz@jarvis.local'
on conflict (pid) do nothing;

select count(*) as teachers from public.people where role = 'teacher';
