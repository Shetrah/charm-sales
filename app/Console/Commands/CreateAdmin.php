<?php
namespace App\Console\Commands;
use App\Models\User;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Validator;
class CreateAdmin extends Command {
 protected $signature='charm:create-admin';
 protected $description='Create the first admin with a private password prompt';
 public function handle():int {
  if(User::where('role','admin')->exists()){$this->error('An admin already exists. Sign in and create accounts from Team.');return self::FAILURE;}
  $v=['name'=>trim((string)$this->ask('Admin name')),'email'=>strtolower(trim((string)$this->ask('Admin email'))),'password'=>$this->secret('Password (at least 12 characters)')];
  $confirmation=$this->secret('Confirm password');
  $validator=Validator::make($v,['name'=>'required|string|max:200','email'=>'required|email|unique:users,email','password'=>'required|string|min:12']);
  if($validator->fails()){foreach($validator->errors()->all() as $error)$this->error($error);return self::FAILURE;}
  if($v['password']!==$confirmation){$this->error('Passwords do not match.');return self::FAILURE;}
  User::create([...$v,'role'=>'admin']);$this->info('Admin created. Sign in with the email and password you entered.');return self::SUCCESS;
 }
}
