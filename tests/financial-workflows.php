<?php
// Uses the configured PostgreSQL database; all test rows are rolled back.
require __DIR__.'/../vendor/autoload.php';
$app=require __DIR__.'/../bootstrap/app.php';$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Date;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Str;
use App\Models\User;
use App\Services\Workspace;
use App\Http\Controllers\PortalController;
function check($condition,$message){if(!$condition)throw new RuntimeException($message);echo "PASS: $message\n";}
function requestFor($user,$values=[]){$r=Illuminate\Http\Request::create('/','POST',$values);$r->headers->set('Accept','application/json');$r->setUserResolver(fn()=>$user);return $r;}
function fails($status,$fn,$message){try{$fn();throw new RuntimeException('Expected failure: '.$message);}catch(Symfony\Component\HttpKernel\Exception\HttpException $e){check($e->getStatusCode()===$status,$message);}}
function cents($value){return (int)round((float)$value*100);}
$w=new Workspace;$p=new PortalController;
config(['cache.default'=>'array','cache.stores.array'=>['driver'=>'array']]);
DB::beginTransaction();
try {
 $suffix=Str::uuid();
 $admin=User::create(['name'=>'QA admin','email'=>'qa-admin-'.$suffix.'@example.test','password'=>'qa-password-123','role'=>'admin']);
 $a=User::create(['name'=>'QA A','email'=>'qa-a-'.$suffix.'@example.test','password'=>'qa-password-123','role'=>'salesperson']);
 $b=User::create(['name'=>'QA B','email'=>'qa-b-'.$suffix.'@example.test','password'=>'qa-password-123','role'=>'salesperson']);
 $product=DB::table('products')->insertGetId(['category'=>'Handwash','capacity'=>'500ml','fragrance'=>'Ylang-Ylang','barcode'=>'QA-'.$suffix,'carton'=>20,'active'=>true,'needs_review'=>false,'created_at'=>now(),'updated_at'=>now()]);
 $client=DB::table('clients')->insertGetId(['salesperson_id'=>$a->id,'name'=>'QA client A','contact'=>'QA','location'=>'QA','created_at'=>now(),'updated_at'=>now()]);
 $other=DB::table('clients')->insertGetId(['salesperson_id'=>$b->id,'name'=>'QA client B','contact'=>'QA','location'=>'QA','created_at'=>now(),'updated_at'=>now()]);
 $payload=['submission_key'=>(string)Str::uuid(),'client_id'=>$client,'items'=>[['product_id'=>$product,'quantity'=>2,'unit'=>'bottle','unit_price'=>'12.35'],['product_id'=>$product,'quantity'=>3,'unit'=>'carton','unit_price'=>'8.20']]];
 $id=$p->addOrder(requestFor($a,$payload))->getData()->id;
 check(DB::table('orders')->find($id)->total==='49.30','Mixed bottle/carton order totals exactly 49.30 without multiplying carton quantity');
 check($p->addOrder(requestFor($a,$payload))->getData()->id===$id,'Order submission UUID retry is idempotent');
 fails(403,fn()=>$p->confirm(requestFor($a),$id),'Salesperson cannot confirm orders');
 fails(403,fn()=>$p->addOrder(requestFor($b,[...$payload,'submission_key'=>(string)Str::uuid()])),'Salesperson cannot submit for another salesperson client');
 fails(404,fn()=>$w->detail(requestFor($b),'orders',$id),'Record detail cannot expose another salesperson order');
 fails(422,fn()=>$p->addOrder(requestFor($a,[...$payload,'submission_key'=>(string)Str::uuid(),'items'=>[['product_id'=>-1,'quantity'=>1,'unit'=>'bottle','unit_price'=>'12.35']]])),'Missing product is rejected after bulk product lookup');
 $oct=$w->summary(requestFor($a,['month'=>'2026-10']));check(cents($oct['monthly_sales'])===0,'Pending orders do not count as sales');
 Date::setTestNow(Carbon\CarbonImmutable::parse('2026-10-31 23:59:00','Africa/Nairobi'));
 $p->confirm(requestFor($admin),$id);
 check(cents($w->summary(requestFor($a,['month'=>'2026-10']))['monthly_sales'])===4930,'Confirmation belongs to Nairobi October month');
 fails(409,fn()=>$p->confirm(requestFor($admin),$id),'Order cannot be confirmed twice');
 $id2=$p->addOrder(requestFor($a,[...$payload,'submission_key'=>(string)Str::uuid()]))->getData()->id;
 Date::setTestNow(Carbon\CarbonImmutable::parse('2026-11-01 00:00:00','Africa/Nairobi'));$p->confirm(requestFor($admin),$id2);
 check(cents($w->summary(requestFor($a,['month'=>'2026-10']))['monthly_sales'])===4930&&cents($w->summary(requestFor($a,['month'=>'2026-11']))['monthly_sales'])===4930,'Nairobi midnight puts second order into November exactly once');
 $payment=['submission_key'=>(string)Str::uuid(),'order_id'=>$id,'amount'=>'10.00','reference'=>'QA payment','received_at'=>now()->toIso8601String()];
 $paymentId=$p->addPayment(requestFor($a,$payment))->getData()->id;
 check(cents($w->summary(requestFor($a))['outstanding'])===9860,'Pending payment leaves balances unchanged');
 check($p->addPayment(requestFor($a,$payment))->getData()->id===$paymentId,'Payment submission UUID retry is idempotent');
 fails(403,fn()=>$p->verify(requestFor($a),$paymentId),'Salesperson cannot verify payments');
 $p->verify(requestFor($admin),$paymentId);
 $summary=$w->summary(requestFor($a,['month'=>'2026-10']));check(cents($summary['outstanding'])===8860&&cents($summary['verified_paid'])===1000&&cents($summary['monthly_sales'])===4930,'Verified payment reduces balance once and does not increase sales');
 fails(409,fn()=>$p->verify(requestFor($admin),$paymentId),'Payment cannot be verified twice');
 $excess=$p->addPayment(requestFor($a,[...$payment,'submission_key'=>(string)Str::uuid(),'amount'=>'40.00']))->getData()->id;
 fails(422,fn()=>$p->verify(requestFor($admin),$excess),'Overpayment verification is rejected');
 $clients=[];for($i=0;$i<55;$i++)$clients[]=['salesperson_id'=>$a->id,'name'=>'QA page '.$i,'contact'=>'QA','location'=>'QA','created_at'=>now(),'updated_at'=>now()];DB::table('clients')->insert($clients);
 $records=$w->records(requestFor($a,['page'=>2,'per_page'=>20]),'clients');check(count($records['records'])===20&&$records['total']===56&&$records['last_page']===3,'Server pagination is bounded and scoped to owner');
 check($w->records(requestFor($a,['q'=>'QA client B']),'clients')['total']===0,'Server search cannot expose another salesperson client');
 $snapshot=$p->snapshot(requestFor($a));check($snapshot['clients']->count()===50&&$snapshot['pagination']['clients']['has_more'],'Mobile snapshot caps records and exposes continuation metadata');
 fails(403,fn()=>$w->records(requestFor($a),'users'),'Salesperson cannot list team accounts');
 $detail=$w->detail(requestFor($admin),'users',$a->id);check(!isset($detail['record']->password),'Admin account details exclude password hashes');
 $w->products();$p->pricing(requestFor($admin,['unit_price'=>'22.50']),$product);check(cents($w->products()->firstWhere('id',$product)->unit_price)===2250,'Reference cache invalidates after price update');
 $plan=$p->record(requestFor($a,['submission_key'=>(string)Str::uuid(),'date'=>'2026-11-02','client_id'=>$client,'notes'=>'QA itinerary','budget'=>'10.00']),'plans')->getData()->id;
 fails(403,fn()=>$p->review(requestFor($a,['status'=>'approved']),'plans',$plan),'Salesperson cannot approve itineraries');
 $p->review(requestFor($admin,['status'=>'approved']),'plans',$plan);check(DB::table('plans')->find($plan)->status==='approved','Admin itinerary review preserved');
 $visit=$p->visit(requestFor($a,['submission_key'=>(string)Str::uuid(),'client_id'=>$client,'check_in_at'=>now()->utc()->toIso8601String(),'latitude'=>'-1.28','longitude'=>'36.82','accuracy_m'=>'10','outcome'=>'follow-up','notes'=>'QA visit report','next_action'=>'Call next week','follow_up_date'=>'2026-11-08']))->getData()->id;
 check(DB::table('visits')->find($visit)->notes==='QA visit report','GPS visit notes and follow-up workflow preserved');
 config(['services.supabase.url'=>'https://storage.example.test','services.supabase.key'=>'qa-key','services.supabase.bucket'=>'qa-private']);
 Illuminate\Support\Facades\Http::fake(['*'=>Illuminate\Support\Facades\Http::response(['signedURL'=>'/object/sign/qa-private/photo.png?token=qa'],200)]);
 $upload=Illuminate\Http\Request::create('/uploads/visits/'.$visit,'POST',[],[],['file'=>Illuminate\Http\UploadedFile::fake()->image('photo.png',5,5)]);$upload->headers->set('Accept','application/json');$upload->setUserResolver(fn()=>$a);
 $uploads=new App\Http\Controllers\UploadController;
 fails(403,fn()=>$uploads->download(requestFor($b),'visits',$visit),'Another salesperson cannot access visit photos');
 check($uploads->store($upload,'visits',$visit)->getData()->uploaded,'Private image-upload workflow works with mocked storage');
 $signed=$uploads->download(requestFor($a),'visits',$visit);check($signed->getStatusCode()===302&&str_contains($signed->getTargetUrl(),'token=qa'),'Authorised photo download redirects to temporary signed URL');
 Illuminate\Support\Facades\Http::assertSent(fn($r)=>str_contains($r->url(),'/storage/v1/object/sign/')&&$r['expiresIn']===60);
} finally {Date::setTestNow();DB::rollBack();Cache::forget('workspace.products.v1');}
echo "Test rows rolled back.\n";
