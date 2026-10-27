import {test,expect,type Page} from '@playwright/test';

async function signIn(page:Page,email:string){
 await page.goto('/');
 await page.getByLabel('Email address').fill(email);
 await page.getByLabel('Password',{exact:true}).fill('test-password-123');
 await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await expect(page.locator('main h1')).toBeVisible();
}
async function signOut(page:Page){
 await page.evaluate(()=>localStorage.clear());
 await page.goto('/');
 await expect(page.getByLabel('Email address')).toBeVisible();
}
async function noOverflow(page:Page,label:string){
 const overflow=await page.evaluate(()=>document.documentElement.scrollWidth-window.innerWidth);
 expect(overflow,`${label} overflows horizontally`).toBeLessThanOrEqual(1);
}

test('field travel sections, tabs and dialogs stay usable without horizontal overflow',async({page})=>{
 await signIn(page,'admin@test.invalid');
 await page.goto('/field');
 await expect(page.locator('main h1')).toHaveText('Field Travel & Planning');
 await expect(page.getByRole('tab')).toHaveCount(5);
 for(const name of ['Overview','Itineraries','Travel requests','Approvals','History']){
  await page.getByRole('tab',{name,exact:true}).click();
  await expect(page.getByRole('tab',{name,exact:true})).toHaveAttribute('aria-selected','true');
  await expect(page.getByRole('alert')).toHaveCount(0);
  await noOverflow(page,`field ${name} tab`);
 }
 await page.getByRole('tab',{name:'Itineraries',exact:true}).click();
 await page.getByRole('button',{name:'New itinerary',exact:true}).first().click();
 const dialog=page.getByRole('dialog');
 await expect(dialog).toBeVisible();
 const width=await page.evaluate(()=>window.innerWidth);
 const box=await dialog.boundingBox();
 expect(box!.width,`itinerary dialog fits at ${width}px`).toBeLessThanOrEqual(width);
 expect(await dialog.evaluate(el=>el.scrollWidth<=el.clientWidth)).toBe(true);
 await dialog.getByRole('button',{name:'Cancel',exact:true}).click();
 await expect(dialog).toHaveCount(0);
 await page.screenshot({path:`tests/.artifacts/field-travel-${test.info().project.name}.png`,fullPage:true});
});

test.describe('field travel approval workflow',()=>{
 test.skip(({isMobile})=>isMobile,'Desktop workflow; tab, dialog and viewport behaviour is covered by the responsive tests.');

 test('an itinerary is submitted without creating a travel request until one is linked and approved',async({page})=>{
  test.setTimeout(90000);
  await signIn(page,'sales@test.invalid');
  await page.goto('/field?tab=itineraries');
  await expect(page.locator('main h1')).toBeVisible();
  await page.getByRole('button',{name:'New itinerary',exact:true}).first().click();
  const editor=page.getByRole('dialog');
  await editor.getByLabel('Itinerary title',{exact:true}).fill('Nairobi supplier route');
  await editor.getByLabel('Start location',{exact:true}).fill('Nairobi CBD');
  await editor.getByLabel('Transport mode',{exact:true}).selectOption('car');
  await editor.getByLabel('Expected duration (minutes)',{exact:true}).first().fill('90');
  await editor.getByRole('button',{name:'Add destination',exact:true}).click();
  await editor.getByLabel('Customer destination 1',{exact:true}).selectOption({label:'Integration Client'});
  await editor.getByLabel('Visit objective',{exact:true}).fill('Supplier stock review');
  await editor.getByRole('button',{name:'Submit itinerary',exact:true}).click();
  await expect(page.getByRole('status').filter({hasText:'Itinerary submitted to the plan.'})).toBeVisible();
  await expect(editor).toHaveCount(0);

  const planCard=page.locator('.field-record').filter({hasText:'Nairobi supplier route'});
  await expect(planCard).toContainText(/Planned visits\s*1/);
  await expect(planCard).toContainText(/Completed visits\s*0/);
  await expect(planCard).toContainText(/Linked travel request\s*—/);

  await page.getByRole('tab',{name:'Travel requests',exact:true}).click();
  await expect(page.locator('.field-record').filter({hasText:'Nairobi supplier route'})).toHaveCount(0);
  await expect(page.getByRole('heading',{name:'No travel requests yet',exact:true})).toBeVisible();

  await page.getByRole('button',{name:'New travel request',exact:true}).first().click();
  const requestEditor=page.getByRole('dialog');
  await requestEditor.getByLabel('Purpose',{exact:true}).fill('Supplier meeting in Nakuru');
  await requestEditor.getByLabel('Origin',{exact:true}).fill('Nairobi');
  await requestEditor.getByLabel('Destination',{exact:true}).fill('Nakuru');
  await requestEditor.getByLabel('Item description 1',{exact:true}).fill('Return fare');
  await requestEditor.getByLabel('Amount (KES) 1',{exact:true}).fill('150');
  await requestEditor.getByRole('checkbox',{name:/Nairobi supplier route/}).check();
  await requestEditor.getByRole('button',{name:'Submit for approval',exact:true}).click();
  await expect(page.getByRole('status').filter({hasText:'Travel request submitted for approval.'})).toBeVisible();
  await expect(requestEditor).toHaveCount(0);

  const requestCard=page.locator('.field-record').filter({hasText:'Supplier meeting in Nakuru'});
  await expect(requestCard).toContainText('Pending approval');
  await expect(requestCard).toContainText(/Linked itineraries\s*1/);

  await signOut(page);
  await signIn(page,'admin@test.invalid');
  await page.goto('/field?tab=approvals');
  const pending=page.locator('.field-row.static').filter({hasText:'Supplier meeting in Nakuru'});
  await expect(pending).toBeVisible();
  await pending.getByRole('button',{name:'Approve',exact:true}).click();
  const decision=page.getByRole('dialog');
  await expect(decision).toContainText('Supplier meeting in Nakuru');
  await decision.getByRole('button',{name:'Approve',exact:true}).click();
  await expect(page.getByRole('status').filter({hasText:'Decision recorded.'})).toBeVisible();
  await expect(pending).toHaveCount(0);

  await page.getByRole('tab',{name:'Itineraries',exact:true}).click();
  const linked=page.locator('.field-record').filter({hasText:'Nairobi supplier route'});
  await expect(linked).toContainText(/Linked travel request\s*#\d+ · Approved/);
  await expect(linked).toContainText(/Planned visits\s*1/);
  await expect(linked).toContainText(/Completed visits\s*0/);

  await page.getByRole('tab',{name:'Overview',exact:true}).click();
  await expect(page.locator('.field-card').filter({hasText:'Completed visits'})).toContainText('0/1');
 });
});
