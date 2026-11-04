begin;
create table charm.chat_conversations(
 id bigserial primary key,
 title text not null default '',
 kind text not null default 'direct' check(kind in ('direct','group')),
 order_id bigint references charm.orders(id),
 created_by bigint not null references charm.users(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table charm.chat_participants(
 conversation_id bigint not null references charm.chat_conversations(id) on delete cascade,
 user_id bigint not null references charm.users(id) on delete cascade,
 joined_at timestamptz not null default now(),
 last_read_at timestamptz not null default now(),
 primary key(conversation_id,user_id)
);
create table charm.chat_messages(
 id bigserial primary key,
 conversation_id bigint not null references charm.chat_conversations(id) on delete cascade,
 sender_id bigint not null references charm.users(id),
 body text not null check(length(trim(body)) between 1 and 4000),
 created_at timestamptz not null default now()
);
alter table charm.chat_messages replica identity full;
create index chat_messages_conversation on charm.chat_messages(conversation_id,id desc);
create index chat_participants_user on charm.chat_participants(user_id,conversation_id);

create function charm.chat_people() returns table(id bigint,name text,role text,active boolean,photo_path text)
language sql stable security definer set search_path='' as $$
 select u.id,u.name::text,u.role::text,u.active,u.photo_path from charm.users u
 where u.active and not exists(select 1 from charm.staff_archives a where a.staff_id=u.id)
$$;

create function charm.chat_member(p_conversation bigint) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from charm.chat_participants p where p.conversation_id=p_conversation and p.user_id=charm.actor())
$$;
create function charm.touch_chat_conversation() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 update charm.chat_conversations set updated_at=new.created_at where id=new.conversation_id;
 return new;
end $$;
create trigger chat_message_touch after insert on charm.chat_messages
 for each row execute function charm.touch_chat_conversation();
alter table charm.chat_conversations enable row level security;
alter table charm.chat_participants enable row level security;
alter table charm.chat_messages enable row level security;
revoke all on charm.chat_conversations,charm.chat_participants,charm.chat_messages from public,anon,authenticated;
grant select on charm.chat_conversations,charm.chat_participants,charm.chat_messages to authenticated;
grant update(last_read_at) on charm.chat_participants to authenticated;
grant insert on charm.chat_messages to authenticated;
grant usage,select on sequence charm.chat_conversations_id_seq,charm.chat_messages_id_seq to authenticated;
grant update on charm.chat_conversations to authenticated;
create policy chat_conversation_member_read on charm.chat_conversations for select to authenticated using(charm.chat_member(id));
create policy chat_conversation_member_touch on charm.chat_conversations for update to authenticated using(charm.chat_member(id)) with check(charm.chat_member(id));
create policy chat_participant_member_read on charm.chat_participants for select to authenticated using(charm.chat_member(conversation_id));
create policy chat_participant_self_read_update on charm.chat_participants for update to authenticated using(user_id=charm.actor()) with check(user_id=charm.actor());
create policy chat_message_member_read on charm.chat_messages for select to authenticated using(charm.chat_member(conversation_id));
create policy chat_message_member_send on charm.chat_messages for insert to authenticated with check(sender_id=charm.actor() and charm.chat_member(conversation_id));

create function charm.chat_create(p_users bigint[],p_title text default '',p_order bigint default null) returns bigint
language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); peers bigint[]; cid bigint; member_id bigint; conversation_kind text;
begin
 peers:=array(select distinct x from unnest(coalesce(p_users,'{}')) x where x is not null and x<>a);
 if cardinality(peers)<1 or cardinality(peers)>49 then raise exception 'chatParticipantsInvalid'; end if;
 if exists(select 1 from unnest(peers) x left join charm.users u on u.id=x and u.active where u.id is null) then raise exception 'chatParticipantInactive'; end if;
 if p_order is not null and not exists(select 1 from charm.orders o where o.id=p_order and (charm.can_access(o.salesperson_id) or charm.finance_reader() or charm.logistics_desk())) then raise exception 'forbidden'; end if;
 conversation_kind:=case when cardinality(peers)=1 then 'direct' else 'group' end;
 if conversation_kind='direct' then
  select c.id into cid from charm.chat_conversations c where c.kind='direct' and c.order_id is not distinct from p_order
   and exists(select 1 from charm.chat_participants p where p.conversation_id=c.id and p.user_id=a)
   and exists(select 1 from charm.chat_participants p where p.conversation_id=c.id and p.user_id=peers[1])
   and (select count(*) from charm.chat_participants p where p.conversation_id=c.id)=2 limit 1;
 end if;
 if cid is null then
  insert into charm.chat_conversations(title,kind,order_id,created_by) values(left(trim(coalesce(p_title,'')),100),conversation_kind,p_order,a) returning id into cid;
  insert into charm.chat_participants(conversation_id,user_id) values(cid,a);
  foreach member_id in array peers loop insert into charm.chat_participants(conversation_id,user_id) values(cid,member_id); end loop;
 end if;
 return cid;
end $$;
create function charm.chat_mark_read(p_conversation bigint) returns void language plpgsql security definer set search_path='' as $$
begin update charm.chat_participants set last_read_at=now() where conversation_id=p_conversation and user_id=charm.require_actor(); if not found then raise exception 'forbidden'; end if; end $$;
revoke execute on function charm.chat_member(bigint),charm.chat_people(),charm.touch_chat_conversation(),charm.chat_create(bigint[],text,bigint),charm.chat_mark_read(bigint) from public,anon,authenticated;
grant execute on function charm.chat_member(bigint),charm.chat_people(),charm.chat_create(bigint[],text,bigint),charm.chat_mark_read(bigint) to authenticated;
do $$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='charm' and tablename='chat_messages') then alter publication supabase_realtime add table charm.chat_messages; end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='charm' and tablename='chat_conversations') then alter publication supabase_realtime add table charm.chat_conversations; end if;
 end if;
end $$;
commit;
