<?php
require __DIR__.'/../vendor/autoload.php';$app=require __DIR__.'/../bootstrap/app.php';$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
view()->share('errors',new Illuminate\Support\ViewErrorBag);
$user=new App\Models\User(['name'=>'Workspace QA','email'=>'qa@example.test','role'=>'admin']);$user->id=900;$user->active=true;
Illuminate\Support\Facades\Auth::guard('web')->setUser($user);
$dir=__DIR__.'/.artifacts';if(!is_dir($dir))mkdir($dir);
$products=collect(json_decode(file_get_contents(__DIR__.'/../products.json')))->map(function($p){$p->unit_price='12.35';$p->active=true;$p->needs_review=false;return $p;});
$data=['month'=>'2026-10','monthly_sales'=>'4930.50','monthly_orders'=>12,'outstanding'=>'3200.00','verified_paid'=>'1730.50','pending_orders'=>3,'pending_payments'=>2,'pending_reviews'=>1,'pending_approvals'=>6,'client_count'=>18,'chart'=>[(object)['id'=>1,'name'=>'Salesperson A','total'=>'4930.50']]];
file_put_contents($dir.'/portal.html',view('portal',compact('user','data','products'))->render());
file_put_contents($dir.'/login.html',view('login')->render());file_put_contents($dir.'/profile.html',view('profile',compact('user'))->render());
echo "Rendered isolated UI fixtures.\n";
