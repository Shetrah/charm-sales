<?php
// Read-only check against the configured database. No credentials or sessions are saved.
require __DIR__.'/../vendor/autoload.php';
$app=require __DIR__.'/../bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
config(['session.driver'=>'array']);
$admin=App\Models\User::where('role','admin')->where('active',true)->firstOrFail();
Illuminate\Support\Facades\Auth::guard('web')->setUser($admin);
$kernel=$app->make(Illuminate\Contracts\Http\Kernel::class);
$response=$kernel->handle(Illuminate\Http\Request::create('http://127.0.0.1:8000/'));
if($response->getStatusCode()!==200 || !str_contains($response->getContent(),'Create salesperson account'))throw new RuntimeException('Admin dashboard failed: HTTP '.$response->getStatusCode());
echo "PASS: authenticated admin dashboard returns HTTP 200 and renders Team account creation\n";
$sales=new App\Models\User(['name'=>'Profile test','email'=>'profile@example.test','role'=>'salesperson']);
$sales->id=$admin->id;
$sales->active=true;
$request=Illuminate\Http\Request::create('/');
$request->setUserResolver(fn()=>$sales);
$html=(new App\Http\Controllers\PortalController)->dashboard($request)->render();
if(!str_contains($html,'My profile')||str_contains($html,'data-panel="Team"'))throw new RuntimeException('Salesperson dashboard visibility failed');
echo "PASS: salesperson dashboard renders profile link and hides admin account creation\n";
