begin;
create function charm.submit_record(p_key uuid,p_kind text,p_date date,p_client bigint,p_budget text,p_notes text,p_follow_up date default null) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); old bigint; id bigint; budget numeric;
begin
 if p_kind not in ('plans','expenses','reports') or p_kind is null then raise exception 'invalid'; end if;
 old:=charm.claim(p_key,p_kind,jsonb_build_array(p_date,p_client,p_budget,p_notes,p_follow_up)); if old is not null then return old; end if;
 if p_date is null or coalesce(length(trim(p_notes)),0) not between 1 and 10000 then raise exception 'invalid'; end if;
 if p_kind in ('plans','expenses') and p_date<=(now() at time zone 'Africa/Nairobi')::date then raise exception 'advanceRequired'; end if;
 if p_client is not null and not exists(select 1 from charm.clients where clients.id=p_client and charm.can_access(salesperson_id)) then raise exception 'forbidden'; end if;
 if p_kind='expenses' and p_client is null then raise exception 'clientRequired'; end if;
 if p_follow_up is not null and p_follow_up<p_date then raise exception 'invalid'; end if;
 if p_budget is not null and p_budget<>'' then
  if p_budget !~ '^\d{1,8}(\.\d{1,2})?$' then raise exception 'invalidMoney'; end if;
  budget:=p_budget::numeric;
 end if;
 execute format('insert into charm.%I(submission_key,salesperson_id,date,client_id,budget,notes,status,created_at,updated_at) values($1,$2,$3,$4,$5,$6,''pending'',now(),now()) returning id',p_kind)
 into id using p_key,a,p_date,p_client,budget,p_notes;
 if p_kind='reports' then update charm.reports set follow_up_date=p_follow_up where reports.id=id; end if;
 perform charm.audit('submitted',p_kind,id); return charm.finish(p_key,id);
end $$;
create function charm.review_record(p_kind text,p_id bigint,p_approve boolean) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_admin(); r record;
begin
 if p_approve is null then raise exception 'invalid'; end if;
 if p_kind not in ('plans','expenses','reports') or p_kind is null then raise exception 'invalid'; end if;
 execute format('select * from charm.%I where id=$1 for update',p_kind) into r using p_id;
 if r.id is null then raise exception 'notFound'; end if;
 if r.salesperson_id=a then raise exception 'selfApproval'; end if;
 if r.status<>'pending' then raise exception 'alreadyReviewed'; end if;
 execute format('update charm.%I set status=$1,reviewed_by=$2,reviewed_at=now(),updated_at=now() where id=$3',p_kind) using case when p_approve then 'approved' else 'rejected' end,a,p_id;
 perform charm.audit(case when p_approve then 'approved' else 'rejected' end,p_kind,p_id);
end $$;

create function charm.submit_visit(p_key uuid,p_client bigint,p_lat numeric,p_lng numeric,p_accuracy numeric,p_outcome text,p_notes text,p_reason text,p_next text,p_follow_up date) returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); id bigint; old bigint;
begin
 old:=charm.claim(p_key,'visit',jsonb_build_array(p_client,p_lat,p_lng,p_accuracy,p_outcome,p_notes,p_reason,p_next,p_follow_up)); if old is not null then return old; end if;
 if not exists(select 1 from charm.clients where clients.id=p_client and charm.can_access(salesperson_id)) then raise exception 'forbidden'; end if;
 if p_lat is null or p_lng is null or p_accuracy is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 or p_accuracy not between 0 and 100000 then raise exception 'invalidLocation'; end if;
 if p_outcome is null or p_outcome not in ('order','follow-up','no-sale','payment-follow-up') or coalesce(length(trim(p_notes)),0) not between 1 and 10000 or coalesce(length(p_next),0)>1000 then raise exception 'invalid'; end if;
 if p_outcome='no-sale' and coalesce(length(trim(p_reason)),0) not between 1 and 1000 then raise exception 'reasonRequired'; end if;
 insert into charm.visits(submission_key,salesperson_id,client_id,check_in_at,latitude,longitude,accuracy_m,outcome,notes,unsuccessful_reason,next_action,follow_up_date,created_at,updated_at)
 values(p_key,a,p_client,now(),p_lat,p_lng,p_accuracy,p_outcome,p_notes,p_reason,p_next,p_follow_up,now(),now()) returning visits.id into id;
 perform charm.audit('checkedIn','visits',id); return charm.finish(p_key,id);
