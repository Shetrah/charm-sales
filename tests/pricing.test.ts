import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';

const db = new PGlite();
const admin = '00000000-0000-4000-8000-000000000001';
const sales = '00000000-0000-4000-8000-000000000002';
let keyCount = 500;
const key = () => `30000000-0000-4000-8000-${String(keyCount++).padStart(12, '0')}`;

async function scalar(sql: string, params: unknown[] = []): Promise<any> {
  const result = await db.query(sql, params);
  return Object.values(result.rows[0] ?? {})[0];
}
async function rows(sql: string, params: unknown[] = []): Promise<any[]> {
  return (await db.query(sql, params)).rows as any[];
}
async function asUser(id: string) {
  await db.exec('reset role');
  await db.query("select set_config('request.jwt.claim.sub',$1,false)", [id]);
  await db.exec('set role authenticated');
}
async function businessToday(): Promise<string> {
  return String(await scalar("select to_char((now() at time zone 'Africa/Nairobi')::date,'YYYY-MM-DD')"));
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
  await db.exec(`insert into auth.users values('${admin}','admin@test.invalid'),('${sales}','sales@test.invalid');
  insert into charm.users(id,name,email,password,role) values
   (1,'Admin','admin@test.invalid','legacy','admin'),
   (2,'Sales','sales@test.invalid','legacy','salesperson');
  insert into charm.auth_accounts(auth_user_id,salesperson_id) values('${admin}',1),('${sales}',2);
  insert into charm.clients(id,salesperson_id,name,contact,location) values(1,2,'Nairobi wholesale','Contact','Nairobi');`);
}, 60000);

afterAll(() => db.close());

