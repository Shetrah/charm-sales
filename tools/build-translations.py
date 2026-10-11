import json
from pathlib import Path
root=Path(__file__).resolve().parents[1]
en=json.loads((root/'lang/en.json').read_text(encoding='utf-8'))
zh=json.loads((root/'lang/zh_CN.json').read_text(encoding='utf-8'))
assert en.keys()==zh.keys(), 'Translation keys must match'
# Laravel validators use these structured keys; both client and server use the same message templates.
rules={'required':'The :attribute field is required.','email':'The :attribute field must be a valid email address.','unique':'The :attribute has already been taken.','exists':'The selected :attribute is invalid.','in':'The selected :attribute is invalid.','regex':'The :attribute field format is invalid.','date':'The :attribute field must be a valid date.','numeric':'The :attribute field must be a number.','integer':'The :attribute field must be an integer.','uuid':'The :attribute field must be a valid UUID.','string':'The :attribute field must be a string.','array':'The :attribute field must be an array.','boolean':'The :attribute field must be true or false.','date_format':'The :attribute field must match the format :format.','after_or_equal':'The :attribute field must be a date after or equal to :date.','file':'The :attribute field must be a file.','mimes':'The :attribute field must be a file of type: :values.'}
for locale,data in [('en',en),('zh_CN',zh)]:
    p=root/'lang'/locale;p.mkdir(exist_ok=True)
    php=lambda s: "'"+s.replace('\\','\\\\').replace("'","\\'")+"'"
    lines=['<?php','return [']+[f' {php(k)}=>{php(data[v])},' for k,v in rules.items()]
    for rule,types in {'min':{'string':'The :attribute field must be at least :min characters.','numeric':'The :attribute field must be at least :min.','array':'The :attribute field must have at least :min items.','file':'The :attribute field must be at least :min kilobytes.'},'max':{'string':'The :attribute field must not be greater than :max characters.','numeric':'The :attribute field must not be greater than :max.','array':'The :attribute field must not have more than :max items.','file':'The :attribute field must not be greater than :max kilobytes.'},'between':{'numeric':'The :attribute field must be between :min and :max.'}}.items():
        lines.append(f' {php(rule)}=>['+','.join(php(k)+'=>'+php(data[v]) for k,v in types.items())+'],')
    attributes={k:data[k] for k in ['name','email','password','role','date','notes','budget','amount','reference','client_id','order_id','submission_key','latitude','longitude','accuracy_m','unit_price','quantity','items','file','due_date','received_at','follow_up_date','check_in_at','check_out_at','outcome','next_action','contact','phone','location','status']}
    attributes.update({'items.*.product_id':data['Product variant'],'items.*.quantity':data['Quantity'],'items.*.unit':data['Ordering unit'],'items.*.unit_price':data['Unit price']})
    lines.append(" 'attributes'=>["+','.join(php(k)+'=>'+php(v) for k,v in attributes.items())+'],');lines.append('];')
    (p/'validation.php').write_text('\n'.join(lines),encoding='utf-8')
(root/'public/translations.js').write_text('window.Charm.messages='+json.dumps({'en':en,'zh_CN':zh},ensure_ascii=False,separators=(',',':'))+';',encoding='utf-8')
