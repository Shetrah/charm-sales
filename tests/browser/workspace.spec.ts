import {test,expect} from '@playwright/test';
test('connected workspace, every direct route, translated tables and mobile navigation',async({page})=>{
 await page.goto('/');
 await page.getByLabel('Email address').fill('admin@test.invalid');await page.getByLabel('Password',{exact:true}).fill('test-password-123');await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await expect(page.getByRole('heading',{name:'Admin portal',exact:true,level:1})).toBeVisible();await page.goto('/dashboard');await expect(page.getByRole('heading',{name:'Overview',exact:true})).toBeVisible();
 await expect(page.locator('.team-ranking').getByText('Test Salesperson',{exact:true})).toBeVisible();
 for(const route of ['clients','products','orders','payments','balances','visits','plans','expenses','reports','routes','staff','audit']){
  await page.goto('/'+route);await expect(page.locator('main h1')).toBeVisible();await expect(page.getByRole('alert')).toHaveCount(0);
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth)).toBe(true);
 }
 await page.goto('/clients');await expect(page.locator(test.info().project.name==='mobile'?'.record-cards':'.desktop-records').getByText('Integration Client',{exact:true})).toBeVisible();
 await page.getByRole('button',{name:'English / 简体中文'}).click();await expect(page.locator('main h1')).toHaveText('客户');
 await page.getByRole('button',{name:'深色模式'}).click();await page.reload();await expect(page.locator('html')).toHaveAttribute('data-theme','dark');
 await expect(page.locator(test.info().project.name==='mobile'?'.record-cards':'.desktop-records').getByText('Integration Client',{exact:true})).toBeVisible();
 await page.getByRole('button',{name:'新建记录',exact:true}).click();await page.getByRole('button',{name:'保存',exact:true}).click();
 await expect(page.getByRole('dialog').getByRole('alert')).toHaveText('请检查填写内容并重试。');await page.getByRole('button',{name:'取消',exact:true}).click();
 for(const [route,title] of Object.entries({clients:'客户',products:'产品目录',orders:'订单',payments:'收款',balances:'余额',visits:'Client Visits',plans:'行程计划',expenses:'差旅申请',reports:'每日报告',routes:'每日路线',staff:'团队',audit:'审计记录'})){
  await page.goto('/'+route);await expect(page.locator('main h1')).toHaveText(title);await expect(page.getByRole('alert')).toHaveCount(0);
 }
 await page.goto('/clients');
 await page.screenshot({path:`tests/.artifacts/workspace-${test.info().project.name}.png`,fullPage:true});
});
test('team cards, complete staff profile and secure editing work on every screen size',async({page})=>{
 await page.goto('/staff');await page.getByLabel('Email address').fill('admin@test.invalid');await page.getByLabel('Password',{exact:true}).fill('test-password-123');await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await page.goto('/staff');await expect(page.locator('.person-card').filter({hasText:'Test Salesperson'})).toHaveCount(1);
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
 await page.goto('/staff');await page.getByLabel('Email address').fill('admin@test.invalid');await page.getByLabel('Password',{exact:true}).fill('test-password-123');await page.getByRole('button',{name:'Sign in',exact:true}).click();await expect(page.locator('.sidebar-footer')).toBeVisible();await page.goto('/staff');
 await page.locator('.person-card').filter({hasText:'Test Removable'}).getByRole('button',{name:'View details',exact:true}).click();
 const dialog=page.getByRole('dialog');await dialog.getByRole('button',{name:'Make inactive',exact:true}).click();await dialog.getByRole('button',{name:'Make inactive',exact:true}).click();await expect(dialog.locator('.profile-badges')).toContainText('Inactive');
 await dialog.getByRole('button',{name:'Reactivate staff',exact:true}).click();await dialog.getByRole('button',{name:'Reactivate staff',exact:true}).click();await expect(dialog.locator('.profile-badges')).toContainText('Active');
 await dialog.getByRole('button',{name:'Delete staff',exact:true}).click();await expect(dialog).toContainText('Their staff ID, clients, orders, payments and audit history are preserved.');await dialog.getByRole('button',{name:'Cancel',exact:true}).click();
 await dialog.getByRole('button',{name:'Delete staff',exact:true}).click();await dialog.getByRole('button',{name:'Delete staff',exact:true}).click();await expect(page.locator('dialog')).toHaveCount(0);await expect(page.locator('.person-card').filter({hasText:'Test Removable'})).toHaveCount(0);
});
test('an already-open admin page receives a new salesperson submission without a reload',async({page,browser})=>{
 await page.goto('/orders');await page.getByLabel('Email address').fill('admin@test.invalid');await page.getByLabel('Password',{exact:true}).fill('test-password-123');await page.getByRole('button',{name:'Sign in',exact:true}).click();await page.goto('/orders');await expect(page.locator('main h1')).toHaveText('Orders');
 const context=await browser.newContext();try{
  const sales=await context.newPage();await sales.goto('http://127.0.0.1:5174/orders');await sales.getByLabel('Email address').fill('sales@test.invalid');await sales.getByLabel('Password',{exact:true}).fill('test-password-123');await sales.getByRole('button',{name:'Sign in',exact:true}).click();await sales.goto('http://127.0.0.1:5174/orders');await sales.getByRole('button',{name:'Create record',exact:true}).click();
  await sales.getByRole('combobox',{name:'Find a client'}).selectOption({label:'Integration Client'});await sales.getByRole('combobox',{name:'Find a product variant'}).selectOption({index:1});await sales.getByLabel('Price per selected unit (KES)',{exact:true}).fill('7.25');await sales.getByRole('button',{name:'Save as draft',exact:true}).click();await sales.locator('input[type=file]').setInputFiles({name:'contract.pdf',mimeType:'application/pdf',buffer:Buffer.from('%PDF-1.4 test')});await expect(sales.getByText(/Contract uploaded/)).toBeVisible();await sales.getByRole('button',{name:'Submit order',exact:true}).click();await expect(sales.locator('dialog')).toHaveCount(0);
  await expect(page.getByRole('cell',{name:'7.25',exact:true})).toBeVisible({timeout:18000});
 }finally{await context.close();}
});
test('visit consent, GPS check-in and mandatory report close work and route logging is blocked outside visits',async({page,context})=>{
 await context.grantPermissions(['geolocation']);await context.setGeolocation({latitude:-1.286389,longitude:36.817223,accuracy:12});
 await page.goto('/visits');await page.getByLabel('Email address').fill('sales@test.invalid');await page.getByLabel('Password',{exact:true}).fill('test-password-123');await page.getByRole('button',{name:'Sign in',exact:true}).click();
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
 test.setTimeout(60000);
 await page.goto('/orders');await page.getByLabel('Email address').fill('sales@test.invalid');await page.getByLabel('Password',{exact:true}).fill('test-password-123');await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await page.goto('/orders');await expect(page.locator('main h1')).toHaveText('Orders');
 await page.getByRole('button',{name:'Create record',exact:true}).click();
 await page.getByRole('combobox',{name:'Find a client'}).selectOption({label:'Integration Client'});
 await page.getByRole('combobox',{name:'Find a product variant'}).selectOption({index:1});
 await page.getByLabel('Quantity',{exact:true}).fill('2');await page.getByLabel('Price per selected unit (KES)',{exact:true}).fill('12.35');
 await page.getByRole('button',{name:'Add line'}).click();
 await page.getByRole('combobox',{name:'Find a product variant'}).nth(1).selectOption({index:2});
 await page.getByLabel('Quantity',{exact:true}).nth(1).fill('3');await page.getByLabel('Unit',{exact:true}).nth(1).selectOption('carton');await page.getByLabel('Price per selected unit (KES)',{exact:true}).nth(1).fill('8.20');
 await expect(page.locator('.order-total')).toHaveText('Total (KES): 49.30');
 await page.getByRole('button',{name:'Save as draft',exact:true}).click();await page.locator('input[type=file]').setInputFiles({name:'signed-contract.pdf',mimeType:'application/pdf',buffer:Buffer.from('%PDF-1.4 contract')});await expect(page.getByText(/Contract uploaded/)).toBeVisible();await page.getByRole('button',{name:'Submit order',exact:true}).click();await expect(page.locator('dialog')).toHaveCount(0);
 await expect(page.getByRole('cell',{name:'49.30',exact:true})).toBeVisible();
 await expect(page.getByRole('button',{name:'Confirm order',exact:true})).toHaveCount(0);
 await page.goto('/staff');await expect(page.locator('main h1')).toHaveText('Overview');
 await page.getByRole('button',{name:'Sign out',exact:true}).click();
 await page.getByLabel('Email address').fill('admin@test.invalid');await page.getByLabel('Password',{exact:true}).fill('test-password-123');await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await page.goto('/orders');await page.getByRole('row').filter({has:page.getByRole('cell',{name:'49.30',exact:true})}).getByRole('button',{name:'Confirm order',exact:true}).click();
 await page.getByRole('dialog').getByRole('button',{name:'Confirm order',exact:true}).click();
 await expect(page.locator('dialog')).toHaveCount(0);await expect(page.getByRole('cell',{name:'Confirmed',exact:true})).toBeVisible();
 await page.getByRole('button',{name:'Sign out',exact:true}).click();
 await page.getByLabel('Email address').fill('sales@test.invalid');await page.getByLabel('Password',{exact:true}).fill('test-password-123');await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await page.goto('/payments');await page.getByRole('button',{name:'Create record',exact:true}).click();
 await page.getByRole('combobox',{name:'Find a confirmed order'}).selectOption({index:1});
 await page.getByLabel('Amount (KES)',{exact:true}).fill('10.00');await page.getByLabel('Payment reference',{exact:true}).fill('BROWSER-REF');
 await page.getByRole('button',{name:'Save',exact:true}).click();await expect(page.locator('dialog')).toHaveCount(0);
 await page.goto('/balances');await expect(page.getByRole('cell',{name:'49.30',exact:true}).last()).toBeVisible();
 await page.getByRole('button',{name:'Sign out',exact:true}).click();
 await page.getByLabel('Email address').fill('admin@test.invalid');await page.getByLabel('Password',{exact:true}).fill('test-password-123');await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await page.goto('/payments');await page.getByRole('button',{name:'Verify payment',exact:true}).click();
 await page.getByRole('dialog').getByRole('button',{name:'Verify payment',exact:true}).click();await expect(page.locator('dialog')).toHaveCount(0);
 await page.goto('/balances');await expect(page.getByRole('cell',{name:'39.30',exact:true})).toBeVisible();
});

});
