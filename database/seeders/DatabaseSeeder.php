<?php
namespace Database\Seeders;
use Illuminate\Database\Seeder;
use Illuminate\Support\Facades\DB;
class DatabaseSeeder extends Seeder {
 public function run():void {
 foreach(json_decode(file_get_contents(base_path('products.json')),true) as $p){$p['needs_review']=in_array($p['id'],[18,20,24]);$p['created_at']=now();$p['updated_at']=now();DB::table('products')->updateOrInsert(['id'=>$p['id']],$p);}
 DB::statement("SELECT setval(pg_get_serial_sequence('charm.products','id'), (SELECT MAX(id) FROM charm.products))");
 }
}
