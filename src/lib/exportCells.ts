// Neutralize spreadsheet formula execution, including leading whitespace/control characters.
export function csvCell(value:unknown){let text=typeof value==='object'&&value!==null?JSON.stringify(value):String(value??'');if(/^[\s\u0000-\u001f]*[=+@-]/.test(text))text="'"+text;return '"'+text.replaceAll('"','""')+'"';}
