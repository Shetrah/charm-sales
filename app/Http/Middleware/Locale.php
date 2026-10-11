<?php
namespace App\Http\Middleware;
use Closure;
use Illuminate\Http\Request;
class Locale {
 public function handle(Request $r,Closure $next){$locale=$r->header('X-Locale')??$r->cookie('charm_locale','en');app()->setLocale(in_array($locale,['en','zh_CN'])?$locale:'en');return $next($r);}
}
