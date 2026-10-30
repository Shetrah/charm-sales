import {test,expect,type Page} from '@playwright/test';
const DESK_PASSWORD='desk-test-password-123';
const ORDER_TOTAL='1014.80';
const portrait={name:'desk-portrait',mimeType:'image/jpeg',buffer:Buffer.from('test-only-jpeg')};

async function signIn(page:Page,email:string,password='test-password-123'){
 await page.getByLabel('Email address').fill(email);await page.getByLabel('Password',{exact:true}).fill(password);await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await expect(page.locator('.sidebar-footer')).toBeVisible();
}
async function signOut(page:Page){await page.locator('.sidebar-footer').getByRole('button',{name:'Sign out',exact:true}).click();await expect(page.getByLabel('Email address')).toBeVisible();}
async function closeDialog(page:Page){await page.keyboard.press('Escape');await expect(page.locator('dialog')).toHaveCount(0);}
async function submitContract(page:Page,reference:string,file:string){
 await page.getByLabel('Contract reference',{exact:true}).fill(reference);
 await page.getByLabel('Signed by (client representative)',{exact:true}).fill('Client Signatory');
 await page.getByLabel('Contract terms and conditions',{exact:true}).fill('Payment, delivery and return terms accepted by the client for this order.');
 await page.getByRole('button',{name:'Save as draft',exact:true}).click();
 await expect(page.getByText(/Draft and contract details saved/)).toBeVisible();
 await page.getByLabel('Add signed contract page',{exact:true}).setInputFiles({name:file,mimeType:'application/pdf',buffer:Buffer.from('%PDF-1.4 contract')});
 await page.getByRole('button',{name:'Review contract before submitting',exact:true}).click();
 await page.getByLabel('I confirm the contract details and attached pages are complete and accurate.').check();
 await page.getByRole('button',{name:'Confirm and submit contract',exact:true}).click();
 await expect(page.getByRole('status').filter({hasText:'Contract submitted. Submit the order as a separate step'})).toBeVisible();
}

test('Admin adds the fulfilment desk and an identity photo reaches the directory',async({page})=>{
 test.skip(test.info().project.name!=='desktop','Account mutation runs once; the desk screens below repeat in every viewport.');
 await page.goto('/staff');await signIn(page,'admin@test.invalid');await page.goto('/staff');
 await page.getByRole('button',{name:'Add staff',exact:true}).click();
 const dialog=page.getByRole('dialog');
 await dialog.getByLabel('Name',{exact:true}).fill('Desk Operator');
 await dialog.getByLabel('Email address').fill('desk@test.invalid');
 await dialog.getByLabel('Temporary password',{exact:true}).fill(DESK_PASSWORD);
 await dialog.getByLabel('Role',{exact:true}).selectOption('logistics_manager');
 await dialog.getByRole('button',{name:'Save',exact:true}).click();
 await expect(page.locator('dialog')).toHaveCount(0);
 const deskCard=page.locator('.person-card').filter({hasText:'Desk Operator'});
 await expect(deskCard).toHaveCount(1);
 await expect(deskCard.getByText('Logistics manager')).toBeVisible();
 await expect(deskCard.locator('.person-avatar img')).toHaveCount(0);

 await page.locator('.person-card').filter({hasText:'Test Admin'}).getByRole('button',{name:'View details',exact:true}).click();
 const self=page.getByRole('dialog');
 await expect(self.locator('.media-upload .media-button')).toBeVisible();
 await self.locator('.media-upload input[type=file]').setInputFiles(portrait);
 await expect(self.locator('.profile-identity .staff-photo')).toBeVisible();
 await expect(page.getByRole('alert')).toHaveCount(0);
 await closeDialog(page);
 await expect(page.locator('.person-card').filter({hasText:'Test Admin'}).locator('.staff-photo')).toBeVisible();
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth)).toBe(true);
});

test('the desk reaches its own portal and is kept out of sales, finance and staff screens',async({page})=>{
 await page.goto('/');await signIn(page,'desk@test.invalid',DESK_PASSWORD);
 await expect(page).toHaveURL(/\/logistics$/);
 await expect(page.locator('.header-caption')).toContainText('Fulfilment desk');
 await expect(page.locator('.sidebar nav').getByText('FULFILMENT DESK')).toHaveCount(1);
 await expect(page.locator('.sidebar nav').getByText('Audit trail',{exact:true})).toHaveCount(0);
 expect(await page.locator('.sidebar nav a').count()).toBeGreaterThanOrEqual(4);
 await page.goto('/production');await expect(page).toHaveURL(/\/logistics$/);
 await page.goto('/staff');await expect(page).toHaveURL(/\/logistics$/);
 await page.goto('/audit');await expect(page).toHaveURL(/\/logistics$/);
 await page.goto('/visits');await expect(page).toHaveURL(/\/logistics$/);
 await page.goto('/finance');await expect(page).toHaveURL(/\/logistics$/);
 await page.goto('/orders');await expect(page.locator('main h1')).toHaveText('Orders');
 await expect(page.getByRole('alert')).toHaveCount(0);
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth)).toBe(true);
});

