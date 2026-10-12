<?php
// Read-only hosted setup diagnostic. Never outputs credentials or user details.
require __DIR__.'/../vendor/autoload.php';
$app=require __DIR__.'/../bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
try {
 $db=Illuminate\Support\Facades\DB::connection();
 $db->statement('BEGIN TRANSACTION READ ONLY');
 $identity=$db->selectOne("SELECT to_regprocedure('charm.actor()') IS NOT NULL AS actor_exists, to_regclass('charm.auth_accounts') IS NOT NULL AS mapping_table_exists");
 $functions=$db->select("SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='charm' ORDER BY proname");
 $config=config('database.connections.pgsql');
 $matches=str_contains((string)($config['host']??''),'ceeojkflwuavxzawncnd') || str_contains((string)($config['username']??''),'ceeojkflwuavxzawncnd');
 $result=['configured_connection_matches_reported_project'=>$matches,'identity'=>$identity,'functions'=>array_column($functions,'proname')];
 if($identity->mapping_table_exists) $result['linked_accounts']=(int)$db->selectOne('SELECT count(*) AS n FROM charm.auth_accounts')->n;
 echo json_encode($result,JSON_PRETTY_PRINT).PHP_EOL;
 $db->rollBack();
} catch(Throwable $e) {
 echo 'Read-only inspection unavailable (connection details omitted).'.PHP_EOL;
 exit(1);
}
