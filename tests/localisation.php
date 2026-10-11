<?php
require __DIR__.'/../vendor/autoload.php';$app=require __DIR__.'/../bootstrap/app.php';$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$en=json_decode(file_get_contents(lang_path('en.json')),true);$zh=json_decode(file_get_contents(lang_path('zh_CN.json')),true);
if(array_keys($en)!==array_keys($zh))throw new RuntimeException('Locale keys do not match');
foreach(['en','zh_CN'] as $locale){
 app()->setLocale($locale);
 foreach(['required','email','unique','exists','in','regex','date','numeric','integer','uuid','string','array','boolean','date_format','after_or_equal','file','mimes','min.numeric','min.string','min.array','max.numeric','max.string','max.array','max.file','between.numeric'] as $rule){if(__('validation.'.$rule)==='validation.'.$rule)throw new RuntimeException('Missing validation '.$locale.' '.$rule);}
 $validator=Illuminate\Support\Facades\Validator::make(['email'=>'invalid'],['name'=>'required','email'=>'email']);
 if(!$validator->fails())throw new RuntimeException('Validation unexpectedly passed');
 if($locale==='zh_CN'&&!str_contains($validator->errors()->first('name'),'请填写姓名'))throw new RuntimeException('Chinese attributes failed');
 echo "PASS: $locale translation catalogue and validation rules\n";
}
$middleware=new App\Http\Middleware\Locale;
$r=Illuminate\Http\Request::create('/login','GET',[],['charm_locale'=>'zh_CN']);$middleware->handle($r,fn()=>response('ok'));if(app()->getLocale()!=='zh_CN')throw new RuntimeException('Cookie locale failed');
$r->headers->set('X-Locale','en');$middleware->handle($r,fn()=>response('ok'));if(app()->getLocale()!=='en')throw new RuntimeException('Header locale failed');
$r->headers->set('X-Locale','invalid');$middleware->handle($r,fn()=>response('ok'));if(app()->getLocale()!=='en')throw new RuntimeException('Unsupported locale accepted');
echo "PASS: locale preference middleware and allowed-language enforcement\n";
