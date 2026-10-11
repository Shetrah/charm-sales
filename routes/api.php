<?php
use Illuminate\Support\Facades\Route;
use App\Http\Controllers\PortalController as P;
Route::post('/token',[P::class,'token'])->middleware('throttle:5,1');
Route::middleware(['auth:sanctum',App\Http\Middleware\ActiveUser::class,'throttle:120,1'])->group(function(){
 Route::get('/snapshot',[P::class,'snapshot']);
 Route::delete('/token',function(Illuminate\Http\Request $r){$r->user()->currentAccessToken()?->delete();return response()->noContent();});
 require __DIR__.'/operations.php';
});
