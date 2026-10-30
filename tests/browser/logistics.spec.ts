import {test,expect} from '@playwright/test';
test('intake board, dispatch board and finished-goods ledger render on every screen size',async({page})=>{
 await page.goto('/logistics');
 await page.getByLabel('Email address').fill('admin@test.invalid');await page.getByLabel('Password',{exact:true}).fill('test-password-123');await page.getByRole('button',{name:'Sign in',exact:true}).click();
 await page.goto('/logistics');
 await expect(page.locator('main h1')).toHaveText('Order Logistics');
 await expect(page.getByRole('alert')).toHaveCount(0);
 await expect(page.getByRole('tab',{name:/Order intake/})).toHaveCount(1);
 await expect(page.getByRole('heading',{name:'Fulfilment queue',exact:true})).toBeVisible();
 await expect(page.locator('.intake-kpis .field-card')).toHaveCount(3);
 await page.getByRole('tab',{name:/Deliveries/}).click();
 await expect(page.getByRole('heading',{name:'Delivery board',exact:true})).toBeVisible();
 await expect(page.locator('.logistics-kpis .field-card')).toHaveCount(4);
 await page.getByRole('tab',{name:/Inventory ledger/}).click();
 await expect(page.getByRole('heading',{name:'Finished-goods ledger',exact:true})).toBeVisible();
 await expect(page.getByRole('alert')).toHaveCount(0);
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth)).toBe(true);
 await page.screenshot({path:`tests/.artifacts/logistics-${test.info().project.name}.png`,fullPage:true});
});
