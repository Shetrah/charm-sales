<?php
namespace App\Services;
use Carbon\CarbonImmutable;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Cache;

class Workspace
{
 public const KINDS=['orders','clients','payments','products','plans','expenses','reports','visits','workdays','users'];
 public function scope(Request $r,string $table) {
  $q=DB::table($table);
  if($r->user()->role!=='admin') {
   if($table==='users')$q->where('users.id',$r->user()->id);
   elseif($table==='payments')$q->whereIn('payments.order_id',DB::table('orders')->select('id')->where('salesperson_id',$r->user()->id));
   elseif($table!=='products')$q->where($table.'.salesperson_id',$r->user()->id);
  }
  return $q;
 }
 public function bounds(Request $r):array {
  $month=$r->validate(['month'=>'nullable|date_format:Y-m'])['month']??now('Africa/Nairobi')->format('Y-m');
  $start=CarbonImmutable::parse($month.'-01','Africa/Nairobi');
  return [$month,$start->utc(),$start->addMonth()->utc()];
 }
 public function balances(Request $r) {
  $paid=DB::table('payments')->select('order_id')->selectRaw('SUM(amount) as paid')->where('status','verified')->groupBy('order_id');
  return $this->scope($r,'orders')->where('orders.status','confirmed')->leftJoinSub($paid,'verified',fn($j)=>$j->on('verified.order_id','=','orders.id'));
 }
 public function summary(Request $r):array {
  [$month,$start,$end]=$this->bounds($r);
  $monthly=$this->scope($r,'orders')->where('status','confirmed')->where('confirmed_at','>=',$start)->where('confirmed_at','<',$end);
  $paid=DB::table('payments')->select('order_id')->selectRaw('SUM(amount) as paid')->where('status','verified')->groupBy('order_id');
  $pendingReviews=$this->scope($r,'plans')->where('status','pending')->selectRaw('COUNT(*) as count')->unionAll($this->scope($r,'expenses')->where('status','pending')->selectRaw('COUNT(*) as count'))->unionAll($this->scope($r,'reports')->where('status','pending')->selectRaw('COUNT(*) as count'));
  $metrics=$this->scope($r,'orders')->leftJoinSub($paid,'verified',fn($j)=>$j->on('verified.order_id','=','orders.id'))
   ->selectRaw("COALESCE(SUM(CASE WHEN orders.status='confirmed' AND orders.confirmed_at >= ? AND orders.confirmed_at < ? THEN orders.total ELSE 0 END),0) as sales, COUNT(CASE WHEN orders.status='confirmed' AND orders.confirmed_at >= ? AND orders.confirmed_at < ? THEN 1 END) as count, COALESCE(SUM(CASE WHEN orders.status='confirmed' THEN orders.total-COALESCE(verified.paid,0) ELSE 0 END),0) as outstanding, COALESCE(SUM(CASE WHEN orders.status='confirmed' THEN COALESCE(verified.paid,0) ELSE 0 END),0) as paid, COUNT(CASE WHEN orders.status='pending' THEN 1 END) as pending",[$start,$end,$start,$end])
   ->selectSub($this->scope($r,'clients')->selectRaw('COUNT(*)'),'client_count')
   ->selectSub($this->scope($r,'payments')->where('status','pending')->selectRaw('COUNT(*)'),'pending_payments')
   ->selectSub(DB::query()->fromSub($pendingReviews,'reviews')->selectRaw('SUM(count)'),'pending_reviews')->first();
  $team=(clone $monthly)->join('users','users.id','=','orders.salesperson_id')->select('users.name','users.id')->selectRaw('SUM(orders.total) as total')->groupBy('users.id','users.name')->orderByDesc('total')->get();
  return ['month'=>$month,'monthly_sales'=>(string)$metrics->sales,'monthly_orders'=>(int)$metrics->count,'outstanding'=>(string)$metrics->outstanding,'verified_paid'=>(string)$metrics->paid,'pending_orders'=>(int)$metrics->pending,'pending_payments'=>(int)$metrics->pending_payments,'pending_reviews'=>(int)$metrics->pending_reviews,'pending_approvals'=>(int)$metrics->pending+(int)$metrics->pending_payments+(int)$metrics->pending_reviews,'client_count'=>(int)$metrics->client_count,'chart'=>$team];
 }
 public function products() {
  return Cache::remember('workspace.products.v1',300,fn()=>DB::table('products')->where('active',true)->orderBy('category')->orderBy('capacity')->get());
 }
 public function records(Request $r,string $kind):array {
  abort_unless(in_array($kind,self::KINDS),404);
  abort_if($kind==='users'&&$r->user()->role!=='admin',403);
  $v=$r->validate(['q'=>'nullable|string|max:100','status'=>'nullable|string|max:30','page'=>'nullable|integer|min:1','per_page'=>'nullable|integer|min:1|max:50','sort'=>'nullable|in:newest,oldest,name,amount','month'=>'nullable|date_format:Y-m','confirmed'=>'nullable|boolean','salesperson_id'=>'nullable|integer|min:1','date'=>'nullable|date_format:Y-m-d']);
  $q=$this->scope($r,$kind);$columns=[$kind.'.*'];
  if(!in_array($kind,['users','products','payments'])) {
   $q->leftJoin('users as assigned','assigned.id','=',$kind.'.salesperson_id');$columns[]='assigned.name as salesperson_name';
   if($r->user()->role==='admin'&&!empty($v['salesperson_id']))$q->where($kind.'.salesperson_id',$v['salesperson_id']);
  }
  if(!empty($v['date'])&&in_array($kind,['plans','expenses','reports','workdays']))$q->where($kind.'.date',$v['date']);
  if(!empty($v['date'])&&$kind==='visits'){$start=CarbonImmutable::parse($v['date'],'Africa/Nairobi')->utc();$q->where('visits.check_in_at','>=',$start)->where('visits.check_in_at','<',$start->addDay());}

  if(in_array($kind,['orders','visits','plans','expenses','reports'])) {
   $q->leftJoin('clients','clients.id','=',$kind.'.client_id');$columns[]='clients.name as client_name';
  }
  if($kind==='payments'){$q->leftJoin('orders as payment_order','payment_order.id','=','payments.order_id')->leftJoin('users as assigned','assigned.id','=','payment_order.salesperson_id');$columns[]='assigned.name as salesperson_name';if($r->user()->role==='admin'&&!empty($v['salesperson_id']))$q->where('payment_order.salesperson_id',$v['salesperson_id']);}
  if(!empty($v['date'])&&in_array($kind,['orders','payments','clients'])){$start=CarbonImmutable::parse($v['date'],'Africa/Nairobi')->utc();$q->where($kind.'.created_at','>=',$start)->where($kind.'.created_at','<',$start->addDay());}
  if($kind==='clients') {
   $balanceOrders=$this->balances($r)->select('orders.client_id')->selectRaw('SUM(orders.total-COALESCE(verified.paid,0)) as balance')->groupBy('orders.client_id');
   $q->leftJoinSub($balanceOrders,'client_balances',fn($j)=>$j->on('client_balances.client_id','=','clients.id'));$columns[] = DB::raw('COALESCE(client_balances.balance,0) as balance');
  }
  if($kind==='orders') {
   $paid=DB::table('payments')->select('order_id')->selectRaw('SUM(amount) as paid')->where('status','verified')->groupBy('order_id');
   $q->leftJoinSub($paid,'verified',fn($j)=>$j->on('verified.order_id','=','orders.id'));
   $columns[]=DB::raw('COALESCE(verified.paid,0) as paid');$columns[]=DB::raw("CASE WHEN orders.status='confirmed' THEN orders.total-COALESCE(verified.paid,0) ELSE NULL END as balance");
   if($r->boolean('confirmed'))$q->where('orders.status','confirmed');
  }
  if($kind==='users')$columns=['users.id','users.name','users.email','users.role','users.active'];
  if(!empty($v['q'])) {
   $search='%'.str_replace(['\\','%','_'],['\\\\','\\%','\\_'],$v['q']).'%';
   $fields=match($kind){'clients'=>['clients.name','clients.contact','clients.phone'],'products'=>['products.category','products.capacity','products.fragrance','products.barcode'],'users'=>['users.name','users.email'],'payments'=>['payments.reference','CAST(payments.order_id AS TEXT)'],'orders'=>['clients.name',"'CH-' || CAST(orders.id AS TEXT)"], 'workdays'=>['CAST(workdays.date AS TEXT)','CAST(workdays.salesperson_id AS TEXT)'], default=>[$kind.'.notes','clients.name']};
   $q->where(function($q)use($fields,$search){foreach($fields as $f)$q->orWhereRaw('LOWER('.$f.') LIKE LOWER(?)',[$search]);if(!$fields)$q->whereRaw('1=0');});
  }
  if(!empty($v['status'])&&in_array($kind,['orders','payments','plans','expenses','reports']))$q->where($kind.'.status',$v['status']);
  if(!empty($v['month'])&&$kind==='orders') {[, $start,$end]=$this->bounds($r);$q->where('orders.status','confirmed')->where('orders.confirmed_at','>=',$start)->where('orders.confirmed_at','<',$end);}
  $sort=$v['sort']??'newest';
  if($sort==='name'&&in_array($kind,['clients','users','products']))$q->orderBy($kind.'.'.($kind==='products'?'category':'name'));
  elseif($sort==='amount'&&in_array($kind,['orders','payments']))$q->orderByDesc($kind.'.'.($kind==='orders'?'total':'amount'));
  else $q->orderBy($kind.'.id',$sort==='oldest'?'asc':'desc');
  $page=$q->paginate($v['per_page']??20,$columns,'page',$v['page']??1);
  return ['records'=>$page->items(),'page'=>$page->currentPage(),'last_page'=>$page->lastPage(),'total'=>$page->total(),'per_page'=>$page->perPage()];
 }
 public function detail(Request $r,string $kind,int $id):array {
  abort_unless(in_array($kind,self::KINDS),404);abort_if($kind==='users'&&$r->user()->role!=='admin',403);
  $columns=$kind==='users'?['id','name','email','role','active']:['*'];
  $record=$this->scope($r,$kind)->where($kind.'.id',$id)->first($columns);abort_unless($record,404);
  $data=['record'=>$record];if(isset($record->salesperson_id))$record->salesperson_name=DB::table('users')->where('id',$record->salesperson_id)->value('name');if(isset($record->client_id))$record->client_name=DB::table('clients')->where('id',$record->client_id)->value('name');
  if($kind==='orders'){$data['items']=DB::table('order_items')->where('order_id',$id)->get();$balance=$this->balances($r)->where('orders.id',$id)->selectRaw('COALESCE(verified.paid,0) as paid, orders.total-COALESCE(verified.paid,0) as balance')->first();if($balance){$record->paid=$balance->paid;$record->balance=$balance->balance;}}
  return $data;
 }
}