describe.sequential('Quotation price book', () => {
  it('imports every quotation line without duplicating catalogue products', async () => {
    expect(await scalar('select count(*)::int from charm.products')).toBe(48);
    expect(await scalar('select count(*)::int from charm.quotation_rows')).toBe(48);
    expect(await scalar("select count(*)::int from charm.product_prices where source='quotation'")).toBe(192);
    expect(await scalar('select count(*)::int from charm.product_prices where source=\'quotation\' and customer_type=\'wholesaler\' and unit=\'bottle\'')).toBe(48);
    expect(await scalar("select count(*)::int from charm.product_prices where source='quotation' and customer_type='retailer' and unit='carton'")).toBe(48);
    expect(await scalar('select row_count from charm.quotation_batches limit 1')).toBe(48);
    expect(await scalar("select price from charm.product_prices where product_id=1 and customer_type='wholesaler' and unit='bottle'")).toBe('133.00');
    expect(await scalar("select price from charm.product_prices where product_id=1 and customer_type='wholesaler' and unit='carton'")).toBe('2660.00');
    expect(await scalar("select price from charm.product_prices where product_id=1 and customer_type='retailer' and unit='bottle'")).toBe('190.00');
    expect(await scalar("select price from charm.product_prices where product_id=1 and customer_type='retailer' and unit='carton'")).toBe('3800.00');
  });

  it('flags source anomalies while preserving the printed values', async () => {
    expect(await scalar("select count(*)::int from charm.products where 'duplicate_barcode'=any(pricing_flags)")).toBe(2);
    expect(await scalar("select count(*)::int from charm.products where 'ambiguous_fragrance'=any(pricing_flags)")).toBe(3);
    expect(await scalar("select count(*)::int from charm.products where 'capacity_typo'=any(pricing_flags)")).toBe(1);
    expect(await scalar("select count(*)::int from charm.products where 'verify_barcode'=any(pricing_flags)")).toBe(1);
    expect(await scalar('select count(*)::int from charm.products where needs_review')).toBe(7);
    expect(await scalar('select capacity from charm.products where id=24')).toBe('751ml');
    expect(await scalar('select barcode from charm.products where id=18')).toBe(await scalar('select barcode from charm.products where id=20'));
    expect(await scalar("select fragrance from charm.quotation_rows where line_no=19")).toBe('HEARTBEAT / WHISPER');
    expect(await scalar('select flag_count from charm.quotation_batches limit 1')).toBe(7);
  });

  it('exposes current bottle and carton prices by customer classification with the printed margin', async () => {
    await asUser(sales);
    const book = await rows('select * from charm.product_price_book()');
    expect(book).toHaveLength(48);
    const handwash = book.find((row: any) => row.product_id === 1);
    expect(Number(handwash.wholesale_bottle)).toBe(133);
    expect(Number(handwash.wholesale_carton)).toBe(2660);
    expect(Number(handwash.retail_bottle)).toBe(190);
    expect(Number(handwash.retail_carton)).toBe(3800);
    expect(Number(handwash.margin_percent)).toBe(30);
    expect(handwash.carton_quantity).toBe(20);
    // A gross profit margin is a commercial margin, never a commission rate.
    expect(await scalar('select count(*)::int from charm.commission_rules')).toBe(0);
    expect(await scalar('select count(*)::int from charm.commission_entries')).toBe(0);
  });

  it('keeps history when an administrator publishes an effective-dated price', async () => {
    await asUser(admin);
    const today = await businessToday();
    const tomorrow = await scalar("select to_char((now() at time zone 'Africa/Nairobi')::date + 1,'YYYY-MM-DD')");
    const priceId = await scalar('select charm.set_product_price($1,1,\'wholesaler\',\'bottle\',140,$2::date,\'Factory increase\')', [key(), tomorrow]);
    expect(Number(priceId)).toBeGreaterThan(0);
    expect(Number(await scalar('select charm.product_price_on(1,\'wholesaler\',\'bottle\',$1::date)', [today]))).toBe(133);
    expect(Number(await scalar('select charm.product_price_on(1,\'wholesaler\',\'bottle\',$1::date)', [tomorrow]))).toBe(140);
    const tomorrowBook = await rows('select * from charm.product_price_book($1::date) where product_id=1', [tomorrow]);
    expect(Number(tomorrowBook[0].wholesale_bottle)).toBe(140);
    const history = await rows('select * from charm.product_price_history(1) where customer_type=\'wholesaler\' and unit=\'bottle\' order by effective_from');
    expect(history).toHaveLength(2);
    expect(Number(history[0].price)).toBe(133);
    expect(Number(history[1].price)).toBe(140);
    await asUser(sales);
    await expect(db.query("select charm.set_product_price($1,1,'wholesaler','bottle',150,null,'')", [key()])).rejects.toThrow('forbidden');
  });

  it('fills omitted order-line prices from the book for wholesalers and retailers', async () => {
    await asUser(sales);
    const wholesale = await scalar("select charm.save_order_draft($1,null,1,null,$2,'wholesaler')", [
      key(),
      JSON.stringify([{ product_id: 1, quantity: 2, unit: 'bottle', unit_price: null }]),
    ]);
    expect(await scalar('select total from charm.orders where id=$1', [wholesale])).toBe('266.00');
    expect(await scalar('select unit_price from charm.order_items where order_id=$1', [wholesale])).toBe('133.00');

    const retailCarton = await scalar("select charm.save_order_draft($1,null,1,null,$2,'retailer')", [
      key(),
      JSON.stringify([{ product_id: 1, quantity: 1, unit: 'carton', unit_price: '' }]),
    ]);
    expect(await scalar('select total from charm.orders where id=$1', [retailCarton])).toBe('3800.00');
    expect(await scalar('select unit from charm.order_items where order_id=$1', [retailCarton])).toBe('carton');

    const explicit = await scalar("select charm.save_order_draft($1,null,1,null,$2,'retailer')", [
      key(),
      JSON.stringify([{ product_id: 1, quantity: 2, unit: 'bottle', unit_price: '150.00' }]),
    ]);
    expect(await scalar('select total from charm.orders where id=$1', [explicit])).toBe('300.00');
  });

  it('rejects a missing price when no approved book price exists for a new variant', async () => {
    await db.exec('reset role');
    const product = await scalar("insert into charm.products(category,capacity,fragrance,barcode,carton,unit_price) values('Test','100ml','Unscented','TEST-PRICE-0001',12,null) returning id");
    await asUser(sales);
    await expect(db.query("select charm.save_order_draft($1,null,1,null,$2,'retailer')", [
      key(),
      JSON.stringify([{ product_id: product, quantity: 1, unit: 'bottle', unit_price: null }]),
    ])).rejects.toThrow('priceRequired');
  });
});
