"""Build the reviewable, repeatable finance upgrade; never connect to a database."""
from pathlib import Path
import re

root=Path(__file__).resolve().parents[1]
parts=['-- Reviewed finance install/upgrade after baseline 001-009.\n'
       '-- Handles partial installations; preserves financial records and IDs.\n'
       '-- Review and test in staging before applying to production.\n'
       'begin;\n'
       'drop function if exists charm.finance_submit_accountability(uuid,bigint,text,text,text,bigint,text,bigint);\n']
for path in sorted((root/'supabase/migrations').glob('2026101300[12]*.sql')):
    sql=path.read_text(encoding='utf-8')
    sql=re.sub(r'^begin;\s*$|^commit;\s*$','',sql,flags=re.M)
    sql=re.sub(r'create table (?!if not exists)','create table if not exists ',sql)
    sql=re.sub(r'create (unique )?index (?!if not exists)',lambda m:'create '+(m[1] or '')+'index if not exists ',sql)
    sql=re.sub(r'create function ','create or replace function ',sql)
    sql=re.sub(r'create view ','create or replace view ',sql)
    sql=re.sub(r'create policy (\w+) on ([\w.]+)',lambda m:'drop policy if exists '+m[1]+' on '+m[2]+';\n'+m[0],sql)
    sql=re.sub(r'create trigger (\w+) (.*?) on ([\w.]+) ',lambda m:'drop trigger if exists '+m[1]+' on '+m[3]+';\n'+m[0],sql)
    sql=sql.replace("('Suppliers'),('Other');","('Suppliers'),('Other') on conflict(name) do nothing;")
    parts.append('\n-- '+path.name+'\n'+sql)
parts.append("\nnotify pgrst,'reload schema';\ncommit;\n")
(root/'supabase/finance-upgrade-reviewed.sql').write_text(''.join(parts),encoding='utf-8')
