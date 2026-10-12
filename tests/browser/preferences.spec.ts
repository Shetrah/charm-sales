import { test, expect } from '@playwright/test';
test('direct routes, English/Chinese and both themes persist without horizontal overflow',async({page})=>{
 await page.goto('/orders');
 await expect(page.getByRole('heading',{name:'Sales portal',exact:true})).toBeVisible();
 await page.getByRole('button',{name:'English / 简体中文'}).click();
 await expect(page.getByRole('heading',{name:'销售门户',exact:true})).toBeVisible();
 await expect(page.getByRole('button',{name:'登录',exact:true})).toBeVisible();
 await page.getByRole('button',{name:'登录',exact:true}).click();
 await expect(page.getByRole('alert')).toHaveText('请检查填写内容并重试。');
 await page.getByRole('button',{name:'深色模式'}).click();
 await expect(page.locator('html')).toHaveAttribute('data-theme','dark');
 await page.reload();
 await expect(page.locator('html')).toHaveAttribute('lang','zh-CN');
 await expect(page.locator('html')).toHaveAttribute('data-theme','dark');
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth)).toBe(true);
 await page.getByRole('button',{name:'浅色模式'}).click();
 await expect(page.locator('html')).toHaveAttribute('data-theme','light');
 await page.screenshot({path:`tests/.artifacts/login-${test.info().project.name}.png`,fullPage:true});
 await page.getByRole('button',{name:'English / 简体中文'}).click();
 await expect(page.getByRole('heading',{name:'Sales portal',exact:true})).toBeVisible();
});
test('supports reduced motion and includes the original company favicon',async({page})=>{
 await page.emulateMedia({reducedMotion:'reduce'});await page.goto('/plans');
 await expect(page.locator('link[rel="icon"]')).toHaveAttribute('href','/assets/charm-logo.png');
 expect(await page.evaluate(()=>window.matchMedia('(prefers-reduced-motion: reduce)').matches)).toBe(true);
 await expect(page.locator('input[type="email"]')).toBeVisible();
});
