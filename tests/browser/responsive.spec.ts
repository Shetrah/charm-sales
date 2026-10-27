import {test,expect} from '@playwright/test';
const widths=[320,360,375,390,414,430,768,1024,1280];
const routes:[string,boolean][]=[['dashboard',true],['clients',true],['orders',true],['payments',true],['visits',true],['field',true],['field?tab=requests',true],['reporting',true],['production',false],['staff',true],['audit',true],['finance',true],['finance/requests',true],['finance/accounts',true]];
test.describe('responsive sweep',()=>{
 test.skip(({isMobile})=>isMobile,'One viewport sweep covers the required widths; tablet and mobile projects cover their own layouts.');
 test('every supported width keeps routes, drawer and dialogs usable',async({page})=>{
  test.setTimeout(240000);
  await page.setViewportSize({width:1280,height:900});
  await page.goto('/');
  await page.getByLabel('Email address').fill('admin@test.invalid');await page.getByLabel('Password',{exact:true}).fill('test-password-123');await page.getByRole('button',{name:'Sign in',exact:true}).click();
  await expect(page.locator('.sidebar-footer')).toBeVisible();
  for(const width of widths){
   await page.setViewportSize({width,height:820});
   for(const [route,failsClosed] of routes){
    await page.goto('/'+route);
    await expect(page.locator('main h1')).toBeVisible();
    if(failsClosed)await expect(page.getByRole('alert'),`${route} shows an error at ${width}px`).toHaveCount(0);
    const overflow=await page.evaluate(()=>document.documentElement.scrollWidth-window.innerWidth);
    expect(overflow,`${route} overflows horizontally at ${width}px`).toBeLessThanOrEqual(1);
   }
   if(width<=760){
    const menu=page.getByRole('button',{name:'Open menu',exact:true});
    await expect(menu).toBeVisible();
    await menu.click();
    await expect(page.locator('#app-sidebar')).toHaveClass(/open/);
    await page.keyboard.press('Escape');
    await expect(page.locator('#app-sidebar')).not.toHaveClass(/open/);
    await expect(menu).toBeFocused();
    const paddingBottom=await page.locator('main.content').evaluate(el=>parseFloat(getComputedStyle(el).paddingBottom));
    expect(paddingBottom,`bottom navigation space at ${width}px`).toBeGreaterThanOrEqual(80);
   }else{
    await expect(page.locator('.sidebar')).toBeVisible();
    await expect(page.getByRole('button',{name:'Open menu',exact:true})).toBeHidden();
   }
  }
  for(const width of [320,360,430]){
   await page.setViewportSize({width,height:820});
   await page.goto('/clients');
   await page.getByRole('button',{name:'Create record',exact:true}).click();
   const dialog=page.getByRole('dialog');
   await expect(dialog).toBeVisible();
   const box=await dialog.boundingBox();
   expect(box!.width,`dialog fit at ${width}px`).toBeLessThanOrEqual(width);
   expect(box!.height,`dialog height at ${width}px`).toBeLessThanOrEqual(821);
   const fontSize=await dialog.locator('.dialog-body input').first().evaluate(el=>parseFloat(getComputedStyle(el).fontSize));
   expect(fontSize,`input font size at ${width}px`).toBeGreaterThanOrEqual(16);
   const actions=await dialog.locator('.dialog-actions').boundingBox();
   expect(actions!.y+actions!.height,`actions visible at ${width}px`).toBeLessThanOrEqual(823);
   await dialog.getByRole('button',{name:'Cancel',exact:true}).click();
   await page.screenshot({path:`tests/.artifacts/responsive-${width}.png`,fullPage:true});
  }
 });
});
