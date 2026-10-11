<?php
require __DIR__.'/../vendor/autoload.php';
$app=require __DIR__.'/../bootstrap/app.php';$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$user=App\Models\User::where('role','admin')->where('active',true)->firstOrFail();
$r=Illuminate\Http\Request::create('/');$r->setUserResolver(fn()=>$user);
view()->share('errors',new Illuminate\Support\ViewErrorBag);
for($i=0;$i<3;$i++){
 Illuminate\Support\Facades\DB::flushQueryLog();Illuminate\Support\Facades\DB::enableQueryLog();
 $start=microtime(true);$view=(new App\Http\Controllers\PortalController)->dashboard($r);$html=$view->render();
 $queries=Illuminate\Support\Facades\DB::getQueryLog();
 echo json_encode(['run'=>$i+1,'milliseconds'=>round((microtime(true)-$start)*1000),'queries'=>count($queries),'query_ms'=>round(array_sum(array_column($queries,'time'))),'html_bytes'=>strlen($html)]).PHP_EOL;
}
