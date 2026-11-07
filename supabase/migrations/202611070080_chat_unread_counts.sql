begin;

-- Return exact unread counts only for the authenticated user's conversations.
-- Keeping this count in the database avoids missing older unread messages when
-- the inbox preview is limited to recent messages.
create or replace function charm.chat_unread_counts()
returns table(conversation_id bigint, unread_count bigint)
language sql stable security definer set search_path=''
as $$
 select p.conversation_id,count(m.id)::bigint as unread_count
 from charm.chat_participants p
 join charm.chat_messages m on m.conversation_id=p.conversation_id
 where p.user_id=charm.require_actor()
  and m.sender_id<>p.user_id
  and m.created_at>p.last_read_at
 group by p.conversation_id;
$$;

revoke execute on function charm.chat_unread_counts() from public,anon;
grant execute on function charm.chat_unread_counts() to authenticated;
notify pgrst,'reload schema';
commit;
