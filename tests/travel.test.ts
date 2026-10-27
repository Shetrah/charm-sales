import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
import { businessInputToInstant, formatBusinessDateTime, mondayOf } from '../src/lib/dates';

const db = new PGlite();
const admin = '00000000-0000-4000-8000-000000000001';
const a = '00000000-0000-4000-8000-000000000002';
const b = '00000000-0000-4000-8000-000000000003';
let keyCount = 100;
const key = () => `20000000-0000-4000-8000-${String(keyCount++).padStart(12, '0')}`;

async function scalar(sql: string, params: unknown[] = []): Promise<any> {
 const result = await db.query(sql, params);
 return Object.values(result.rows[0] ?? {})[0];
}
async function asUser(id: string) {
 await db.exec('reset role');
 await db.query("select set_config('request.jwt.claim.sub',$1,false)", [id]);
 await db.exec('set role authenticated');
}
async function today() {
 return String(await scalar("select to_char(now() at time zone 'Africa/Nairobi','YYYY-MM-DD')"));
}

beforeAll(async () => {
 await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
 create schema auth; create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 grant usage on schema auth to authenticated,anon; grant execute on function auth.uid() to authenticated,anon;
 create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
 create table storage.objects(id uuid default gen_random_uuid(),bucket_id text,name text,unique(bucket_id,name));alter table storage.objects enable row level security;
 grant usage on schema storage to authenticated,anon;grant select,insert,update,delete on storage.objects to authenticated,anon;`);
 for (const file of readdirSync('supabase/migrations').sort()) await db.exec(readFileSync(`supabase/migrations/${file}`, 'utf8'));
 await db.exec(`insert into auth.users values('${admin}','admin@test.invalid'),('${a}','a@test.invalid'),('${b}','b@test.invalid');
 insert into charm.users(id,name,email,password,role) values
  (1,'Admin','admin@test.invalid','legacy','admin'),
  (2,'Sales A','a@test.invalid','legacy','salesperson'),
  (3,'Sales B','b@test.invalid','legacy','salesperson'),
  (4,'Finance Officer','finance@test.invalid','legacy','finance_officer');
 insert into charm.auth_accounts(auth_user_id,salesperson_id) values('${admin}',1),('${a}',2),('${b}',3);
 insert into charm.clients(id,salesperson_id,name,contact,location) values(1,2,'Nairobi client','Contact','Nairobi'),(2,3,'Mombasa client','Contact','Mombasa');`);
}, 60000);

afterAll(() => db.close());

describe.sequential('Field travel & planning', () => {
 let plan = 0;
 let stop = 0;
 let date = '';
 let request = 0;
 let reviewed = 0;

 it('creates and submits an itinerary without creating a travel request and never counts planning as a visit', async () => {
  await asUser(a);
  date = await today();
  const appointment = businessInputToInstant(`${date}T23:30`);
  plan = await scalar('select charm.save_itinerary($1,null,$2,2,$3,$4,$5,$6,$7,$8::jsonb,null,false)', [
   key(), 'Nairobi route', date, 'Nairobi', 'car', 60, 'Customer visits', JSON.stringify([{ client_id: '1', appointment_at: appointment, objective: 'Stock review', expected_duration_minutes: 45, sequence: 1 }]),
  ]);
  expect(await scalar('select status from charm.plans where id=$1', [plan])).toBe('draft');
  expect(await scalar('select count(*)::int from charm.expenses where salesperson_id=2')).toBe(0);
  await db.query('select charm.submit_itinerary($1)', [plan]);
  expect(await scalar('select status from charm.plans where id=$1', [plan])).toBe('planned');
  expect(await scalar('select submitted_at is not null from charm.plans where id=$1', [plan])).toBe(true);
  expect(await scalar('select count(*)::int from charm.expenses where salesperson_id=2')).toBe(0);
  await db.query('select charm.finish_itinerary($1,false)', [plan]);
  expect(await scalar('select status from charm.plans where id=$1', [plan])).toBe('partially_completed');
  const totals = await scalar("select charm.report_totals($1,$1,null,null)", [date]);
  expect(totals.travel.itineraries).toBe(1);
  expect(totals.travel.plannedStops).toBe(1);
  expect(totals.travel.completedStops).toBe(0);
  expect(totals.travel.outstandingStops).toBe(1);
 });

 it('requires an authorized administrator, records the decision and notifies only the requester and approver', async () => {
  await asUser(a);
  const depart = businessInputToInstant(`${date}T06:00`);
  const back = businessInputToInstant(`${date}T18:00`);
  request = await scalar('select charm.save_travel_request($1,null,$2,$3,$4,$5,$6,1,false,$7,$8::jsonb,$9::jsonb,true)', [
   key(), 'Supplier meeting in Nakuru', 'Nairobi', 'Nakuru', depart, back, 'Visited supplier', JSON.stringify([{ kind: 'transport', label: 'Return fare', amount: '150.00' }]), JSON.stringify([String(plan)]),
  ]);
  expect(await scalar('select status from charm.expenses where id=$1', [request])).toBe('pending_approval');
  expect(await scalar('select travel_request_id from charm.plans where id=$1', [plan])).toBe(request);
  await db.exec('reset role');
  expect(await scalar("select count(*)::int from charm.finance_notifications where recipient_id=4 and entity='expenses' and entity_id=$1", [request])).toBe(0);
  expect(await scalar("select count(*)::int from charm.finance_notifications where recipient_id=3 and entity='expenses' and entity_id=$1", [request])).toBe(0);
  expect(await scalar("select count(*)::int from charm.finance_notifications where recipient_id=1 and event='travel_request_pending_approval' and entity_id=$1", [request])).toBe(1);

  await asUser(b);
  await expect(db.query("select charm.decide_travel_request($1,'approve',null)", [request])).rejects.toThrow('forbidden');
  await asUser(admin);
  await expect(db.query("select charm.decide_travel_request($1,'reject',null)", [request])).rejects.toThrow('reasonRequired');
  await db.query("select charm.decide_travel_request($1,'approve',null)", [request]);
  expect(await scalar('select status from charm.expenses where id=$1', [request])).toBe('approved');
  expect(await scalar('select decided_by from charm.expenses where id=$1', [request])).toBe(1);
  expect(await scalar('select decided_at is not null from charm.expenses where id=$1', [request])).toBe(true);
  await db.exec('reset role');
  expect(await scalar("select count(*)::int from charm.finance_notifications where recipient_id=2 and event='travel_request_approved' and entity_id=$1", [request])).toBe(1);
  expect(await scalar("select count(*)::int from charm.finance_notifications where recipient_id=4 and entity='expenses' and entity_id=$1", [request])).toBe(0);
  expect(await scalar('select count(*)::int from charm.finance_requests where source_expense_id=$1', [request])).toBe(0);
 });

 it('sends a material change on an approved itinerary back for reapproval and restores the linked status', async () => {
  await asUser(a);
  stop = await scalar('select id from charm.plan_stops where plan_id=$1', [plan]);
  const appointment = businessInputToInstant(`${date}T10:30`);
  await db.query('select charm.save_itinerary($1,$2,$3,2,$4,$5,$6,$7,$8,$9::jsonb,$10,false)', [
   key(), plan, 'Nairobi route', date, 'Nairobi', 'car', 60, 'Rescheduled customer visit', JSON.stringify([{ id: stop, client_id: '1', appointment_at: appointment, objective: 'Stock review', expected_duration_minutes: 45, sequence: 1 }]), request,
  ]);
  expect(await scalar('select status from charm.expenses where id=$1', [request])).toBe('pending_approval');
  expect(await scalar('select decided_by is null and decided_at is null from charm.expenses where id=$1', [request])).toBe(true);
  expect(String(await scalar('select decision_reason from charm.expenses where id=$1', [request]))).toContain('reapproval');
  await db.exec('reset role');
  expect(await scalar("select count(*)::int from charm.audit_logs where action='travel_request_reapproval_required' and entity_id=$1", [request])).toBe(1);
  expect(await scalar('select status from charm.plan_stops where id=$1', [stop])).toBe('rescheduled');
  await asUser(admin);
  await db.query("select charm.decide_travel_request($1,'approve','Change accepted')", [request]);
  expect(await scalar('select status from charm.expenses where id=$1', [request])).toBe('approved');
  await asUser(a);
  await db.query('select charm.start_itinerary($1)', [plan]);
  expect(await scalar('select status from charm.plans where id=$1', [plan])).toBe('in_progress');
 });

 it('links a saved visit to the planned stop and separates estimated, approved and actual amounts', async () => {
  await asUser(a);
  const visit = await scalar("select charm.start_visit($1,1,true,-1.286389,36.817223,9,'captured',null)", [key()]);
  await db.query("select charm.submit_visit_report($1,$2,'Discussed stock and pricing','follow-up','Wants a larger pack','Quarterly order','Send quotation',(now() at time zone 'Africa/Nairobi')::date+2,2)", [key(), visit]);
  expect(await scalar('select visit_id from charm.plan_stops where id=$1', [stop])).toBe(visit);
  expect(await scalar('select status from charm.plan_stops where id=$1', [stop])).toBe('completed');
  await db.query('select charm.finish_itinerary($1,false)', [plan]);
  expect(await scalar('select status from charm.plans where id=$1', [plan])).toBe('completed');

  const totals = await scalar("select charm.report_totals($1,$1,null,null)", [date]);
  expect(totals.travel.itineraries).toBe(1);
  expect(totals.travel.plannedStops).toBe(1);
  expect(totals.travel.completedStops).toBe(1);
  expect(totals.travel.outstandingStops).toBe(0);
  expect(totals.travel.missedStops).toBe(0);
  expect(totals.travel.rescheduledStops).toBe(1);
  expect(Number(totals.travel.estimatedCost)).toBe(150);
  expect(Number(totals.travel.approvedCost)).toBe(150);
  expect(Number(totals.travel.actualCost)).toBe(0);
 });

 it('routes a policy-threshold request through finance and notifies finance once', async () => {
  await asUser(admin);
  await db.query('select charm.save_travel_policy(100)');
  await asUser(a);
  const depart = businessInputToInstant(`${date}T06:00`);
  const back = businessInputToInstant(`${date}T18:00`);
  reviewed = await scalar('select charm.save_travel_request($1,null,$2,$3,$4,$5,$6,null,false,$7,$8::jsonb,null,true)', [
   key(), 'Finance-reviewed supplier trip', 'Nairobi', 'Kisumu', depart, back, 'Supplier review', JSON.stringify([{ kind: 'accommodation', label: 'One night', amount: '150.00' }]),
  ]);
  await asUser(admin);
  await db.query("select charm.decide_travel_request($1,'approve',null)", [reviewed]);
  expect(await scalar('select status from charm.expenses where id=$1', [reviewed])).toBe('finance_review');
  expect(await scalar('select finance_review_required from charm.expenses where id=$1', [reviewed])).toBe(true);
  await db.exec('reset role');
  expect(await scalar("select count(*)::int from charm.finance_notifications where recipient_id=4 and event='travel_request_finance_review' and entity_id=$1", [reviewed])).toBe(1);
  await asUser(admin);
  await db.query("select charm.finance_decide_travel_request($1,'approve',null)", [reviewed]);
  expect(await scalar('select status from charm.expenses where id=$1', [reviewed])).toBe('approved');
  await db.exec('reset role');

  const totals = await scalar("select charm.report_totals($1,$1,null,null)", [date]);
  expect(Number(totals.travel.estimatedCost)).toBe(300);
  expect(Number(totals.travel.approvedCost)).toBe(300);
  expect(Number(totals.travel.actualCost)).toBe(0);
  expect(totals.travel.requestsSubmitted).toBe(2);
  expect(totals.travel.requestsAwaitingApproval).toBe(0);
  expect(totals.travel.requestsApproved).toBe(2);
 });

 it('uses half-open Kenyan midnight and Monday-based reporting boundaries', async () => {
  await db.exec('reset role');
  const insert = "insert into charm.visits(submission_key,salesperson_id,client_id,check_in_at,latitude,longitude,accuracy_m,gps_status,outcome,notes,discussion,client_feedback,sales_opportunities,next_action,follow_up_date,created_at,updated_at) values($1,2,1,$2,-1.2,36.8,9,'captured','follow-up','x','x','x','x','x','2025-06-20',now(),now())";
  await db.query(insert, [key(), '2025-06-10T20:59:30Z']);
  await db.query(insert, [key(), '2025-06-10T21:00:30Z']);
  expect(await scalar("select ((charm.business_day_start('2025-06-10')) at time zone 'UTC')::text")).toBe('2025-06-09 21:00:00');
  expect(await scalar("select ((charm.business_day_end('2025-06-10')) at time zone 'UTC')::text")).toBe('2025-06-10 21:00:00');
  const day10 = await scalar("select charm.report_totals('2025-06-10','2025-06-10',null,null)");
  const day11 = await scalar("select charm.report_totals('2025-06-11','2025-06-11',null,null)");
  expect(day10.visits).toBe(1);
  expect(day11.visits).toBe(1);
  expect(mondayOf('2025-06-10')).toBe('2025-06-09');
  const week = await scalar("select charm.report_totals('2025-06-09','2025-06-15',null,null)");
  expect(week.visits).toBe(2);
  const month = await scalar("select charm.report_totals('2025-06-01','2025-06-30',null,null)");
  expect(month.visits).toBe(2);
  expect(formatBusinessDateTime('2025-06-10T20:59:30Z')).toBe('10 Jun 2025, 23:59 EAT');
  expect(formatBusinessDateTime('2025-06-10T21:00:30Z')).toBe('11 Jun 2025, 00:00 EAT');
 });
});
