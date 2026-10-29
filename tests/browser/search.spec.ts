import{test,expect,type Page}from '@playwright/test';

async function signIn(page:Page,email='admin@test.invalid'){
 await page.getByLabel('Email address').fill(email);
 await page.getByLabel('Password',{exact:true}).fill('test-password-123');
 await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await expect(page.locator('.sidebar-footer')).toBeVisible();
}

test('search centre groups results, deep links to the record and reports empty searches',async({page})=>{
 await page.goto('/');
 await signIn(page);
 await page.getByRole('button',{name:'Search records',exact:true}).click();
 const dialog=page.getByRole('dialog');
 await expect(dialog).toBeVisible();
 await expect(dialog).toContainText('Type at least two characters. Results are limited to records you can access.');
 const box=await dialog.boundingBox();
 expect(box!.x).toBeGreaterThanOrEqual(0);
 expect(box!.x+box!.width).toBeLessThanOrEqual(page.viewportSize()!.width);
 const input=dialog.getByLabel('Search clients, orders, deliveries or products',{exact:true});
 await input.fill('Integration');
 const hit=dialog.locator('.search-hit').filter({hasText:'Integration Client'}).first();
 await expect(hit).toBeVisible();
 await expect(dialog.locator('.search-group h3').filter({hasText:'Clients'})).toBeVisible();
 await hit.click();
 await expect(page.getByRole('dialog')).toHaveCount(0);
 await expect(page).toHaveURL(/\/clients\?record=\d+/);
 await expect(page.getByRole('dialog')).toContainText('Integration Client');
 await page.getByRole('dialog').getByRole('button',{name:'Close',exact:true}).last().click();
 await page.getByRole('button',{name:'Search records',exact:true}).click();
 const empty=page.getByRole('dialog');
 await empty.getByLabel('Search clients, orders, deliveries or products',{exact:true}).fill('zz-no-such-record-zz');
 await expect(empty).toContainText('No matching records.');
 await expect(empty).toContainText('Try a client name, order or delivery number, product SKU or barcode.');
 await empty.getByRole('button',{name:'Close',exact:true}).last().click();
 await expect(page.getByRole('dialog')).toHaveCount(0);
 expect(await page.evaluate(()=>document.documentElement.scrollWidth-window.innerWidth)).toBeLessThanOrEqual(1);
});

test('search centre respects ownership for a salesperson',async({page})=>{
 await page.goto('/');
 await signIn(page,'sales@test.invalid');
 await page.getByRole('button',{name:'Search records',exact:true}).click();
 const dialog=page.getByRole('dialog');
 await dialog.getByLabel('Search clients, orders, deliveries or products',{exact:true}).fill('Integration');
 await expect(dialog.locator('.search-hit').filter({hasText:'Integration Client'}).first()).toBeVisible();
 await dialog.getByLabel('Search clients, orders, deliveries or products',{exact:true}).fill('Maina');
 await expect(dialog).toContainText('No matching records.');
});
