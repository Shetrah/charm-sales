<?php
// Run with: php tests/account-smoke.php (isolated in-memory database).
require __DIR__.'/../vendor/autoload.php';
$app = require __DIR__.'/../bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
config(['database.default'=>'sqlite','database.connections.sqlite'=>['driver'=>'sqlite','database'=>':memory:','prefix'=>''],'session.driver'=>'array']);
$schema = Illuminate\Support\Facades\Schema::connection('sqlite');
$schema->create('users',function($t){$t->id();$t->string('name');$t->string('email')->unique();$t->string('password');$t->string('role');$t->boolean('active')->default(true);$t->rememberToken();$t->timestamps();});
$schema->create('audit_logs',function($t){$t->id();$t->integer('actor_id');$t->string('action');$t->string('entity');$t->integer('entity_id');$t->text('details');$t->timestamp('created_at');});
$schema->create('clients',function($t){$t->id();$t->integer('salesperson_id');});
function check($condition,$message){if(!$condition)throw new RuntimeException($message);echo "PASS: $message\n";}
function requestFor($user,$values=[]){$r=Illuminate\Http\Request::create('/users','POST',$values);$r->headers->set('Accept','application/json');$r->setUserResolver(fn()=>$user);return $r;}
$admin=App\Models\User::create(['name'=>'Admin','email'=>'admin@example.test','password'=>'test-password-123','role'=>'admin']);
$controller=new App\Http\Controllers\PortalController;
$response=$controller->addUser(requestFor($admin,['name'=>'Sales A','email'=>'a@example.test','password'=>'sales-password-123','role'=>'salesperson']));
$sales=App\Models\User::find($response->getData()->id);
check($sales && Illuminate\Support\Facades\Hash::check('sales-password-123',$sales->password),'Admin creates salesperson with hashed password');
check(Illuminate\Support\Facades\Auth::attempt(['email'=>$sales->email,'password'=>'sales-password-123','active'=>true]),'Created salesperson can authenticate');
try{$controller->addUser(requestFor($sales));throw new RuntimeException('Salesperson created account');}catch(Symfony\Component\HttpKernel\Exception\HttpException $e){check($e->getStatusCode()===403,'Salesperson cannot create accounts');}
try{$controller->addUser(requestFor($admin,['name'=>'Duplicate','email'=>'a@example.test','password'=>'sales-password-123','role'=>'salesperson']));throw new RuntimeException('Duplicate accepted');}catch(Illuminate\Validation\ValidationException $e){check(isset($e->errors()['email']),'Duplicate login email rejected');}
$profile=$controller->profile(requestFor($sales))->render();
check(str_contains($profile,'a@example.test')&&!str_contains($profile,'admin@example.test')&&!str_contains($profile,$sales->password),'Profile shows only signed-in account and hides password');
Illuminate\Support\Facades\DB::table('clients')->insert([['salesperson_id'=>$sales->id],['salesperson_id'=>$admin->id]]);
$scope=new ReflectionMethod($controller,'scope');
check($scope->invoke($controller,requestFor($sales),'clients')->count()===1,'Salesperson data scope excludes other accounts');
$favicon=Illuminate\Support\Facades\Route::getRoutes()->match(Illuminate\Http\Request::create('/favicon.ico'))->run();
check($favicon->getStatusCode()===200 && $favicon->headers->get('Content-Type')==='image/png','Favicon route serves existing logo');
check(Illuminate\Support\Facades\Route::getRoutes()->match(Illuminate\Http\Request::create('/admin/login'))->uri()==='admin/login','Admin login alias exists');
