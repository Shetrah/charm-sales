import {test,expect,type Page} from '@playwright/test';
async function login(page:Page,email:string,password='test-password-123'){
 await page.goto('/');await page.getByLabel('Email address').fill(email);await page.getByLabel('Password',{exact:true}).fill(password);await page.getByRole('button',{name:'Sign in',exact:true}).click();await expect(page.locator('.sidebar-footer')).toBeVisible();
}
async function logout(page:Page){
 if(await page.locator('.mobile-menu').isVisible()&&!await page.locator('.sidebar').evaluate(el=>el.classList.contains('open')))await page.locator('.mobile-menu').click();
 await page.locator('.sidebar-footer').getByRole('button').click();
}
test('each role reaches its portal and only Admin can choose every portal',async({page})=>{
 await login(page,'admin@test.invalid');await expect(page).toHaveURL(/\/admin$/);await expect(page.locator('.portal-grid a')).toHaveCount(3);
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
 await page.screenshot({path:`tests/.artifacts/company-hub-${test.info().project.name}.png`,fullPage:true});
 await page.getByRole('link',{name:'Finance portal',exact:true}).click();await expect(page.locator('main h1')).toHaveText('Finance dashboard');
 await page.goto('/admin');await expect(page.locator('main h1')).toHaveText('Admin portal');
 await logout(page);await login(page,'officer@test.invalid');await expect(page).toHaveURL(/\/finance$/);
 await page.goto('/staff');await expect(page).toHaveURL(/\/finance$/);await page.goto('/sales');await expect(page).toHaveURL(/\/finance$/);
 await logout(page);await login(page,'sales@test.invalid');await expect(page).toHaveURL(/\/sales$/);
 await page.goto('/admin');await expect(page).toHaveURL(/\/sales$/);await page.goto('/finance');await expect(page).toHaveURL(/\/my-requests$/);
 await expect(page.locator('main h1')).toHaveText('My financial requests');await expect(page.getByRole('button',{name:'Add payment account',exact:true})).toHaveCount(0);
});
test('Admin adds staff with a temporary password and staff can change it',async({page,browser})=>{
 test.skip(test.info().project.name!=='desktop','Account mutation runs once; role routing covers all sizes.');
 await login(page,'admin@test.invalid');await page.goto('/staff');await page.getByRole('button',{name:'Add staff',exact:true}).click();
 const dialog=page.getByRole('dialog');await dialog.getByLabel('Name',{exact:true}).fill('New Finance Staff');await dialog.getByLabel('Email address').fill('new-finance@test.invalid');
 await dialog.getByLabel('Temporary password',{exact:true}).fill('temporary-test-password');await dialog.getByLabel('Role',{exact:true}).selectOption('finance_officer');
 await expect(dialog.getByLabel('Role').locator('option')).toHaveCount(3);await dialog.getByRole('button',{name:'Save',exact:true}).click();await expect(dialog).toHaveCount(0);
 const context=await browser.newContext(),staff=await context.newPage();
 try{
  await login(staff,'new-finance@test.invalid','temporary-test-password');await expect(staff).toHaveURL(/\/finance$/);
  await staff.locator('.sidebar-footer').getByRole('link',{name:'Update password'}).click();await expect(staff.locator('main h1')).toHaveText('Update password');
  await staff.locator('input[type=password]').fill('updated-test-password');await staff.getByRole('button',{name:'Update password',exact:true}).click();await expect(staff).toHaveURL(/\/finance$/);
  await staff.locator('.sidebar-footer').getByRole('button').click();await login(staff,'new-finance@test.invalid','updated-test-password');await expect(staff).toHaveURL(/\/finance$/);
 }finally{await context.close();}
});
