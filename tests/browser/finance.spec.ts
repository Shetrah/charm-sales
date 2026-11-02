import {test,expect,type Page} from '@playwright/test';
import {readFileSync} from 'node:fs';
async function login(page:Page,email:string){await page.goto('/finance');await page.getByLabel('Email address').fill(email);await page.getByLabel('Password',{exact:true}).fill('test-password-123');await page.getByRole('button',{name:'Sign in',exact:true}).click();await expect(page.locator('.sidebar-footer')).toBeVisible();await expect(page.locator('main h1')).toHaveText(email==='sales@test.invalid'?'My financial requests':'Finance dashboard');}
const pdf={name:'receipt.pdf',mimeType:'application/pdf',buffer:Buffer.from('%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\n%%EOF')};
async function signIn(page:Page,email:string){await page.goto('/');await page.getByLabel('Email address').fill(email);await page.getByLabel('Password',{exact:true}).fill('test-password-123');await page.getByRole('button',{name:'Sign in',exact:true}).click();await expect(page.locator('.sidebar-footer')).toBeVisible();}
test('finance workspace is responsive, role-specific, translated and keeps the dashboard accessible',async({page})=>{
 await login(page,'manager@test.invalid');
 for(const pageName of ['requests','disbursements','accountability','cashbook','expenses','receipts','budgets','statements','accounts','audit']){await page.goto('/finance/'+pageName);await expect(page.locator('main h1')).toBeVisible();await expect(page.getByRole('alert')).toHaveCount(0);expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);}
 // The retired expenditure and operating bookmarks open the consolidated register instead of a second expense book.
 for(const retired of ['expenditure','operating']){await page.goto('/finance/'+retired);await expect(page).toHaveURL(/\/finance\/expenses$/);await expect(page.getByRole('heading',{level:2,name:'Company expense register',exact:true})).toBeVisible();await expect(page.getByRole('button',{name:'Record expense',exact:true})).toBeVisible();}
 await page.goto('/finance/accounts');
 await expect(page.getByRole('button',{name:'Request funds',exact:true})).toHaveCount(0);await expect(page.locator('.sidebar nav').getByText('Team',{exact:true})).toHaveCount(0);
 await page.goto('/finance/accounts');await page.getByRole('button',{name:'Verify payment recipient',exact:true}).click();await expect(page.getByRole('dialog')).toBeVisible();expect(await page.getByRole('dialog').evaluate(el=>el.scrollWidth<=el.clientWidth)).toBe(true);await page.getByRole('button',{name:'Cancel',exact:true}).click();
 await page.locator('.preferences').getByRole('button',{name:'English / 简体中文',exact:true}).click();await expect(page.locator('main h1')).toHaveText('账户与收款人');await page.locator('.preferences').getByRole('button',{name:'浅色模式',exact:true}).click();await page.goto('/finance');await expect(page.locator('.finance-queue-grid')).toBeVisible();await page.screenshot({path:`tests/.artifacts/finance-${test.info().project.name}.png`,fullPage:true});
});
test.describe('desktop finance lifecycle',()=>{
 test.skip(({isMobile})=>isMobile,'Complete transaction flow covered on desktop; responsive views run on all sizes.');
 test('salesperson request, admin decision, finance partial payments, accountability, notifications and exports',async({page,browser})=>{
  test.setTimeout(120000);await login(page,'manager@test.invalid');
  await page.goto('/finance/accounts');await page.getByRole('button',{name:'Add payment account',exact:true}).click();await page.getByLabel('Name',{exact:true}).fill('Operations test M-Pesa');await page.getByLabel('Payment method',{exact:true}).selectOption('M-Pesa');await page.getByRole('button',{name:'Save',exact:true}).click();await expect(page.getByRole('dialog')).toHaveCount(0);
  await page.getByRole('button',{name:'Record opening funds',exact:true}).click();await page.getByLabel('Payment account',{exact:true}).selectOption({label:'Operations test M-Pesa'});await page.getByLabel('Amount (KES)',{exact:true}).fill('500.00');await page.getByLabel('Payment reference',{exact:true}).fill('OPEN-BROWSER');await page.getByRole('checkbox').check();await page.getByRole('button',{name:'Save',exact:true}).click();await expect(page.getByRole('dialog')).toHaveCount(0);
  await page.goto('/finance/budgets');await page.getByRole('button',{name:'Set monthly budget',exact:true}).click();await page.getByLabel('Expense category',{exact:true}).selectOption({label:'Travel'});await page.getByLabel('Amount (KES)',{exact:true}).fill('1000.00');await page.getByRole('button',{name:'Save',exact:true}).click();await expect(page.getByRole('dialog')).toHaveCount(0);
  await page.goto('/finance/accounts');await page.getByRole('button',{name:'Verify payment recipient',exact:true}).click();await page.getByLabel('Team',{exact:true}).selectOption({label:'Test Salesperson'});await page.getByLabel('Name',{exact:true}).fill('Test Salesperson');await page.getByRole('dialog').locator('textarea').fill('Verified M-Pesa destination 0700000000');await page.getByRole('button',{name:'Save',exact:true}).click();await expect(page.getByRole('dialog')).toHaveCount(0);
  const salesContext=await browser.newContext(),sales=await salesContext.newPage();const adminContext=await browser.newContext(),admin=await adminContext.newPage();const officerContext=await browser.newContext(),officer=await officerContext.newPage();
  try{
   await login(sales,'sales@test.invalid');await sales.getByRole('button',{name:'Request funds',exact:true}).click();await sales.getByLabel('Amount (KES)',{exact:true}).fill('100.00');await sales.getByLabel('Expense category',{exact:true}).selectOption({label:'Travel'});await sales.getByLabel('Purpose',{exact:true}).fill('Delivery support 中文核销');await sales.getByRole('dialog').locator('input[type=file]').setInputFiles(pdf);
   // Commit on the real SQL transport, then simulate a lost response. Retry must preserve one request.
   await sales.route('**/rpc/finance_submit_request',async route=>{await route.fetch();await route.fulfill({status:400,contentType:'application/json',body:JSON.stringify({message:'genericError',code:'test_lost_response'})});},{times:1});
   await sales.getByRole('button',{name:'Save',exact:true}).click();await expect(sales.getByRole('dialog').getByRole('alert')).toBeVisible();await sales.getByRole('button',{name:'Save',exact:true}).click();await expect(sales.getByRole('dialog')).toHaveCount(0);await expect(sales.locator('.desktop-records tbody tr').filter({hasText:'Delivery support 中文核销'})).toHaveCount(1);
   await sales.evaluate(()=>{const original=AudioContext.prototype.createOscillator;(window as any).__financeSounds=0;AudioContext.prototype.createOscillator=function(){(window as any).__financeSounds++;return original.call(this);};});await sales.getByRole('button',{name:/Notifications/}).click();await sales.getByRole('button',{name:'Enable sound',exact:true}).click();await expect(sales.getByRole('button',{name:'Mute alerts',exact:true})).toBeVisible();await sales.getByRole('dialog').getByRole('button',{name:'Close',exact:true}).click();
   await login(officer,'officer@test.invalid');await officer.goto('/finance/disbursements');await expect(officer.locator('.desktop-records tbody tr').filter({hasText:'Delivery support 中文核销'})).toHaveCount(0);
   await login(admin,'admin@test.invalid');await admin.goto('/finance/requests');const adminRow=admin.locator('.desktop-records tbody tr').filter({hasText:'Delivery support 中文核销'});await adminRow.getByRole('button',{name:'View details',exact:true}).click();await admin.getByRole('button',{name:'Review',exact:true}).click();await admin.getByRole('button',{name:'Save',exact:true}).click();await expect(admin.getByRole('dialog').locator('.finance-detail-title')).toContainText('Approved');
   const row=officer.locator('.desktop-records tbody tr').filter({hasText:'Delivery support 中文核销'});await expect(row).toBeVisible();await row.getByRole('button',{name:'View details',exact:true}).click();
   for(const [amount,reference] of [['60.00','BROWSER-PART-1'],['40.00','BROWSER-PART-2']]){await officer.getByRole('button',{name:'Record confirmed payment',exact:true}).click();await officer.getByLabel('Amount (KES)',{exact:true}).fill(amount);await officer.getByLabel('Payment account',{exact:true}).selectOption({label:'Operations test M-Pesa'});await officer.getByLabel('Payment reference',{exact:true}).fill(reference);await officer.getByRole('dialog').locator('input[type=file]').setInputFiles(pdf);await officer.getByRole('checkbox').check();await officer.getByRole('button',{name:'Save',exact:true}).click();await expect(officer.locator('.finance-detail-title')).toContainText(reference.endsWith('1')?'Partially disbursed':'Fully disbursed');}
   await expect(officer.locator('.finance-detail-title')).toContainText('Fully disbursed');
   await sales.bringToFront();await expect.poll(()=>sales.evaluate(()=>(window as any).__financeSounds),{timeout:15000}).toBeGreaterThan(0);const sounds=await sales.evaluate(()=>(window as any).__financeSounds);await sales.getByRole('button',{name:/Notifications/}).click();await sales.getByRole('button',{name:'Mark all read',exact:true}).click();await sales.getByRole('dialog').getByRole('button',{name:'Close',exact:true}).click();await expect(sales.getByRole('button',{name:'Notifications (0)',exact:true})).toBeVisible();expect(await sales.evaluate(()=>(window as any).__financeSounds)).toBe(sounds);
   await sales.reload();await sales.locator('.desktop-records tbody tr').filter({hasText:'Delivery support 中文核销'}).getByRole('button',{name:'View details',exact:true}).click();await sales.getByRole('button',{name:'Submit accountability',exact:true}).click();await sales.getByLabel('Amount (KES)',{exact:true}).fill('100.00');await sales.getByLabel('Expenditure report',{exact:true}).fill('Actual delivery costs with receipt 中文收据');await sales.getByRole('dialog').locator('input[type=file]').setInputFiles(pdf);await sales.getByRole('button',{name:'Save',exact:true}).click();await expect(sales.locator('.finance-detail-title')).toBeVisible();
   await officer.reload();await officer.locator('.finance-entry').filter({hasText:'Actual delivery costs'}).getByRole('button',{name:'Review',exact:true}).click();await officer.getByRole('button',{name:'Save',exact:true}).click();await expect(officer.locator('.finance-entry').filter({hasText:'Actual delivery costs'})).toContainText('Accepted');await officer.getByRole('button',{name:'Settle & close',exact:true}).click();await officer.getByLabel('Reason',{exact:true}).fill('All receipts reviewed and reconciled');await officer.getByRole('button',{name:'Save',exact:true}).click();await expect(officer.locator('.finance-detail-title')).toContainText('Settled / closed');
   await sales.getByRole('dialog').getByRole('button',{name:'Close',exact:true}).click();await sales.getByRole('button',{name:/Notifications/}).click();await expect(sales.locator('.notification-history')).toContainText('Funds disbursed');await sales.getByRole('button',{name:'Mark all read',exact:true}).click();await sales.getByRole('dialog').getByRole('button',{name:'Close',exact:true}).click();await expect(sales.getByRole('button',{name:'Notifications (0)',exact:true})).toBeVisible();
   await page.goto('/finance/requests');const csvDownload=page.waitForEvent('download');await page.getByRole('button',{name:'CSV',exact:true}).click();const csv=await csvDownload;expect(readFileSync((await csv.path())!,'utf8')).toContain('Delivery support 中文核销');const pdfDownload=page.waitForEvent('download');await page.getByRole('button',{name:'PDF',exact:true}).click();const downloaded=await pdfDownload;const bytes=readFileSync((await downloaded.path())!);expect(bytes.subarray(0,5).toString()).toBe('%PDF-');expect(bytes.length).toBeGreaterThan(10000);
  }finally{await Promise.allSettled([salesContext.close(),adminContext.close(),officerContext.close()]);}
 });
 test('an unverified recipient is verified inside the disbursement dialog, then paid',async({page,browser})=>{
  test.setTimeout(150000);
  await login(page,'manager@test.invalid');
  await page.goto('/finance/accounts');
  await page.getByRole('button',{name:'Add payment account',exact:true}).click();
  await page.getByLabel('Name',{exact:true}).fill('Unverified recipient Bank');
  await page.getByLabel('Payment method',{exact:true}).selectOption('Bank');
  await page.getByRole('button',{name:'Save',exact:true}).click();
  await page.getByRole('button',{name:'Record opening funds',exact:true}).click();
  await page.getByLabel('Payment account',{exact:true}).selectOption({label:'Unverified recipient Bank'});
  await page.getByLabel('Amount (KES)',{exact:true}).fill('500.00');
  await page.getByLabel('Payment reference',{exact:true}).fill('OPEN-UNVERIFIED');
  await page.getByRole('checkbox').check();
  await page.getByRole('button',{name:'Save',exact:true}).click();
  await page.goto('/finance/budgets');
  await page.getByRole('button',{name:'Set monthly budget',exact:true}).click();
  await page.getByLabel('Expense category',{exact:true}).selectOption({label:'Travel'});
  await page.getByLabel('Amount (KES)',{exact:true}).fill('1000.00');
  await page.getByRole('button',{name:'Save',exact:true}).click();
  // No "Verify payment recipient" step: the disbursement dialog must offer it, otherwise the officer dead-ends.
  const requesterContext=await browser.newContext(),requester=await requesterContext.newPage();
  const adminContext=await browser.newContext(),admin=await adminContext.newPage();
  const officerContext=await browser.newContext(),officer=await officerContext.newPage();
  try{
   await signIn(requester,'removable@test.invalid');await requester.goto('/finance');await expect(requester.locator('main h1')).toHaveText('My financial requests');
   await requester.getByRole('button',{name:'Request funds',exact:true}).click();
   await requester.getByLabel('Amount (KES)',{exact:true}).fill('80.00');
   await requester.getByLabel('Expense category',{exact:true}).selectOption({label:'Travel'});
   await requester.getByLabel('Purpose',{exact:true}).fill('Advance without a verified payee');
   await requester.getByRole('dialog').locator('input[type=file]').setInputFiles(pdf);
   await requester.getByRole('button',{name:'Save',exact:true}).click();
   await login(admin,'admin@test.invalid');await admin.goto('/finance/requests');
   const approvedRow=admin.locator('.desktop-records tbody tr').filter({hasText:'Advance without a verified payee'});
   await approvedRow.getByRole('button',{name:'View details',exact:true}).click();
   await admin.getByRole('button',{name:'Review',exact:true}).click();
   await admin.getByRole('button',{name:'Save',exact:true}).click();
   await expect(admin.getByRole('dialog').locator('.finance-detail-title')).toContainText('Approved');
   await login(officer,'officer@test.invalid');await officer.goto('/finance/disbursements');
   const row=officer.locator('.desktop-records tbody tr').filter({hasText:'Advance without a verified payee'});
   await expect(row).toBeVisible();
   await row.getByRole('button',{name:'View details',exact:true}).click();
   await officer.getByRole('button',{name:'Record confirmed payment',exact:true}).click();
   const dialog=officer.getByRole('dialog');
   await expect(dialog.locator('.finance-payee')).toContainText('A Finance Officer must verify this recipient');
   await expect(dialog.locator('.finance-payee-verify')).toBeVisible();
   await expect(dialog.getByLabel('Name',{exact:true})).toHaveValue('Test Removable');
   await dialog.getByLabel('Verified payment destination',{exact:true}).fill('M-Pesa 0700000111');
   await officer.screenshot({path:'tests/.artifacts/disbursement-verify-recipient.png',fullPage:false});
   await officer.setViewportSize({width:390,height:844});
   const mobileBox=await dialog.boundingBox();
   expect(mobileBox!.width,'disbursement dialog width at 390px').toBeLessThanOrEqual(390);
   expect(await officer.evaluate(()=>document.documentElement.scrollWidth-window.innerWidth),'disbursement dialog overflows at 390px').toBeLessThanOrEqual(1);
   await officer.screenshot({path:'tests/.artifacts/disbursement-verify-mobile.png',fullPage:false});
   await officer.setViewportSize({width:1280,height:820});
   await dialog.getByRole('button',{name:'Save verified recipient',exact:true}).click();
   await expect(dialog.locator('.finance-payee-verify')).toHaveCount(0);
   await expect(dialog.locator('.finance-payee')).toContainText('M-Pesa 0700000111');
   await dialog.getByLabel('Amount (KES)',{exact:true}).fill('80.00');
   await dialog.getByLabel('Payment account',{exact:true}).selectOption({label:'Unverified recipient Bank'});
   await dialog.getByLabel('Payment reference',{exact:true}).fill('UNVERIFIED-PAY-1');
   await dialog.locator('input[type=file]').setInputFiles(pdf);
   await dialog.getByRole('checkbox').check();
   await dialog.getByRole('button',{name:'Save',exact:true}).click();
   await expect(officer.getByRole('dialog').locator('.finance-detail-title')).toContainText('Fully disbursed');
   await officer.screenshot({path:'tests/.artifacts/disbursement-recipient.png',fullPage:false});
   // Reconciliation is a derived worklist: the payment shows up without manual entry, and a bank line
   // identical to it reconciles on import instead of duplicating the movement.
   await officer.getByRole('dialog').getByRole('button',{name:'Close',exact:true}).click();
   await officer.goto('/finance/statements');
   await expect(officer.getByText('Every recorded payment and receipt appears here automatically.')).toBeVisible();
   const payRow=officer.locator('.desktop-records tbody tr').filter({hasText:'UNVERIFIED-PAY-1'});
   await expect(payRow).toHaveCount(1);
   await expect(payRow).toContainText('Unverified recipient Bank');
   await expect(payRow).toContainText('Awaiting reconciliation');
   await officer.setViewportSize({width:390,height:844});
   await officer.keyboard.press('Escape');
   expect((await officer.locator('#app-sidebar').boundingBox())!.x,'navigation drawer must stay closed on the reconciliation list').toBeLessThan(0);
   expect(await officer.evaluate(()=>document.documentElement.scrollWidth-window.innerWidth),'statements overflows at 390px').toBeLessThanOrEqual(1);
   const payCard=officer.locator('.finance-mobile-cards article').filter({hasText:'UNVERIFIED-PAY-1'});
   await expect(payCard).toHaveCount(1);
   await expect(payCard).toContainText('Awaiting reconciliation');
   await officer.setViewportSize({width:390,height:1300});
   await officer.screenshot({path:'tests/.artifacts/statements-autofill-mobile.png',fullPage:true});
   await officer.setViewportSize({width:390,height:844});
   await officer.setViewportSize({width:1600,height:1000});
   await officer.getByRole('button',{name:'Add statement line',exact:true}).click();
   const statement=officer.getByRole('dialog');
   await statement.getByLabel('Payment account',{exact:true}).selectOption({label:'Unverified recipient Bank'});
   await statement.getByLabel('Payment reference',{exact:true}).fill('UNVERIFIED-PAY-1');
   await statement.getByLabel('Amount (KES)',{exact:true}).fill('80.00');
   await statement.getByRole('button',{name:'Save',exact:true}).click();
   await expect(statement).toHaveCount(0);
   await expect(officer.locator('.desktop-records tbody tr').filter({hasText:'UNVERIFIED-PAY-1'})).toHaveCount(1);
   await expect(officer.locator('.desktop-records tbody tr').filter({hasText:'UNVERIFIED-PAY-1'})).toContainText('Reconciled');
   await officer.screenshot({path:'tests/.artifacts/statements-autofill.png',fullPage:false});
  }finally{await Promise.allSettled([requesterContext.close(),adminContext.close(),officerContext.close()]);}
 });
});
