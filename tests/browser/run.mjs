import {spawnSync} from 'node:child_process';
const env={...process.env,VITE_SUPABASE_URL:'http://127.0.0.1:54329',VITE_SUPABASE_PUBLISHABLE_KEY:'test-only-public-key',VITE_REALTIME_ENABLED:'false'};
const build=spawnSync(process.execPath,['node_modules/vite/bin/vite.js','build','--outDir','tests/.artifacts/browser-dist'],{env,stdio:'inherit',windowsHide:true});
if(build.status!==0)process.exit(build.status??1);
const test=spawnSync(process.execPath,['node_modules/@playwright/test/cli.js','test',...process.argv.slice(2)],{env,stdio:'inherit',windowsHide:true});
process.exit(test.status??1);