test('the catalogue opens as image cards the desk can dress',async({page})=>{
 await page.goto('/products');await signIn(page,'desk@test.invalid',DESK_PASSWORD);await page.goto('/products');
 await expect(page.locator('main h1')).toHaveText('Catalogue');
 await expect(page.locator('.record-cards.catalogue-cards')).toBeVisible();
 await expect(page.locator('.desktop-records')).toHaveCount(0);
 const card=page.locator('.record-card.record-products').first();
 await expect(card.locator('.record-card-media')).toBeVisible();
 await card.getByRole('button',{name:'View details',exact:true}).click();
 const detail=page.getByRole('dialog');
 await expect(detail.locator('.product-media')).toBeVisible();
 await detail.locator('.media-upload input[type=file]').setInputFiles(portrait);
 await expect(detail.locator('.product-media-preview .product-photo')).toBeVisible();
 await expect(page.getByRole('alert')).toHaveCount(0);
 await closeDialog(page);
 await expect(page.locator('.record-card .product-photo').first()).toBeVisible();
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth)).toBe(true);
});

test('the desk checks stock, arranges production and then plans the delivery',async({page})=>{
 test.skip(test.info().project.name!=='desktop','One production-and-dispatch journey per build; the queue is shared state.');
 test.setTimeout(180000);
 await page.goto('/orders');await signIn(page,'sales@test.invalid');await page.goto('/orders');
 await page.getByRole('button',{name:'Create record',exact:true}).click();
 await page.getByRole('combobox',{name:'Find a client'}).selectOption({label:'Integration Client'});
 await page.getByRole('combobox',{name:'Find a product variant'}).selectOption({index:1});
 await page.getByLabel('Quantity',{exact:true}).fill('40');
 await page.getByLabel('Price per selected unit (KES)',{exact:true}).fill('25.37');
 await expect(page.locator('.order-total')).toHaveText(`Total (KES): ${ORDER_TOTAL}`);
 await submitContract(page,'CT-DESK-1','desk-contract.pdf');
 await page.getByRole('button',{name:'Submit order for approval',exact:true}).click();
 await expect(page.locator('dialog')).toHaveCount(0);

 await signOut(page);await page.goto('/orders');await signIn(page,'admin@test.invalid');await page.goto('/orders');
 const pending=page.locator('.desktop-records').getByRole('row').filter({has:page.getByRole('cell',{name:ORDER_TOTAL,exact:true})}).first();
 await expect(pending).toBeVisible();
 const orderNumber=await pending.locator('td').first().innerText();
 await pending.getByRole('button',{name:'Confirm order',exact:true}).click();
 await page.getByLabel('I have reviewed the submitted contract and supporting documents.').check();
 await page.getByRole('dialog').getByRole('button',{name:'Confirm order',exact:true}).click();
 await expect(page.locator('dialog')).toHaveCount(0);

 await signOut(page);await page.goto('/');await signIn(page,'desk@test.invalid',DESK_PASSWORD);await page.goto('/logistics');
 const queueFilter={hasText:new RegExp(`#${orderNumber}(?!\\d)`)};
 const card=page.locator('.intake-card').filter(queueFilter).filter({hasText:'Integration Client'}).first();
 await expect(card).toBeVisible();
 await expect(card.locator('.intake-gaps li').first()).toBeVisible();
 await expect(card.getByText('Stock shortage')).toBeVisible();
 await card.getByRole('button',{name:'Arrange production',exact:true}).click();
 const arrange=page.getByRole('dialog');
 await expect(arrange.locator('.intake-gaps li')).not.toHaveCount(0);
 await arrange.getByLabel('Ready by',{exact:true}).fill(await page.evaluate(()=>new Intl.DateTimeFormat('en-CA',{timeZone:'Africa/Nairobi'}).format(new Date(Date.now()+4*86400000))));
 await arrange.getByRole('button',{name:'Arrange production',exact:true}).click();
 await expect(page.getByRole('status').filter({hasText:'Production arranged'})).toBeVisible();
 await expect(page.locator('dialog')).toHaveCount(0);
 await expect(card.getByText('Under production')).toBeVisible();
 await expect(card.getByRole('button',{name:'Plan delivery',exact:true})).toBeVisible();

 await card.getByRole('button',{name:'Plan delivery',exact:true}).click();
 const plan=page.getByRole('dialog');
 await plan.getByLabel('Driver',{exact:true}).fill('Desk Driver');
 await plan.getByLabel('Vehicle',{exact:true}).fill('KDD 500X');
 await plan.getByRole('button',{name:'Save',exact:true}).click();
 await expect(page.getByRole('status').filter({hasText:'Delivery planned'})).toBeVisible();
 await expect(page.locator('.intake-card').filter(queueFilter)).toHaveCount(0);
 await page.getByRole('tab',{name:/Deliveries/}).click();
 await expect(page.locator('.logistics-card').filter({hasText:'Desk Driver'}).first()).toBeVisible();

 await signOut(page);await page.goto('/orders');await signIn(page,'admin@test.invalid');await page.goto('/orders');
 const orderRow=page.locator('.desktop-records').getByRole('row').filter({has:page.getByRole('cell',{name:ORDER_TOTAL,exact:true})}).first();
 await expect(orderRow.getByText('Confirmed')).toBeVisible();
 await expect(orderRow.getByText('Under production')).toHaveCount(0);
 await expect(page.getByRole('alert')).toHaveCount(0);
});
