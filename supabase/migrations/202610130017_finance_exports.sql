begin;
-- STABLE uses the caller statement's MVCC snapshot across every register page.
create function charm.finance_export(p_view text,p_from date,p_to date,p_status text default '',p_owner bigint default null) returns jsonb language plpgsql stable security definer set search_path='' as $$declare data jsonb;rows jsonb;page integer:=2;begin
 data:=charm.finance_register(p_view,p_from,p_to,p_status,p_owner,1);
 if (data->>'total')::integer>5000 then raise exception 'financeExportLimit';end if;rows:=data->'rows';
 while jsonb_array_length(rows)<(data->>'total')::integer loop rows:=rows||(charm.finance_register(p_view,p_from,p_to,p_status,p_owner,page)->'rows');page:=page+1;end loop;return rows;
end$$;
revoke execute on function charm.finance_export(text,date,date,text,bigint) from public,anon;
grant execute on function charm.finance_export(text,date,date,text,bigint) to authenticated;
notify pgrst,'reload schema';
commit;
