<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;
return new class extends Migration {
 public function up():void {Schema::table('reports',function(Blueprint $t){$t->date('follow_up_date')->nullable()->index();});}
 public function down():void {Schema::table('reports',fn(Blueprint $t)=>$t->dropColumn('follow_up_date'));}
};
