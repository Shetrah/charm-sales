<?php
namespace App\Http\Middleware;
use Closure;
use Illuminate\Http\Request;
class ActiveUser {public function handle(Request $r,Closure $next){abort_unless($r->user()?->active,403);$response=$next($r);$response->headers->set('Cache-Control','private, no-store');return $response;}}
