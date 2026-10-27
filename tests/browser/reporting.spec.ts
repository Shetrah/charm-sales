import {test,expect,type Page} from '@playwright/test';
async function login(page:Page,email:string){
 await page.goto('/');await page.getByLabel('Email address').fill(email);await page.getByLabel('Password',{exact:true}).fill('test-password-123');await page.getByRole('button',{name:'Sign in',exact:true}).click();await expect(page.locator('.sidebar-footer')).toBeVisible();
}
test('admin generates a factual snapshot with transparent narrative status and exports',async({page})=>{
 await login(page,'admin@test.invalid');await page.goto('/reporting');
 await expect(page.getByRole('heading',{name:'Management reports',exact:true,level:1})).toBeVisible();
 // Each viewport uses its own historical date so parallel projects do not share a cached snapshot.
 await page.getByLabel('Report date').fill(test.info().project.name==='desktop'?'2026-01-05':test.info().project.name==='tablet'?'2026-01-06':'2026-01-07');
 const generate=page.getByRole('button',{name:'Generate report',exact:true}).first();
 if(await generate.count())await generate.click();else await page.getByRole('button',{name:'Regenerate report',exact:true}).click();
 await expect(page.getByText('Automatic summary',{exact:true}).first()).toBeVisible({timeout:25000});
 await expect(page.getByRole('heading',{name:'Executive summary',exact:true})).toBeVisible();
 await expect(page.getByText('Recorded facts',{exact:true}).first()).toBeVisible();
 await expect(page.getByText('AI interpretation',{exact:true})).toHaveCount(0);
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth)).toBe(true);
 await page.getByRole('button',{name:'Regenerate report',exact:true}).click();
 await expect(page.getByText('The source data has not changed; the existing snapshot was reused.',{exact:true})).toBeVisible();
 const csv=page.waitForEvent('download');await page.getByRole('button',{name:'Download CSV',exact:true}).click();
 expect((await csv).suggestedFilename()).toMatch(/^charm-management-report-daily-/);
 const xlsx=page.waitForEvent('download');await page.getByRole('button',{name:'Download Excel',exact:true}).click();
 expect((await xlsx).suggestedFilename()).toMatch(/^charm-management-report-daily-.*\.xlsx$/);
 const pdf=page.waitForEvent('download');await page.getByRole('button',{name:'Download PDF',exact:true}).click();
 expect((await pdf).suggestedFilename()).toMatch(/^charm-management-report-daily-.*\.pdf$/);
 await page.screenshot({path:`tests/.artifacts/reporting-${test.info().project.name}.png`,fullPage:true});
});
test('reporting is restricted to administrators',async({page})=>{
 await login(page,'sales@test.invalid');await page.goto('/reporting');
 await expect(page).toHaveURL(/\/sales$/);
 await expect(page.getByRole('heading',{name:'Overview',exact:true})).toBeVisible();
});
