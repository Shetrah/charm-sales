<?php
namespace App\Http\Controllers;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Str;
class UploadController {
 private function record(Request $r,string $kind,int $id):object {
 abort_unless(in_array($kind,['visits','payments']),404);$x=DB::table($kind)->find($id);abort_unless($x,404);
 $owner=$kind==='visits'?$x->salesperson_id:DB::table('orders')->find($x->order_id)->salesperson_id;
 abort_unless($r->user()->role==='admin'||$owner===$r->user()->id,403);return $x;
 }
 private function client(){abort_unless(config('services.supabase.url')&&config('services.supabase.key'),503,__('Storage not configured'));return Http::withHeaders(['apikey'=>config('services.supabase.key'),'Authorization'=>'Bearer '.config('services.supabase.key')])->timeout(30);}
 public function store(Request $r,string $kind,int $id){$this->record($r,$kind,$id);$r->validate(['file'=>'required|file|mimes:jpg,jpeg,png,webp|max:5120']);$f=$r->file('file');$path=$kind.'/'.$id.'/'.Str::uuid().'.'.$f->extension();$url=rtrim(config('services.supabase.url'),'/').'/storage/v1/object/'.config('services.supabase.bucket').'/'.$path;$this->client()->withBody(file_get_contents($f->getRealPath()),$f->getMimeType())->post($url)->throw();DB::table($kind)->where('id',$id)->update([$kind==='visits'?'photo_path':'proof_path'=>$path]);return $r->expectsJson()?response()->json(['uploaded'=>true]):redirect('/')->with('success',__('Image uploaded'));}
 public function download(Request $r,string $kind,int $id){$x=$this->record($r,$kind,$id);$path=$kind==='visits'?$x->photo_path:$x->proof_path;abort_unless($path,404);$url=rtrim(config('services.supabase.url'),'/').'/storage/v1/object/sign/'.config('services.supabase.bucket').'/'.$path;$signed=$this->client()->post($url,['expiresIn'=>60])->throw()->json('signedURL');return redirect()->away(rtrim(config('services.supabase.url'),'/').'/storage/v1'.$signed);}
}
