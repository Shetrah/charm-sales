<?php
namespace App\Http\Controllers;
use App\Services\Workspace;
use Illuminate\Http\Request;
class WorkspaceController {
 public function summary(Request $r,Workspace $workspace){return response()->json($workspace->summary($r))->header('Cache-Control','private, no-store');}
 public function records(Request $r,string $kind,Workspace $workspace){return response()->json($workspace->records($r,$kind))->header('Cache-Control','private, no-store');}
 public function detail(Request $r,string $kind,int $id,Workspace $workspace){return response()->json($workspace->detail($r,$kind,$id))->header('Cache-Control','private, no-store');}
}
