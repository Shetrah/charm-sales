import {test,expect,type Page} from '@playwright/test';
async function submitContract(page:Page,reference:string,file:string){
 await page.getByLabel('Contract reference',{exact:true}).fill(reference);
 await page.getByLabel('Signed by (client representative)',{exact:true}).fill('Client Signatory');
 await page.getByLabel('Contract terms and conditions',{exact:true}).fill('Payment, delivery and return terms accepted by the client for this order.');
 await page.getByRole('button',{name:'Save as draft',exact:true}).click();
 await expect(page.getByText(/Draft and contract details saved/)).toBeVisible();
 await page.getByLabel('Add signed contract page',{exact:true}).setInputFiles({name:file,mimeType:'application/pdf',buffer:Buffer.from('%PDF-1.4 contract')});
 await expect(page.getByText(file,{exact:true})).toBeVisible();
 await page.getByRole('button',{name:'Review contract before submitting',exact:true}).click();
 await page.getByLabel('I confirm the contract details and attached pages are complete and accurate.').check();
 await page.getByRole('button',{name:'Confirm and submit contract',exact:true}).click();
 await expect(page.getByRole('status').filter({hasText:'Contract submitted. Submit the order as a separate step'})).toBeVisible();
}
async function signIn(page:Page,email:string){
 await page.getByLabel('Email address').fill(email);await page.getByLabel('Password',{exact:true}).fill('test-password-123');await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await expect(page.locator('.sidebar-footer')).toBeVisible();
}
test('connected workspace, every direct route, translated tables and mobile navigation',async({page})=>{
 await page.goto('/');
 await signIn(page,'admin@test.invalid');
 await expect(page.getByRole('heading',{name:'Admin portal',exact:true,level:1})).toBeVisible();await page.goto('/dashboard');await expect(page.getByRole('heading',{name:'Overview',exact:true})).toBeVisible();
 await expect(page.locator('.team-ranking').getByText('Test Salesperson',{exact:true})).toBeVisible();
 for(const route of ['clients','products','orders','payments','balances','visits','plans','expenses','reports','reporting','routes','staff','audit','logistics']){
  await page.goto('/'+route);await expect(page.locator('main h1')).toBeVisible();await expect(page.getByRole('alert')).toHaveCount(0);
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth)).toBe(true);
 }
 await page.goto('/clients');await expect(page.locator(test.info().project.name==='mobile'?'.record-cards':'.desktop-records').getByText('Integration Client',{exact:true})).toBeVisible();
 await page.locator('.preferences').getByRole('button',{name:'English / 简体中文',exact:true}).click();await expect(page.locator('main h1')).toHaveText('客户');
 await page.locator('.preferences').getByRole('button',{name:'浅色模式',exact:true}).click();await page.reload();await expect(page.locator('html')).toHaveAttribute('data-theme','light');
 await expect(page.locator(test.info().project.name==='mobile'?'.record-cards':'.desktop-records').getByText('Integration Client',{exact:true})).toBeVisible();
 await page.getByRole('button',{name:'新建记录',exact:true}).click();await page.getByRole('button',{name:'保存',exact:true}).click();
 await expect(page.getByRole('dialog').getByRole('alert')).toHaveText('请检查填写内容并重试。');await page.getByRole('button',{name:'取消',exact:true}).click();
 for(const [route,title] of Object.entries({clients:'客户',products:'产品目录',orders:'订单',payments:'收款',balances:'余额',visits:'Client Visits',plans:'行程计划',expenses:'差旅申请',reports:'每日报告',reporting:'管理报告',routes:'每日路线',staff:'团队',audit:'审计记录',logistics:'订单物流'})){
  await page.goto('/'+route);await expect(page.locator('main h1')).toHaveText(title);await expect(page.getByRole('alert')).toHaveCount(0);
 }
 await page.goto('/clients');
 await page.screenshot({path:`tests/.artifacts/workspace-${test.info().project.name}.png`,fullPage:true});
});
test('team cards, complete staff profile and secure editing work on every screen size',async({page})=>{
 await page.goto('/staff');await signIn(page,'admin@test.invalid');await page.goto('/staff');await expect(page.locator('.person-card').filter({hasText:'Test Salesperson'})).toHaveCount(1);
 await page.locator('.person-card').filter({hasText:'Test Salesperson'}).getByRole('button',{name:'View details',exact:true}).click();
 await expect(page.getByRole('dialog')).toBeVisible();await expect(page.getByText('All-time confirmed sales',{exact:true})).toBeVisible();
 await page.getByRole('button',{name:'Edit staff information',exact:true}).last().click();
 await page.getByLabel('Phone',{exact:true}).fill('0712345678');await page.getByLabel('Territory / area',{exact:true}).fill('Nairobi');
 await page.getByRole('button',{name:'Save',exact:true}).click();await expect(page.locator('.profile-contact')).toContainText('0712345678');await expect(page.locator('.profile-contact')).toContainText('Nairobi');
 expect(await page.getByRole('dialog').evaluate(el=>el.scrollWidth<=el.clientWidth)).toBe(true);
 await page.locator('.dialog-body').evaluate(el=>{el.scrollTop=0;});await page.screenshot({path:`tests/.artifacts/staff-profile-${test.info().project.name}.png`});
 await page.locator('.dialog-actions').getByRole('button',{name:'Close',exact:true}).click();
 await page.goto('/routes');await expect(page.getByRole('button',{name:'Start workday',exact:true})).toHaveCount(0);
 await page.goto('/reports');await expect(page.getByRole('button',{name:'Create record',exact:true})).toHaveCount(0);
});
test.describe('desktop transaction and field workflows',()=>{
 test.skip(({isMobile})=>isMobile,'Desktop transaction coverage; responsive views are tested separately.');
test('admin can deactivate, reactivate and delete staff through confirmed controls',async({page})=>{
 await page.goto('/staff');await signIn(page,'admin@test.invalid');await page.goto('/staff');
 await page.locator('.person-card').filter({hasText:'Test Removable'}).getByRole('button',{name:'View details',exact:true}).click();
 const dialog=page.getByRole('dialog');await dialog.getByRole('button',{name:'Make inactive',exact:true}).click();await dialog.getByRole('button',{name:'Make inactive',exact:true}).click();await expect(dialog.locator('.profile-badges')).toContainText('Inactive');
 await dialog.getByRole('button',{name:'Reactivate staff',exact:true}).click();await dialog.getByRole('button',{name:'Reactivate staff',exact:true}).click();await expect(dialog.locator('.profile-badges')).toContainText('Active');
 await dialog.getByRole('button',{name:'Delete staff',exact:true}).click();await expect(dialog).toContainText('Their staff ID, clients, orders, payments and audit history are preserved.');await dialog.getByRole('button',{name:'Cancel',exact:true}).click();
 await dialog.getByRole('button',{name:'Delete staff',exact:true}).click();await dialog.getByRole('button',{name:'Delete staff',exact:true}).click();await expect(page.locator('dialog')).toHaveCount(0);await expect(page.locator('.person-card').filter({hasText:'Test Removable'})).toHaveCount(0);
});
test('an already-open admin page receives a new salesperson submission without a reload',async({page,browser})=>{
 await page.goto('/orders');await signIn(page,'admin@test.invalid');await page.goto('/orders');await expect(page.locator('main h1')).toHaveText('Orders');
 const context=await browser.newContext();try{
  const sales=await context.newPage();await sales.goto('http://127.0.0.1:5174/orders');await signIn(sales,'sales@test.invalid');await sales.goto('http://127.0.0.1:5174/orders');await sales.getByRole('button',{name:'Create record',exact:true}).click();
  await sales.getByRole('combobox',{name:'Find a client'}).selectOption({label:'Integration Client'});await sales.getByRole('combobox',{name:'Find a product variant'}).selectOption({index:1});await sales.getByLabel('Price per selected unit (KES)',{exact:true}).fill('7.25');
  await submitContract(sales,'CT-LIVE-1','live-contract.pdf');
  await sales.getByRole('button',{name:'Submit order for approval',exact:true}).click();await expect(sales.locator('dialog')).toHaveCount(0);
  await expect(page.getByRole('cell',{name:'7.25',exact:true})).toBeVisible({timeout:18000});
 }finally{await context.close();}
});
test('visit consent, GPS check-in and mandatory report close work and route logging is blocked outside visits',async({page,context})=>{
 await context.grantPermissions(['geolocation']);await context.setGeolocation({latitude:-1.286389,longitude:36.817223,accuracy:12});
 await page.addInitScript(()=>{navigator.geolocation.getCurrentPosition=success=>success({coords:{latitude:-1.286389,longitude:36.817223,accuracy:12,altitude:null,altitudeAccuracy:null,heading:null,speed:null},timestamp:Date.now()} as GeolocationPosition);});
 await page.goto('/visits');await signIn(page,'sales@test.invalid');
 await page.goto('/visits');await page.getByRole('button',{name:'Check in',exact:true}).click();
 await page.getByRole('combobox',{name:'Choose client'}).selectOption({label:'Integration Client'});
 await page.getByRole('checkbox').check();await page.getByRole('button',{name:'Check in',exact:true}).last().click();await expect(page.locator('dialog')).toHaveCount(0);
 await expect(page.locator('.desktop-records').getByText('captured')).toBeVisible();
 await page.getByRole('button',{name:'Complete report & close',exact:true}).click();
 const report=page.getByRole('dialog');
 await report.getByRole('button',{name:'Submit report & close',exact:true}).click();await expect(report).toBeVisible();
 await report.getByLabel('Discussion').fill('Discussed current stock and pricing');
 await report.getByLabel('Outcome').selectOption('follow-up');
 await report.getByLabel('Client feedback').fill('Interested in a larger order');
 await report.getByLabel('Sales opportunities').fill('Potential quarterly bulk order');
 await report.getByLabel('Follow-up actions').fill('Send quotation');
 await report.getByLabel('Follow-up deadline').fill(new Date(Date.now()+86400000).toISOString().slice(0,10));
 await report.getByRole('button',{name:'Submit report & close',exact:true}).click();await expect(page.locator('dialog')).toHaveCount(0);
 await page.getByRole('button',{name:'Visit details'}).click();await expect(page.getByText('Discussed current stock and pricing')).toBeVisible();await page.getByRole('button',{name:'Close',exact:true}).click();
 await page.goto('/routes');await page.getByRole('button',{name:'Start workday',exact:true}).click();await page.getByRole('button',{name:'Save',exact:true}).click();await expect(page.locator('dialog')).toHaveCount(0);
 await page.getByRole('button',{name:'View details',exact:true}).click();await page.getByRole('button',{name:'Report location now',exact:true}).click();await expect(page.getByRole('alert')).toHaveCount(1);
 await page.getByRole('button',{name:'End workday',exact:true}).click();await expect(page.getByRole('heading',{name:'Tracking status: Workday ended',exact:true})).toBeVisible();
});
test('salesperson submits an exact multi-line order through the connected application',async({page})=>{
 test.setTimeout(90000);
 await page.goto('/orders');await signIn(page,'sales@test.invalid');
 await page.goto('/orders');await expect(page.locator('main h1')).toHaveText('Orders');
 await page.getByRole('button',{name:'Create record',exact:true}).click();
 await page.getByRole('combobox',{name:'Find a client'}).selectOption({label:'Integration Client'});
 await page.getByRole('combobox',{name:'Find a product variant'}).selectOption({index:1});
 await page.getByLabel('Quantity',{exact:true}).fill('2');await page.getByLabel('Price per selected unit (KES)',{exact:true}).fill('12.35');
 await page.getByRole('button',{name:'Add line'}).click();
 await page.getByRole('combobox',{name:'Find a product variant'}).nth(1).selectOption({index:2});
 await page.getByLabel('Quantity',{exact:true}).nth(1).fill('3');await page.getByLabel('Unit',{exact:true}).nth(1).selectOption('carton');await page.getByLabel('Price per selected unit (KES)',{exact:true}).nth(1).fill('8.20');
 await expect(page.locator('.order-total')).toHaveText('Total (KES): 49.30');
 await submitContract(page,'CT-MULTI-1','signed-contract.pdf');
 await page.getByRole('button',{name:'Submit order for approval',exact:true}).click();await expect(page.locator('dialog')).toHaveCount(0);
 await expect(page.getByRole('cell',{name:'49.30',exact:true})).toBeVisible();
 await expect(page.getByRole('button',{name:'Confirm order',exact:true})).toHaveCount(0);
 await page.goto('/staff');await expect(page.locator('main h1')).toHaveText('Overview');
 await page.getByRole('button',{name:'Sign out',exact:true}).click();
 await signIn(page,'admin@test.invalid');
 await page.goto('/orders');await page.getByRole('row').filter({has:page.getByRole('cell',{name:'49.30',exact:true})}).getByRole('button',{name:'Confirm order',exact:true}).click();
 await page.getByLabel('I have reviewed the submitted contract and supporting documents.').check();
 await page.getByRole('dialog').getByRole('button',{name:'Confirm order',exact:true}).click();
 await expect(page.locator('dialog')).toHaveCount(0);await expect(page.getByRole('row').filter({has:page.getByRole('cell',{name:'49.30',exact:true})}).getByRole('cell',{name:'Confirmed',exact:true}).first()).toBeVisible();
 await page.getByRole('button',{name:'Sign out',exact:true}).click();
 await signIn(page,'sales@test.invalid');
 await page.goto('/payments');await page.getByRole('button',{name:'Create record',exact:true}).click();
 await page.getByRole('combobox',{name:'Find a confirmed order'}).selectOption({index:1});
 await page.getByLabel('Amount (KES)',{exact:true}).fill('10.00');await page.getByLabel('Payment reference',{exact:true}).fill('BROWSER-REF');
 await page.getByRole('button',{name:'Save',exact:true}).click();await expect(page.locator('dialog')).toHaveCount(0);
 await page.goto('/balances');await expect(page.getByRole('cell',{name:'49.30',exact:true}).last()).toBeVisible();
 await page.getByRole('button',{name:'Sign out',exact:true}).click();
 await signIn(page,'admin@test.invalid');
 await page.goto('/payments');await page.getByRole('button',{name:'Verify payment',exact:true}).click();
 await page.getByRole('dialog').getByRole('button',{name:'Verify payment',exact:true}).click();await expect(page.locator('dialog')).toHaveCount(0);
 await page.goto('/balances');await expect(page.getByRole('cell',{name:'39.30',exact:true})).toBeVisible();
 await page.goto('/logistics');await expect(page.locator('main h1')).toHaveText('Order Logistics');
 await page.getByRole('tab',{name:/Deliveries/}).click();
 await page.locator('.page-heading').getByRole('button',{name:'Plan delivery',exact:true}).click();
 const plan=page.getByRole('dialog');
 await plan.getByLabel('Confirmed order',{exact:true}).selectOption({index:1});
 await plan.getByLabel('Driver',{exact:true}).fill('Browser Driver');
 await plan.getByLabel('Vehicle',{exact:true}).fill('KDA 001A');
 await plan.getByRole('button',{name:'Save',exact:true}).click();
 await expect(page.getByText('Delivery planned',{exact:true})).toBeVisible();
 const delivery=page.locator('.logistics-card').filter({hasText:'Browser Driver'}).first();
 await expect(delivery.locator('.badge')).toHaveText('Planned');
 await delivery.getByRole('button',{name:'Dispatch',exact:true}).click();
 await page.getByRole('dialog').getByRole('button',{name:'Dispatch',exact:true}).click();
 await expect(page.getByText('Delivery dispatched',{exact:true})).toBeVisible();
 await expect(delivery.locator('.badge')).toHaveText('Dispatched');
 await delivery.getByRole('button',{name:'Mark delivered',exact:true}).click();
 await page.getByRole('dialog').getByRole('button',{name:'Mark delivered',exact:true}).click();
 await expect(page.getByText('Delivery delivered',{exact:true})).toBeVisible();
 await expect(delivery.locator('.badge')).toHaveText('Delivered');
 await delivery.getByRole('button',{name:'Open delivery note',exact:true}).click();
 const note=page.locator('dialog').last();
 await expect(note.locator('.commercial-doc h3')).toHaveText('Delivery Note');
 await expect(note.locator('.doc-number')).toHaveText(/^DN-\d{8}-\d{5}$/);
 await expect(note.locator('.doc-brand img')).toBeVisible();
 await expect(note.locator('.doc-lines tbody tr')).toHaveCount(2);
 await expect(note.locator('.doc-party').first()).toContainText('Integration Client');
 await note.getByRole('tab',{name:'Tax Invoice',exact:true}).click();
 await expect(note.locator('.doc-number')).toHaveText(/^CHM-INV-/);
 await expect(note.locator('.doc-toolbar, .doc-scroll').first()).toBeVisible();
 await expect(note.getByRole('button',{name:'Print',exact:true})).toBeVisible();
 expect(await note.evaluate(el=>el.scrollWidth<=el.clientWidth)).toBe(true);
 await note.locator('.dialog-actions').getByRole('button',{name:'Close',exact:true}).click();
 await page.getByRole('tab',{name:/Inventory ledger/}).click();
 await expect(page.locator('.logistics-ledger-row.dispatch').first()).toContainText('DN-');
 await expect(page.getByRole('alert')).toHaveCount(0);
});

});