end $$;
create function charm.checkout_visit(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); v charm.visits;
begin
 select * into v from charm.visits where id=p_id for update;
 if not found or v.salesperson_id<>a then raise exception 'forbidden'; end if;
 if v.check_out_at is null then update charm.visits set check_out_at=now(),updated_at=now() where id=p_id; perform charm.audit('checkedOut','visits',p_id); end if;
end $$;
create function charm.start_workday() returns bigint language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); id bigint; w charm.workdays;
begin
 perform 1 from charm.users where users.id=a for update;
 select * into w from charm.workdays where salesperson_id=a and (ended_at is null or date=(now() at time zone 'Africa/Nairobi')::date) order by id desc limit 1;
 if found then if w.ended_at is not null then raise exception 'alreadyReviewed'; end if; return w.id; end if;
 insert into charm.workdays(salesperson_id,date,started_at) values(a,(now() at time zone 'Africa/Nairobi')::date,now()) returning workdays.id into id;
 return id;
end $$;
create function charm.end_workday(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
begin
 update charm.workdays set ended_at=coalesce(ended_at,now()) where id=p_id and salesperson_id=charm.require_actor();
 if not found then raise exception 'forbidden'; end if;
end $$;
create function charm.location_batch(p_workday bigint,p_points jsonb) returns integer language plpgsql security definer set search_path='' as $$
declare a bigint:=charm.require_actor(); w charm.workdays; point jsonb; at timestamptz; key uuid; old bigint; id bigint; lat numeric; lng numeric; accuracy numeric;
begin
 select * into w from charm.workdays where workdays.id=p_workday for update;
 if not found or w.salesperson_id<>a then raise exception 'forbidden'; end if;
 if p_points is null or jsonb_typeof(p_points)<>'array' then raise exception 'invalid'; end if;
 if jsonb_array_length(p_points) not between 1 and 200 then raise exception 'invalid'; end if;
 for point in select value from jsonb_array_elements(p_points) loop
  key:=(point->>'submission_key')::uuid; at:=(point->>'recorded_at')::timestamptz;
  lat:=(point->>'latitude')::numeric; lng:=(point->>'longitude')::numeric; accuracy:=(point->>'accuracy_m')::numeric;
  if at is null or at<w.started_at or at>coalesce(w.ended_at,now()) or lat is null or lng is null or accuracy is null or lat not between -90 and 90 or lng not between -180 and 180 or accuracy not between 0 and 100000 then raise exception 'invalidLocation'; end if;
  old:=charm.claim(key,'location',jsonb_build_object('workday',p_workday,'point',point));
  if old is null then
   insert into charm.location_points(submission_key,workday_id,latitude,longitude,accuracy_m,recorded_at,received_at) values(key,p_workday,lat,lng,accuracy,at,now()) returning location_points.id into id;
   perform charm.finish(key,id);
  end if;
 end loop;
 return jsonb_array_length(p_points);
end $$;
revoke execute on function charm.submit_record(uuid,text,date,bigint,text,text,date),charm.review_record(text,bigint,boolean),charm.submit_visit(uuid,bigint,numeric,numeric,numeric,text,text,text,text,date),charm.checkout_visit(bigint),charm.start_workday(),charm.end_workday(bigint),charm.location_batch(bigint,jsonb) from public,anon;
grant execute on function charm.submit_record(uuid,text,date,bigint,text,text,date),charm.review_record(text,bigint,boolean),charm.submit_visit(uuid,bigint,numeric,numeric,numeric,text,text,text,text,date),charm.checkout_visit(bigint),charm.start_workday(),charm.end_workday(bigint),charm.location_batch(bigint,jsonb) to authenticated;
commit;
