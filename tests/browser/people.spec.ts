import {test,expect,type Page} from '@playwright/test';

async function signIn(page:Page,email:string){
 await page.goto('/');
 await page.getByLabel('Email address').fill(email);
 await page.getByLabel('Password',{exact:true}).fill('test-password-123');
 await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await expect(page.locator('main h1')).toBeVisible();
}
async function noOverflow(page:Page,label:string){
 const overflow=await page.evaluate(()=>document.documentElement.scrollWidth-window.innerWidth);
 expect(overflow,`${label} overflows horizontally`).toBeLessThanOrEqual(1);
}

test('people workspace shows staff identity, attendance, leave and commission without losing layout',async({page})=>{
 test.setTimeout(90000);
 await signIn(page,'admin@test.invalid');
 await page.goto('/people');
 await expect(page.locator('main h1')).toHaveText('People & Performance');
 await expect(page.getByRole('tab')).toHaveCount(4);
 await expect(page.getByRole('tab',{name:/Team/})).toHaveAttribute('aria-selected','true');
 await expect(page.locator('.people-card').first()).toBeVisible();
 await expect(page.locator('.people-card').first().locator('.people-code')).toContainText(/CK-\d{4}/);
 await page.getByLabel('Search by name, Staff ID, phone or territory').fill('Salesperson');
 await expect(page.locator('.people-card').filter({hasText:'Test Salesperson'})).toBeVisible();
 await noOverflow(page,'people team tab');

 await page.getByRole('tab',{name:/^Attendance/}).click();
 await expect(page.getByRole('tab',{name:/^Attendance/})).toHaveAttribute('aria-selected','true');
 await expect(page.getByRole('alert')).toHaveCount(0);
 const summary=page.locator('.people-summary').first();
 if(await summary.count()){await summary.click();
  const dialog=page.getByRole('dialog');
  await expect(dialog).toBeVisible();
  const width=await page.evaluate(()=>window.innerWidth);
  const box=await dialog.boundingBox();
  expect(box!.width,`attendance dialog fits at ${width}px`).toBeLessThanOrEqual(width);
  await dialog.locator('.dialog-actions').getByRole('button',{name:'Close',exact:true}).click();
  await expect(dialog).toHaveCount(0);
 }
 await noOverflow(page,'people attendance tab');

 await page.getByRole('tab',{name:/^Commissions/}).click();
 await expect(page.locator('.people-money-card')).toHaveCount(5);
 await expect(page.getByRole('alert')).toHaveCount(0);
 await noOverflow(page,'people commissions tab');
 await page.goto('/people?tab=leave');
 await expect(page.getByRole('tab',{name:/^Leave/})).toHaveAttribute('aria-selected','true');
 await expect(page.getByRole('alert')).toHaveCount(0);
 await page.screenshot({path:`tests/.artifacts/people-${test.info().project.name}.png`,fullPage:true});
});

test('a salesperson sees self-service attendance, leave and commission without an administration team tab',async({page})=>{
 test.setTimeout(90000);
 await signIn(page,'sales@test.invalid');
 await page.goto('/people');
 await expect(page.locator('main h1')).toHaveText('People & Performance');
 await expect(page.getByRole('tab')).toHaveCount(3);
 await expect(page.getByRole('tab',{name:/Team/})).toHaveCount(0);
 await page.getByRole('tab',{name:/^Leave/}).click();
 await page.getByRole('button',{name:'Request leave',exact:true}).first().click();
 const dialog=page.getByRole('dialog');
 await expect(dialog).toBeVisible();
 await expect(dialog.getByLabel('Leave type')).toBeVisible();
 await dialog.getByRole('button',{name:'Cancel',exact:true}).click();
 await expect(dialog).toHaveCount(0);
 await page.goto('/people?tab=team');
 await expect(page.getByRole('tab',{name:/Team/})).toHaveCount(0);
 await expect(page.getByRole('tab',{name:/^Attendance/})).toHaveAttribute('aria-selected','true');
 await noOverflow(page,'salesperson people page');
});

test('client lifecycle change is recorded with ownership history',async({page})=>{
 test.setTimeout(90000);
 await signIn(page,'admin@test.invalid');
 await page.goto('/clients');
 await expect(page.locator('main h1')).toHaveText('Clients');
 await page.goto('/clients?record=1');
 const dialog=page.getByRole('dialog');
 await expect(dialog).toBeVisible();
 await expect(dialog.locator('.client-lifecycle')).toBeVisible();
 await expect(dialog.getByRole('heading',{name:'Ownership history',exact:true})).toBeVisible();
 const select=dialog.getByLabel('Current lifecycle');
 const current=await select.inputValue();
 const target=current==='prospective'?'active':'prospective';
 await select.selectOption(target);
 await dialog.getByLabel('Lifecycle reason').fill('Qualification visit scheduled');
 await dialog.getByRole('button',{name:'Update lifecycle',exact:true}).click();
 await expect(dialog.locator('.client-lifecycle > header .badge')).toHaveText(target==='prospective'?'Prospective':'Active');
 await expect(dialog.locator('.client-lifecycle > p.field-note').first()).toContainText('Qualification visit scheduled');
 await dialog.locator('.dialog-actions').getByRole('button',{name:'Close',exact:true}).click();
 await expect(dialog).toHaveCount(0);
});
