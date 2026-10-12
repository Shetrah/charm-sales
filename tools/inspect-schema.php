<?php
require __DIR__.'/../vendor/autoload.php';
$app=require __DIR__.'/../bootstrap/app.php';$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
try {
$db=Illuminate\Support\Facades\DB::connection();
$db->statement('BEGIN TRANSACTION READ ONLY');
$columns=$db->select("SELECT table_name,column_name,data_type,is_nullable FROM information_schema.columns WHERE table_schema='charm' ORDER BY table_name,ordinal_position");
$counts=[];foreach(['users','products','clients','orders','order_items','payments','visits','plans','expenses','reports','workdays','location_points','audit_logs'] as $table){$counts[$table]=$db->selectOne('SELECT count(*) AS n FROM charm.'.$table)->n;}
echo json_encode(['columns'=>$columns,'counts'=>$counts],JSON_PRETTY_PRINT);$db->rollBack();
}catch(Throwable $e){echo 'Inspection unavailable: '.get_class($e).' (connection details omitted)';exit(1);}
