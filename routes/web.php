<?php
use Illuminate\Support\Facades\Route;
use App\Http\Controllers\PortalController as P;
Route::view('/login','login')->name('login');
Route::post('/login',[P::class,'login'])->middleware('throttle:5,1');
Route::redirect('/admin/login','/login');
Route::get('/favicon.ico',function(){return response()->file(public_path('assets/charm-logo.png'),['Content-Type'=>'image/png']);});
Route::middleware(['auth',App\Http\Middleware\ActiveUser::class])->group(function(){
 Route::get('/workspace/summary',[App\Http\Controllers\WorkspaceController::class,'summary']);
 Route::get('/workspace/records/{kind}',[App\Http\Controllers\WorkspaceController::class,'records']);
 Route::get('/workspace/records/{kind}/{id}',[App\Http\Controllers\WorkspaceController::class,'detail'])->whereNumber('id');
 Route::redirect('/admin','/');
 Route::redirect('/dashboard','/');
 Route::get('/profile',[P::class,'profile'])->name('profile');
 Route::get('/',[P::class,'dashboard']); Route::post('/logout',[P::class,'logout']);
 require __DIR__.'/operations.php';
});
