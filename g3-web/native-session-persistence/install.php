<?php
chdir('/srv/g3-portal/app');require 'vendor/autoload.php';$a=require 'bootstrap/app.php';$a->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
use Illuminate\Support\Facades\Schema;
use Illuminate\Database\Schema\Blueprint;
if(!Schema::hasTable('rustdesk_sso_native_sessions'))Schema::create('rustdesk_sso_native_sessions',function(Blueprint $t){$t->string('token_hash',64)->primary();$t->unsignedBigInteger('user_id')->index();$t->timestamp('created_at');});
echo "Native app grant table ready\n";
