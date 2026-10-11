<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;
return new class extends Migration {
 public function up():void {
  Schema::table('orders',function(Blueprint $t){$t->index(['salesperson_id','status','confirmed_at'],'orders_owner_status_month');$t->index(['status','confirmed_at'],'orders_status_month');$t->index(['client_id','status'],'orders_client_status');});
  Schema::table('payments',fn(Blueprint $t)=>$t->index(['order_id','status'],'payments_order_status'));
  foreach(['clients','visits','plans','expenses','reports'] as $table)Schema::table($table,fn(Blueprint $t)=>$t->index(['salesperson_id','id'],$table.'_owner_page'));
 }
 public function down():void {
  Schema::table('orders',function(Blueprint $t){$t->dropIndex('orders_owner_status_month');$t->dropIndex('orders_status_month');$t->dropIndex('orders_client_status');});
  Schema::table('payments',fn(Blueprint $t)=>$t->dropIndex('payments_order_status'));
  foreach(['clients','visits','plans','expenses','reports'] as $table)Schema::table($table,fn(Blueprint $t)=>$t->dropIndex($table.'_owner_page'));
 }
};
